# EKS cluster engress-west in us-west-1. Edge-only v1; core IRSA optional for future west core.

data "aws_iam_policy" "aws_load_balancer_controller_west" {
  count    = var.enable_eks_west ? 1 : 0
  provider = aws.west
  name     = "AWSLoadBalancerControllerIAMPolicy"
}

module "eks_west" {
  count   = var.enable_eks_west ? 1 : 0
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  lifecycle {
    prevent_destroy = true
  }

  providers = {
    aws = aws.west
  }

  cluster_name    = local.eks_west_cluster_name
  cluster_version = var.eks_cluster_version

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  vpc_id     = module.vpc_west[0].vpc_id
  subnet_ids = module.vpc_west[0].private_subnets

  enable_cluster_creator_admin_permissions = true

  access_entries = {
    github_deploy = {
      principal_arn = aws_iam_role.github_deploy.arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  eks_managed_node_groups = {
    system = {
      name           = "system"
      instance_types = [var.eks_system_node_instance_type]
      ami_type       = "AL2023_ARM_64_STANDARD"
      min_size       = var.eks_system_node_min_size
      max_size       = var.eks_system_node_max_size
      desired_size   = var.eks_system_node_desired_size
      labels         = { role = "system" }
    }
    workload = {
      name           = "workload"
      instance_types = [var.eks_workload_node_instance_type]
      ami_type       = "AL2023_ARM_64_STANDARD"
      min_size       = var.eks_workload_node_min_size
      max_size       = var.eks_workload_max_nodes
      desired_size   = var.eks_workload_node_desired_size
      labels         = { role = "workload" }
    }
  }

  tags = var.tags
}

module "engress_edge_irsa_west" {
  count     = var.enable_eks_west ? 1 : 0
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "5.3.2"
  role_name = "${var.name_prefix}-edge-west"

  oidc_providers = {
    main = {
      provider_arn               = module.eks_west[0].oidc_provider_arn
      namespace_service_accounts = ["engress:engress-edge"]
    }
  }
}

resource "aws_iam_role_policy" "engress_edge_west" {
  count = var.enable_eks_west ? 1 : 0
  name  = "${var.name_prefix}-edge-west-ecr"
  role  = module.engress_edge_irsa_west[0].iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
      ]
      Resource = "*"
    }]
  })
}

module "engress_core_irsa_west" {
  count     = var.enable_eks_west ? 1 : 0
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "5.3.2"
  role_name = "${var.name_prefix}-core-west"

  role_policy_arns = {
    lbc = data.aws_iam_policy.aws_load_balancer_controller_west[0].arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks_west[0].oidc_provider_arn
      namespace_service_accounts = ["engress:engress-core"]
    }
  }
}

resource "aws_iam_role_policy" "engress_core_west" {
  count = var.enable_eks_west ? 1 : 0
  name  = "${var.name_prefix}-core-west-ssm"
  role  = module.engress_core_irsa_west[0].iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
      ]
      Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/*"
    }]
  })
}

module "aws_load_balancer_controller_irsa_west" {
  count   = var.enable_eks_west ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.3.2"

  role_name = "${var.name_prefix}-aws-lbc-west"

  role_policy_arns = {
    lbc = data.aws_iam_policy.aws_load_balancer_controller_west[0].arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks_west[0].oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

output "eks_west_cluster_name" {
  value       = var.enable_eks_west ? module.eks_west[0].cluster_name : ""
  description = "West EKS cluster name"
}

output "engress_edge_west_irsa_arn" {
  value       = var.enable_eks_west ? module.engress_edge_irsa_west[0].iam_role_arn : ""
  description = "IRSA for engress-edge pods in us-west-1"
}

output "engress_core_west_irsa_arn" {
  value       = var.enable_eks_west ? module.engress_core_irsa_west[0].iam_role_arn : ""
  description = "IRSA for engress-core pods in us-west-1 (optional)"
}

output "aws_load_balancer_controller_west_irsa_arn" {
  value       = var.enable_eks_west ? module.aws_load_balancer_controller_irsa_west[0].iam_role_arn : ""
  description = "IRSA for AWS LBC in us-west-1"
}
