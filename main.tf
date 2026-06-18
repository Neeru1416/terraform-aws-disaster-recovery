terraform {
  required_version = ">= 1.3.0"
}

provider "aws" {
  region = var.region
}

########################
# LOCALS (100% ROBUST)
########################
locals {
  # Always-unique keys
  subnets_map = {
    for idx, s in var.subnets :
    idx => s
  }

  # Group subnet indexes by NAME (duplicates allowed)
  subnet_name_to_keys = {
    for idx, s in var.subnets :
    s.name => idx...
  }

  # Public subnet IDs (used for NAT)
  public_subnet_ids = [
    for idx, s in aws_subnet.this :
    s.id if local.subnets_map[idx].public
  ]
}

########################
# VPC
########################
resource "aws_vpc" "this" {
  cidr_block = var.vpc.cidr

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.vpc.name
  }
}

########################
# SUBNETS (INDEX-BASED, SAFE)
########################
resource "aws_subnet" "this" {
  for_each = local.subnets_map

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  map_public_ip_on_launch = each.value.public

  tags = {
    Name = each.value.name
  }
}

########################
# INTERNET GATEWAY
########################
resource "aws_internet_gateway" "this" {
  count  = var.has_igw ? 1 : 0
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.vpc.name}-igw"
  }
}

########################
# ELASTIC IP (ONLY IF NAT POSSIBLE)
########################
resource "aws_eip" "nat" {
  count  = var.has_nat && length(local.public_subnet_ids) > 0 ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "${var.vpc.name}-nat-eip"
  }
}

########################
# NAT GATEWAY (FINAL SAFE)
########################
resource "aws_nat_gateway" "this" {
  count = var.has_nat && length(local.public_subnet_ids) > 0 ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = local.public_subnet_ids[0]

  depends_on = [aws_internet_gateway.this]

  tags = {
    Name = "${var.vpc.name}-nat"
  }
}

########################
# ROUTE TABLES
########################
resource "aws_route_table" "public" {
  count  = var.has_igw ? 1 : 0
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = {
    Name = "${var.vpc.name}-public-rt"
  }
}

resource "aws_route_table" "private" {
  count  = var.has_nat && length(local.public_subnet_ids) > 0 ? 1 : 0
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[0].id
  }

  tags = {
    Name = "${var.vpc.name}-private-rt"
  }
}

########################
# ROUTE TABLE ASSOCIATIONS (SAFE)
########################
resource "aws_route_table_association" "assoc" {
  for_each = aws_subnet.this

  subnet_id = each.value.id

  route_table_id = (
    local.subnets_map[each.key].public
    ? aws_route_table.public[0].id
    : (
        length(aws_route_table.private) > 0
        ? aws_route_table.private[0].id
        : aws_route_table.public[0].id
      )
  )
}

########################
# SECURITY GROUPS
########################
resource "aws_security_group" "this" {
  for_each = {
    for sg in var.security_groups :
    sg.name => sg
  }

  name        = each.key
  description = each.value.description
  vpc_id      = aws_vpc.this.id

  dynamic "ingress" {
    for_each = each.value.ingress
    content {
      from_port   = ingress.value.from
      to_port     = ingress.value.to
      protocol    = ingress.value.proto
      cidr_blocks = [ingress.value.cidr]
    }
  }

  dynamic "egress" {
    for_each = each.value.egress
    content {
      from_port   = egress.value.from
      to_port     = egress.value.to
      protocol    = egress.value.proto
      cidr_blocks = [egress.value.cidr]
    }
  }

  tags = {
    Name = each.key
  }
}

########################
# EC2 INSTANCES (100% SAFE)
########################
resource "aws_instance" "this" {
  for_each = {
  for idx, ec2 in var.ec2_instances :
  "${ec2.name}-${idx}" => ec2
}

  ami           = each.value.ami
  instance_type = each.value.instance_type
  key_name      = each.value.key_name

  # Pick FIRST subnet that matches the name
  subnet_id = aws_subnet.this[
    local.subnet_name_to_keys[each.value.subnet_name][0]
  ].id

  vpc_security_group_ids = compact([
    for sg in each.value.security_groups :
    try(aws_security_group.this[sg].id, null)
  ])

  root_block_device {
    volume_size = lookup(each.value, "root_volume_gb", 8)
  }

  tags = {
    Name = each.value.name
  }
}
