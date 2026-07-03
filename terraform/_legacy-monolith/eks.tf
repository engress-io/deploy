# EKS cluster — big-bang migration from EC2. Disabled by default (enable_eks = false).

locals {
  eks_cluster_name = var.eks_cluster_name != "" ? var.eks_cluster_name : "${var.name_prefix}-east"
}

module "eks" {
  count   = var.enable_eks ? 1 : 0
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.eks_cluster_name
  cluster_version = var.eks_cluster_version

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  cluster_enabled_log_types              = []
  cloudwatch_log_group_retention_in_days = 7

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

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

      labels = {
        role = "system"
      }
    }
    workload = {
      name           = "workload"
      instance_types = [var.eks_workload_node_instance_type]
      ami_type       = "AL2023_ARM_64_STANDARD"
      min_size       = var.eks_workload_node_min_size
      max_size       = var.eks_workload_max_nodes
      desired_size   = var.eks_workload_node_desired_size

      labels = {
        role = "workload"
      }
    }
  }

  tags = var.tags
}

# IRSA for engress-core (SSM access for Neon + Clerk secrets)
data "aws_iam_policy" "aws_load_balancer_controller" {
  count = var.enable_eks ? 1 : 0
  name  = "AWSLoadBalancerControllerIAMPolicy"
}

module "engress_core_irsa" {
  count     = var.enable_eks ? 1 : 0
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "5.3.2"
  role_name = "${var.name_prefix}-core"

  role_policy_arns = {
    lbc = data.aws_iam_policy.aws_load_balancer_controller[0].arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks[0].oidc_provider_arn
      namespace_service_accounts = ["engress:engress-core"]
    }
  }
}

resource "aws_iam_role_policy" "engress_core" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.name_prefix}-core-neon-ssm"
  role  = module.engress_core_irsa[0].iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "engress_core_oasis_dashboard" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.name_prefix}-core-oasis-dashboard"
  role  = module.engress_core_irsa[0].iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListNodegroups",
          "eks:DescribeNodegroup"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ce:GetCostAndUsage",
          "ce:GetCostForecast",
          "ce:GetDimensionValues"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "globalaccelerator:ListAccelerators",
          "globalaccelerator:ListListeners",
          "globalaccelerator:ListEndpointGroups",
          "globalaccelerator:DescribeEndpointGroup"
        ]
        Resource = "*"
      }
    ]
  })
}

# IRSA for engress-edge (ECR pull + SSM for tunnel CA)
module "engress_edge_irsa" {
  count     = var.enable_eks ? 1 : 0
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "5.3.2"
  role_name = "${var.name_prefix}-edge"

  oidc_providers = {
    main = {
      provider_arn               = module.eks[0].oidc_provider_arn
      namespace_service_accounts = ["engress:engress-edge"]
    }
  }
}

resource "aws_iam_role_policy" "engress_edge" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.name_prefix}-edge-ecr-ssm"
  role  = module.engress_edge_irsa[0].iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/engress-tunnel-ca-*",
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/engress-metrics-ingest-secret",
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/flux-metrics-ingest-secret",
        ]
      }
    ]
  })
}

# IRSA for AWS Load Balancer Controller (ALB/NLB provisioning)
module "aws_load_balancer_controller_irsa" {
  count   = var.enable_eks ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.3.2"

  role_name = "${var.name_prefix}-aws-lbc"

  role_policy_arns = {
    lbc = data.aws_iam_policy.aws_load_balancer_controller[0].arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks[0].oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

output "eks_cluster_name" {
  value       = var.enable_eks ? module.eks[0].cluster_name : ""
  description = "EKS cluster name (empty when enable_eks=false)"
}

output "eks_cluster_endpoint" {
  value       = var.enable_eks ? module.eks[0].cluster_endpoint : ""
  description = "EKS API endpoint"
}

output "engress_core_irsa_arn" {
  value       = var.enable_eks ? module.engress_core_irsa[0].iam_role_arn : ""
  description = "IRSA role ARN for engress-core pods"
}

output "engress_edge_irsa_arn" {
  value       = var.enable_eks ? module.engress_edge_irsa[0].iam_role_arn : ""
  description = "IRSA role ARN for engress-edge pods"
}

output "aws_load_balancer_controller_irsa_arn" {
  value       = var.enable_eks ? module.aws_load_balancer_controller_irsa[0].iam_role_arn : ""
  description = "IRSA role ARN for AWS Load Balancer Controller"
}

output "eks_oidc_provider_arn" {
  value       = var.enable_eks ? module.eks[0].oidc_provider_arn : ""
  description = "OIDC provider ARN for IRSA"
}
