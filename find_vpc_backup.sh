#find_vpc_backup.sh
#[root@ip-11-0-1-154 scripts]# cat find_vpc_backup.sh
#!/bin/bash
set -euo pipefail

ACCOUNT="$1"
REGION="$2"
VPC_NAME="$3"

BASE_DIR="/opt/terraform/logs"
TF_DIR="/opt/terraform/vpc-dr-test/tf-network-dr"
TFVARS="$TF_DIR/terraform.tfvars.json"

LATEST_BACKUP=$(ls -d ${BASE_DIR}/${ACCOUNT}_* 2>/dev/null | sort | tail -1)
[ -z "$LATEST_BACKUP" ] && echo "No backup found" && exit 1

MATCHING_VPC=$(ls -d "${LATEST_BACKUP}/${ACCOUNT}_${REGION}_"*"${VPC_NAME}"* 2>/dev/null | head -1)
[ -z "$MATCHING_VPC" ] && echo "No matching VPC" && exit 1

HAS_IGW=false
HAS_NAT=false
jq -e '.InternetGateways | length > 0' "$MATCHING_VPC/internet_gateways.json" >/dev/null && HAS_IGW=true
jq -e '.RouteTables[].Routes[]? | select(.NatGatewayId!=null)' "$MATCHING_VPC/route_tables.json" >/dev/null && HAS_NAT=true

echo "🛠 Generating terraform.tfvars.json …"

jq -n \
--arg region "$REGION" \
--argjson vpc "$(jq '{name:(.Vpcs[0].Tags[]?|select(.Key=="Name")|.Value),cidr:.Vpcs[0].CidrBlock}' "$MATCHING_VPC/vpc.json")" \
\
--argjson subnets "$(jq '[.Subnets[] | {
  name:(.Tags[]?|select(.Key=="Name")|.Value),
  cidr:.CidrBlock,
  az:.AvailabilityZone,
  public:(any(.Tags[]?; .Key=="Type" and (.Value=="public" or .Value=="Public"))),
  private_nat:(any(.Tags[]?; .Key=="Type" and (.Value=="private" or .Value=="Private" or .Value=="nat")))
}]' "$MATCHING_VPC/subnets.json")" \
\
--argjson security_groups "$(jq '[.SecurityGroups[]|select(.GroupName!="default")|{
  name:.GroupName,
  description:.Description,
  ingress:[.IpPermissions[]? as $p|$p.IpRanges[]?|{
    from:($p.FromPort//0),
    to:($p.ToPort//0),
    proto:($p.IpProtocol//"-1"),
    cidr:.CidrIp
  }],
  egress:[.IpPermissionsEgress[]? as $p|$p.IpRanges[]?|{
    from:($p.FromPort//0),
    to:($p.ToPort//0),
    proto:($p.IpProtocol//"-1"),
    cidr:.CidrIp
  }]
}]' "$LATEST_BACKUP/security_groups_${REGION}.json")" \
\
--argjson ec2_instances "$(jq '[.Reservations[].Instances[]|{
  name:(.Tags[]?|select(.Key=="Name")|.Value),
  ami:.ImageId,
  instance_type:.InstanceType,
  subnet_id:.SubnetId,
  security_groups:[.SecurityGroups[].GroupName],
  key_name:.KeyName,
  root_volume_gb:(.BlockDeviceMappings[]|select(.DeviceName=="/dev/xvda")|.Ebs.VolumeSize)
}]' "$MATCHING_VPC/ec2_instances.json")" \
\
--argjson eips "$(jq '[.Addresses[]|{
  allocation_id:.AllocationId,
  public_ip:.PublicIp
}]' "$LATEST_BACKUP/non-vpc_${REGION}/eips.json")" \
\
--argjson nat_gateways "$(jq '[.NatGateways[]|{
  name:(.Tags[]?|select(.Key=="Name")|.Value // .NatGatewayId),
  subnet_id:.SubnetId,
  allocation_id:.NatGatewayAddresses[0].AllocationId
}]' "$MATCHING_VPC/nat_gateways.json")" \
\
--argjson rds_instances "$(jq '[.[]|{
  identifier:.DBInstanceIdentifier,
  engine:.Engine,
  engine_version:.EngineVersion,
  instance_class:.DBInstanceClass,
  allocated_storage:(.AllocatedStorage//20),
  storage_type:(.StorageType//"gp3"),
  username:.MasterUsername,
  port:.Endpoint.Port,
  subnet_group_name:.DBSubnetGroup.DBSubnetGroupName,
  multi_az:.MultiAZ,
  publicly_accessible:.PubliclyAccessible,
  security_groups:[.VpcSecurityGroups[].VpcSecurityGroupId]
}]' "$MATCHING_VPC/rds_instances.json")" \
\
--argjson has_igw "$HAS_IGW" \
--argjson has_nat "$HAS_NAT" \
'
{
  region:$region,
  vpc:$vpc,
  subnets:$subnets,
  security_groups:$security_groups,
  ec2_instances:$ec2_instances,
  eips:$eips,
  nat_gateways:$nat_gateways,
  rds_instances:$rds_instances,
  has_igw:$has_igw,
  has_nat:$has_nat
}
' > "$TFVARS"

echo "✅ terraform.tfvars.json created:"
echo "$TFVARS"
