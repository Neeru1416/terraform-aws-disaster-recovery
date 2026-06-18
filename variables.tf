variable "region" {
  type = string
}

variable "vpc" {
  type = object({
    name = string
    cidr = string
  })
}

variable "subnets" {
  type = list(object({
    name        = string
    cidr        = string
    az          = string
    public      = bool
    private_nat = bool
  }))
}

variable "has_igw" {
  type = bool
}

variable "has_nat" {
  type = bool
}

variable "security_groups" {
  type = list(object({
    name        = string
    description = optional(string, "")
    ingress     = list(any)
    egress      = list(any)
  }))
  default = []
}

variable "ec2_instances" {
  type = list(object({
    name            = string
    ami             = string
    instance_type   = string
    subnet_name     = string
    security_groups = list(string)
    key_name        = string
  }))
  default = []
}

variable "rds_instances" {
  type    = list(any)
  default = []
}

variable "albs" {
  type    = list(any)
  default = []
}

variable "target_groups" {
  type    = list(any)
  default = []
}

variable "listeners" {
  type    = list(any)
  default = []
}

variable "vpc_endpoints" {
  type    = list(any)
  default = []
}

variable "network_acls" {
  type    = list(any)
  default = []
}
