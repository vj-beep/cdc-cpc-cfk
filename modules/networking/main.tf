locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.project_name
  cidr = var.vpc_cidr

  azs              = local.azs
  private_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]      # /20 - EKS nodes
  public_subnets   = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)] # /24 - LBs
  intra_subnets    = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 52)] # /24 - EKS CP ENIs
  database_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 56)] # /24 - RDS + Aurora

  enable_nat_gateway = true
  single_nat_gateway = true # single NAT keeps dev costs low

  # Database subnet group for RDS / Aurora
  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = true # Mac connectivity

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags required by EKS / Karpenter / ALB controller
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.project_name
  }

  tags = {
    "karpenter.sh/discovery" = var.project_name
  }
}
