#!/usr/bin/env bash
# Load deploy configuration from SSM Parameter Store.
# Set ENGRESS_ENV=prod|staging (default prod).
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-2}"
ENGRESS_ENV="${ENGRESS_ENV:-prod}"

if [[ "$ENGRESS_ENV" == "staging" ]]; then
  SSM_PREFIX="engress-staging-deploy"
else
  SSM_PREFIX="engress-deploy"
fi

_ssm() {
  local name="$1"
  aws ssm get-parameter \
    --name "$name" \
    --region "$AWS_REGION" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null || true
}

_ssm_or_legacy() {
  local primary="$1"
  local legacy="${2:-}"
  local v
  v="$(_ssm "$primary")"
  if [[ -n "$v" && "$v" != "None" ]]; then
    echo "$v"
    return
  fi
  if [[ -n "$legacy" ]]; then
    _ssm "$legacy"
  fi
}

export ENGRESS_ENV
export ENGRESS_DEPLOY_SSM_PREFIX="$SSM_PREFIX"
export ENGRESS_DEPLOY_GITHUB_ROLE_ARN="${ENGRESS_DEPLOY_GITHUB_ROLE_ARN:-$(_ssm "${SSM_PREFIX}-github-role-arn")}"
export ENGRESS_DEPLOY_TARGET="${ENGRESS_DEPLOY_TARGET:-$(_ssm "${SSM_PREFIX}-target")}"
export ENGRESS_DEPLOY_EDGE_IP="${ENGRESS_DEPLOY_EDGE_IP:-$(_ssm "${SSM_PREFIX}-edge-ip")}"
export ENGRESS_DEPLOY_CORE_IP="${ENGRESS_DEPLOY_CORE_IP:-$(_ssm "${SSM_PREFIX}-core-ip")}"
export ENGRESS_DEPLOY_EDGE_HOST="${ENGRESS_DEPLOY_EDGE_HOST:-$(_ssm "${SSM_PREFIX}-edge-host")}"
export ENGRESS_DEPLOY_CORE_HOST="${ENGRESS_DEPLOY_CORE_HOST:-$(_ssm "${SSM_PREFIX}-core-host")}"
export ENGRESS_DEPLOY_BASE_DOMAIN="${ENGRESS_DEPLOY_BASE_DOMAIN:-$(_ssm "${SSM_PREFIX}-base-domain")}"
export ENGRESS_DEPLOY_EKS_CLUSTER="${ENGRESS_DEPLOY_EKS_CLUSTER:-$(_ssm_or_legacy "${SSM_PREFIX}-eks-east-cluster-name" "engress-deploy-eks-cluster-name")}"
export ENGRESS_DEPLOY_CORE_IRSA_ARN="${ENGRESS_DEPLOY_CORE_IRSA_ARN:-$(_ssm_or_legacy "${SSM_PREFIX}-core-east-irsa-arn" "engress-deploy-core-irsa-arn")}"
export ENGRESS_DEPLOY_EDGE_IRSA_ARN="${ENGRESS_DEPLOY_EDGE_IRSA_ARN:-$(_ssm_or_legacy "${SSM_PREFIX}-edge-east-irsa-arn" "engress-deploy-edge-irsa-arn")}"
export ENGRESS_DEPLOY_LBC_IRSA_ARN="${ENGRESS_DEPLOY_LBC_IRSA_ARN:-$(_ssm_or_legacy "${SSM_PREFIX}-lbc-east-irsa-arn" "engress-deploy-lbc-irsa-arn")}"
export ENGRESS_DEPLOY_AWS_REGION_EAST="${ENGRESS_DEPLOY_AWS_REGION_EAST:-$(_ssm "${SSM_PREFIX}-aws-region-east")}"
export ENGRESS_DEPLOY_EKS_WEST_CLUSTER="${ENGRESS_DEPLOY_EKS_WEST_CLUSTER:-$(_ssm "${SSM_PREFIX}-eks-west-cluster-name")}"
export ENGRESS_DEPLOY_EDGE_WEST_IRSA_ARN="${ENGRESS_DEPLOY_EDGE_WEST_IRSA_ARN:-$(_ssm "${SSM_PREFIX}-edge-west-irsa-arn")}"
export ENGRESS_DEPLOY_CORE_WEST_IRSA_ARN="${ENGRESS_DEPLOY_CORE_WEST_IRSA_ARN:-$(_ssm "${SSM_PREFIX}-core-west-irsa-arn")}"
export ENGRESS_DEPLOY_LBC_WEST_IRSA_ARN="${ENGRESS_DEPLOY_LBC_WEST_IRSA_ARN:-$(_ssm "${SSM_PREFIX}-lbc-west-irsa-arn")}"
export ENGRESS_DEPLOY_AWS_REGION_WEST="${ENGRESS_DEPLOY_AWS_REGION_WEST:-$(_ssm "${SSM_PREFIX}-aws-region-west")}"
export ENGRESS_GA_IPS="${ENGRESS_GA_IPS:-$(_ssm "${SSM_PREFIX}-global-accelerator-ips")}"

# Back-compat aliases used by smoke-test.sh and legacy scripts
export ENGRESS_EDGE_IP="${ENGRESS_EDGE_IP:-${ENGRESS_DEPLOY_EDGE_IP:-}}"
export ENGRESS_CORE_IP="${ENGRESS_CORE_IP:-${ENGRESS_DEPLOY_CORE_IP:-}}"

# URL-based smoke defaults per environment
if [[ "$ENGRESS_ENV" == "staging" ]]; then
  export ENGRESS_SMOKE_BASE_URL="${ENGRESS_SMOKE_BASE_URL:-https://staging.engress.io}"
  export ENGRESS_SMOKE_API_URL="${ENGRESS_SMOKE_API_URL:-https://staging.engress.io/api/healthz}"
else
  export ENGRESS_SMOKE_BASE_URL="${ENGRESS_SMOKE_BASE_URL:-https://engress.io}"
  export ENGRESS_SMOKE_API_URL="${ENGRESS_SMOKE_API_URL:-https://engress.io/api/healthz}"
fi
