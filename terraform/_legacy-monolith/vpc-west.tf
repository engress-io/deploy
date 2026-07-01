# VPC for engress-west (us-west-1). Disabled when enable_eks_west=false.

locals {
  eks_west_cluster_name = var.eks_west_cluster_name != "" ? var.eks_west_cluster_name : "${var.name_prefix}-west"
}

module "vpc_west" {
  count   = var.enable_eks_west ? 1 : 0
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  providers = {
    aws = aws.west
  }

  name = "${var.name_prefix}-vpc-west"
  cidr = var.eks_west_vpc_cidr

  azs             = ["us-west-1a", "us-west-1c"]
  private_subnets = var.eks_west_private_subnet_cidrs
  public_subnets  = var.eks_west_public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                              = "1"
    "kubernetes.io/cluster/${local.eks_west_cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                   = "1"
    "kubernetes.io/cluster/${local.eks_west_cluster_name}" = "shared"
  }

  tags = var.tags
}
