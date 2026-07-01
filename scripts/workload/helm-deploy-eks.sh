#!/usr/bin/env bash
# Deploy engress-core and/or engress-edge Helm releases to EKS (east or staging).
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ENGRESS_DEPLOY_ROOT="$DEPLOY_ROOT"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/scripts/lib/workspace.sh"
engress_export_workspace
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/scripts/lib/ssm-deploy-config.sh"

AWS_REGION="${AWS_REGION:-us-east-2}"
ENGRESS_DEPLOY_EKS_CLUSTER="${ENGRESS_DEPLOY_EKS_CLUSTER:-engress-east}"
EDGE_VALUES=()
CORE_VALUES=()
DEPLOY_CORE=1
DEPLOY_EDGE=1
EDGE_IRSA="${ENGRESS_DEPLOY_EDGE_IRSA_ARN:-}"
CORE_IRSA="${ENGRESS_DEPLOY_CORE_IRSA_ARN:-}"
EDGE_HOST="${ENGRESS_DEPLOY_EDGE_HOST:-edge-origin-east.engress.io}"
CORE_HOST="${ENGRESS_DEPLOY_CORE_HOST:-core-origin-east.engress.io}"

CHARTS_ROOT="${ENGRESS_CHARTS_ROOT:-${ENGRESS_DEPLOY_ROOT:-}/helm}"
if [[ -z "$CHARTS_ROOT" || ! -d "$CHARTS_ROOT" ]]; then
  CHARTS_ROOT="${ENGRESS_WORKSPACE_ROOT:-$(engress_workspace_root)}/charts"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      export ENGRESS_ENV="$2"
      shift 2
      # shellcheck source=/dev/null
      source "$DEPLOY_ROOT/scripts/lib/ssm-deploy-config.sh"
      ENGRESS_DEPLOY_EKS_CLUSTER="${ENGRESS_DEPLOY_EKS_CLUSTER:-engress-east}"
      EDGE_IRSA="${ENGRESS_DEPLOY_EDGE_IRSA_ARN:-}"
      CORE_IRSA="${ENGRESS_DEPLOY_CORE_IRSA_ARN:-}"
      EDGE_HOST="${ENGRESS_DEPLOY_EDGE_HOST:-edge-origin-east.engress.io}"
      CORE_HOST="${ENGRESS_DEPLOY_CORE_HOST:-core-origin-east.engress.io}"
      ;;
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    --cluster)
      ENGRESS_DEPLOY_EKS_CLUSTER="$2"
      shift 2
      ;;
    --values-east)
      EDGE_VALUES+=(-f "$CHARTS_ROOT/engress-edge/values-east.yaml")
      CORE_VALUES+=(-f "$CHARTS_ROOT/engress-core/values-east.yaml")
      shift
      ;;
    --values-west)
      EDGE_VALUES+=(-f "$CHARTS_ROOT/engress-edge/values-west.yaml")
      CORE_VALUES+=(-f "$CHARTS_ROOT/engress-core/values-west.yaml")
      shift
      ;;
    --values-staging)
      EDGE_VALUES+=(-f "$CHARTS_ROOT/engress-edge/values-staging.yaml")
      CORE_VALUES+=(-f "$CHARTS_ROOT/engress-core/values-staging.yaml")
      shift
      ;;
    --values)
      EDGE_VALUES+=(-f "$2")
      CORE_VALUES+=(-f "$2")
      shift 2
      ;;
    --edge-only)
      DEPLOY_CORE=0
      shift
      ;;
    --core-only)
      DEPLOY_EDGE=0
      shift
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

# Default value overlays by environment
if [[ ${#EDGE_VALUES[@]} -eq 0 ]]; then
  if [[ "${ENGRESS_ENV:-prod}" == "staging" ]]; then
    EDGE_VALUES+=(-f "$CHARTS_ROOT/engress-edge/values-staging.yaml")
    CORE_VALUES+=(-f "$CHARTS_ROOT/engress-core/values-staging.yaml")
  else
    EDGE_VALUES+=(-f "$CHARTS_ROOT/engress-edge/values-east.yaml")
    CORE_VALUES+=(-f "$CHARTS_ROOT/engress-core/values-east.yaml")
  fi
fi

IMAGE_TAG="${IMAGE_TAG:-$(git -C "$ENGRESS_CORE_ROOT" rev-parse --short HEAD 2>/dev/null || echo latest)}"
NAMESPACE="${NAMESPACE:-engress}"

# Load west-specific SSM when deploying to us-west-1
if [[ "$AWS_REGION" == "us-west-1" ]]; then
  _ssm_west() {
    aws ssm get-parameter --name "$1" --region us-east-2 --query 'Parameter.Value' --output text 2>/dev/null || true
  }
  local_prefix="${ENGRESS_DEPLOY_SSM_PREFIX:-engress-deploy}"
  ENGRESS_DEPLOY_EKS_CLUSTER="${ENGRESS_DEPLOY_EKS_CLUSTER:-$(_ssm_west "${local_prefix}-eks-west-cluster-name")}"
  EDGE_IRSA="${EDGE_IRSA:-$(_ssm_west "${local_prefix}-edge-west-irsa-arn")}"
  CORE_IRSA="${CORE_IRSA:-$(_ssm_west "${local_prefix}-core-west-irsa-arn")}"
  EDGE_HOST="${EDGE_HOST:-edge-origin-west.engress.io}"
  if [[ ${#EDGE_VALUES[@]} -eq 0 || "${EDGE_VALUES[*]}" != *values-west* ]]; then
    EDGE_VALUES+=(-f "$CHARTS_ROOT/engress-edge/values-west.yaml")
  fi
  DEPLOY_CORE="${DEPLOY_WEST_CORE:-0}"
fi

: "${ENGRESS_DEPLOY_EKS_CLUSTER:?set ENGRESS_DEPLOY_EKS_CLUSTER or run terraform apply with enable_eks=true}"

aws eks update-kubeconfig --name "$ENGRESS_DEPLOY_EKS_CLUSTER" --region "$AWS_REGION"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if helm status engress-core -n "$NAMESPACE" 2>/dev/null | grep -qi pending; then
  echo "WARN: clearing pending engress-core helm release"
  helm rollback engress-core -n "$NAMESPACE" || true
fi

if [[ "$DEPLOY_CORE" -eq 1 ]]; then
  : "${CORE_IRSA:?missing core IRSA ARN in SSM}"
  helm upgrade --install engress-core "$CHARTS_ROOT/engress-core" \
    --namespace "$NAMESPACE" \
    ${CORE_VALUES[@]+"${CORE_VALUES[@]}"} \
    --set "image.tag=${IMAGE_TAG}" \
    --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${CORE_IRSA}" \
    --set "ingress.hosts[0].host=${CORE_HOST}" \
    --set "ingress.hosts[0].paths[0].path=/" \
    --set "ingress.hosts[0].paths[0].pathType=Prefix" \
    --wait --timeout 5m
fi

if [[ "$DEPLOY_EDGE" -eq 1 ]]; then
  helm upgrade --install engress-edge "$CHARTS_ROOT/engress-edge" \
    --namespace "$NAMESPACE" \
    ${EDGE_VALUES[@]+"${EDGE_VALUES[@]}"} \
    --set "image.tag=${IMAGE_TAG}" \
    --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${EDGE_IRSA}" \
    --set "ingress.hosts[0].host=${EDGE_HOST}" \
    --set "ingress.hosts[0].paths[0].path=/" \
    --set "ingress.hosts[0].paths[0].pathType=Prefix" \
    --set "config.controlOriginHost=${EDGE_HOST}" \
    --wait --timeout 5m
fi

if [[ "$DEPLOY_CORE" -eq 1 ]]; then
  kubectl rollout status "deployment/engress-core" -n "$NAMESPACE" --timeout=120s
fi
if [[ "$DEPLOY_EDGE" -eq 1 ]]; then
  kubectl rollout status "deployment/engress-edge" -n "$NAMESPACE" --timeout=120s
fi

echo "Helm deploy complete (env=${ENGRESS_ENV:-prod}, tag=${IMAGE_TAG}, cluster=${ENGRESS_DEPLOY_EKS_CLUSTER}, region=${AWS_REGION})"
