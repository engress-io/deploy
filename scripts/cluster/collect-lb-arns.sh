#!/usr/bin/env bash
# Discover NLB/ALB ARNs from EKS clusters and write to SSM for Global Accelerator Terraform.
set -euo pipefail

SSM_REGION="${SSM_REGION:-us-east-2}"
EAST_CLUSTER="${EAST_CLUSTER:-engress-east}"
EAST_REGION="${EAST_REGION:-us-east-2}"
WEST_CLUSTER="${WEST_CLUSTER:-engress-west}"
WEST_REGION="${WEST_REGION:-us-west-1}"
NS="${NAMESPACE:-engress}"

_put_ssm() {
  local name="$1" value="$2"
  [[ -n "$value" && "$value" != "None" ]] || { echo "ERROR: empty value for $name" >&2; return 1; }
  aws ssm put-parameter --name "$name" --type String --value "$value" --overwrite --region "$SSM_REGION"
  echo "  SSM $name = $value"
}

_lb_arn_from_dns() {
  local dns="$1" region="$2"
  [[ -n "$dns" ]] || return 1
  aws elbv2 describe-load-balancers --region "$region" \
    --query "LoadBalancers[?DNSName=='${dns}'].LoadBalancerArn | [0]" --output text 2>/dev/null
}

_collect_cluster() {
  local cluster="$1" region="$2" prefix="$3"
  echo "==> $cluster ($region)"
  aws eks update-kubeconfig --name "$cluster" --region "$region" >/dev/null

  local nlb_dns edge_alb_dns nlb_arn edge_alb_arn
  nlb_dns="$(kubectl get svc engress-edge-nlb -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  edge_alb_dns="$(kubectl get ingress engress-edge -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

  nlb_arn="$(_lb_arn_from_dns "$nlb_dns" "$region")"
  edge_alb_arn="$(_lb_arn_from_dns "$edge_alb_dns" "$region")"

  echo "  NLB DNS: $nlb_dns"
  echo "  Edge ALB DNS: $edge_alb_dns"

  _put_ssm "engress-deploy-${prefix}-nlb-arn" "$nlb_arn"
  _put_ssm "engress-deploy-${prefix}-edge-alb-arn" "$edge_alb_arn"
}

echo "=== Collect LB ARNs for Global Accelerator ==="
_collect_cluster "$EAST_CLUSTER" "$EAST_REGION" "east"
_collect_cluster "$WEST_CLUSTER" "$WEST_REGION" "west"
echo "Done. Run: terraform apply -var='enable_global_accelerator=true'"
