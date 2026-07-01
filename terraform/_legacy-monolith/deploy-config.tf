# Deploy configuration in SSM — single source of truth for CI/CD and Helm.
# GitHub Actions reads these after OIDC auth; only AWS_DEPLOY_ROLE_ARN stays in GitHub (bootstrap).

locals {
  deploy_edge_host = var.edge_origin_hostname != "" ? var.edge_origin_hostname : "edge-origin.${var.base_domain}"
  deploy_core_host = var.enable_control_instance && var.control_origin_hostname != "" ? var.control_origin_hostname : local.deploy_edge_host
  deploy_edge_ip   = local.edge_public_ip
  deploy_core_ip   = var.enable_control_instance && !var.decommission_ec2 ? try(aws_instance.control[0].public_ip, local.deploy_edge_ip) : local.deploy_edge_ip
  deploy_target    = var.decommission_ec2 ? "eks" : (var.enable_eks ? var.deploy_target : "ec2")
}

resource "aws_ssm_parameter" "deploy_github_role_arn" {
  name  = "engress-deploy-github-role-arn"
  type  = "String"
  value = aws_iam_role.github_deploy.arn

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_edge_ip" {
  name  = "engress-deploy-edge-ip"
  type  = "String"
  value = local.deploy_edge_ip

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_core_ip" {
  name  = "engress-deploy-core-ip"
  type  = "String"
  value = local.deploy_core_ip

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_edge_host" {
  name  = "engress-deploy-edge-host"
  type  = "String"
  value = local.deploy_edge_host

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_core_host" {
  name  = "engress-deploy-core-host"
  type  = "String"
  value = local.deploy_core_host

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_target" {
  name  = "engress-deploy-target"
  type  = "String"
  value = local.deploy_target

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_eks_cluster_name" {
  count = var.enable_eks ? 1 : 0

  name  = "engress-deploy-eks-cluster-name"
  type  = "String"
  value = local.eks_cluster_name

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_core_irsa_arn" {
  count = var.enable_eks ? 1 : 0

  name  = "engress-deploy-core-irsa-arn"
  type  = "String"
  value = module.engress_core_irsa[0].iam_role_arn

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_edge_irsa_arn" {
  count = var.enable_eks ? 1 : 0

  name  = "engress-deploy-edge-irsa-arn"
  type  = "String"
  value = module.engress_edge_irsa[0].iam_role_arn

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_lbc_irsa_arn" {
  count = var.enable_eks ? 1 : 0

  name  = "engress-deploy-lbc-irsa-arn"
  type  = "String"
  value = module.aws_load_balancer_controller_irsa[0].iam_role_arn

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_eks_west_cluster_name" {
  count = var.enable_eks_west ? 1 : 0

  name  = "engress-deploy-eks-west-cluster-name"
  type  = "String"
  value = local.eks_west_cluster_name

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_edge_west_irsa_arn" {
  count = var.enable_eks_west ? 1 : 0

  name  = "engress-deploy-edge-west-irsa-arn"
  type  = "String"
  value = module.engress_edge_irsa_west[0].iam_role_arn

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_core_west_irsa_arn" {
  count = var.enable_eks_west ? 1 : 0

  name  = "engress-deploy-core-west-irsa-arn"
  type  = "String"
  value = module.engress_core_irsa_west[0].iam_role_arn

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_lbc_west_irsa_arn" {
  count = var.enable_eks_west ? 1 : 0

  name  = "engress-deploy-lbc-west-irsa-arn"
  type  = "String"
  value = module.aws_load_balancer_controller_irsa_west[0].iam_role_arn

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_aws_region_west" {
  count = var.enable_eks_west ? 1 : 0

  name  = "engress-deploy-aws-region-west"
  type  = "String"
  value = "us-west-1"

  tags = var.tags
}

resource "aws_ssm_parameter" "deploy_global_accelerator_ips" {
  count = var.enable_global_accelerator ? 1 : 0

  name  = "engress-deploy-global-accelerator-ips"
  type  = "String"
  value = join(",", aws_globalaccelerator_accelerator.edge[0].ip_sets[0].ip_addresses)

  tags = var.tags
}

output "deploy_config_ssm_parameters" {
  value = compact([
    aws_ssm_parameter.deploy_github_role_arn.name,
    aws_ssm_parameter.deploy_edge_ip.name,
    aws_ssm_parameter.deploy_core_ip.name,
    aws_ssm_parameter.deploy_edge_host.name,
    aws_ssm_parameter.deploy_core_host.name,
    aws_ssm_parameter.deploy_target.name,
    var.enable_eks ? aws_ssm_parameter.deploy_eks_cluster_name[0].name : "",
    var.enable_eks ? aws_ssm_parameter.deploy_core_irsa_arn[0].name : "",
    var.enable_eks ? aws_ssm_parameter.deploy_edge_irsa_arn[0].name : "",
    var.enable_eks ? aws_ssm_parameter.deploy_lbc_irsa_arn[0].name : "",
    var.enable_eks_west ? aws_ssm_parameter.deploy_eks_west_cluster_name[0].name : "",
    var.enable_eks_west ? aws_ssm_parameter.deploy_edge_west_irsa_arn[0].name : "",
    var.enable_eks_west ? aws_ssm_parameter.deploy_core_west_irsa_arn[0].name : "",
    var.enable_eks_west ? aws_ssm_parameter.deploy_lbc_west_irsa_arn[0].name : "",
    var.enable_eks_west ? aws_ssm_parameter.deploy_aws_region_west[0].name : "",
    var.enable_global_accelerator ? aws_ssm_parameter.deploy_global_accelerator_ips[0].name : "",
  ])
  description = "SSM parameter names written for CI/CD (read via scripts/deploy/lib/ssm-deploy-config.sh)"
}
