#!/usr/bin/env bash
# Load deploy configuration from SSM Parameter Store.
# CI reads these after OIDC auth — avoids duplicating infra outputs as GitHub secrets.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-2}"

_ssm() {
  local name="$1"
  aws ssm get-parameter \
    --name "$name" \
    --region "$AWS_REGION" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null || true
}

export ENGRESS_DEPLOY_GITHUB_ROLE_ARN="${ENGRESS_DEPLOY_GITHUB_ROLE_ARN:-$(_ssm engress-deploy-github-role-arn)}"
export ENGRESS_DEPLOY_TARGET="${ENGRESS_DEPLOY_TARGET:-$(_ssm engress-deploy-target)}"
export ENGRESS_DEPLOY_EDGE_IP="${ENGRESS_DEPLOY_EDGE_IP:-$(_ssm engress-deploy-edge-ip)}"
export ENGRESS_DEPLOY_CORE_IP="${ENGRESS_DEPLOY_CORE_IP:-$(_ssm engress-deploy-core-ip)}"
export ENGRESS_DEPLOY_EDGE_HOST="${ENGRESS_DEPLOY_EDGE_HOST:-$(_ssm engress-deploy-edge-host)}"
export ENGRESS_DEPLOY_CORE_HOST="${ENGRESS_DEPLOY_CORE_HOST:-$(_ssm engress-deploy-core-host)}"
export ENGRESS_DEPLOY_EKS_CLUSTER="${ENGRESS_DEPLOY_EKS_CLUSTER:-$(_ssm engress-deploy-eks-cluster-name)}"
export ENGRESS_DEPLOY_CORE_IRSA_ARN="${ENGRESS_DEPLOY_CORE_IRSA_ARN:-$(_ssm engress-deploy-core-irsa-arn)}"
export ENGRESS_DEPLOY_EDGE_IRSA_ARN="${ENGRESS_DEPLOY_EDGE_IRSA_ARN:-$(_ssm engress-deploy-edge-irsa-arn)}"
export ENGRESS_DEPLOY_LBC_IRSA_ARN="${ENGRESS_DEPLOY_LBC_IRSA_ARN:-$(_ssm engress-deploy-lbc-irsa-arn)}"
export ENGRESS_DEPLOY_EKS_WEST_CLUSTER="${ENGRESS_DEPLOY_EKS_WEST_CLUSTER:-$(_ssm engress-deploy-eks-west-cluster-name)}"
export ENGRESS_DEPLOY_EDGE_WEST_IRSA_ARN="${ENGRESS_DEPLOY_EDGE_WEST_IRSA_ARN:-$(_ssm engress-deploy-edge-west-irsa-arn)}"
export ENGRESS_DEPLOY_CORE_WEST_IRSA_ARN="${ENGRESS_DEPLOY_CORE_WEST_IRSA_ARN:-$(_ssm engress-deploy-core-west-irsa-arn)}"
export ENGRESS_DEPLOY_LBC_WEST_IRSA_ARN="${ENGRESS_DEPLOY_LBC_WEST_IRSA_ARN:-$(_ssm engress-deploy-lbc-west-irsa-arn)}"
export ENGRESS_DEPLOY_AWS_REGION_WEST="${ENGRESS_DEPLOY_AWS_REGION_WEST:-$(_ssm engress-deploy-aws-region-west)}"
export ENGRESS_GA_IPS="${ENGRESS_GA_IPS:-$(_ssm engress-deploy-global-accelerator-ips)}"

# Back-compat aliases used by smoke-test.sh and legacy scripts
export ENGRESS_EDGE_IP="${ENGRESS_EDGE_IP:-${ENGRESS_DEPLOY_EDGE_IP:-}}"
export ENGRESS_CORE_IP="${ENGRESS_CORE_IP:-${ENGRESS_DEPLOY_CORE_IP:-}}"
