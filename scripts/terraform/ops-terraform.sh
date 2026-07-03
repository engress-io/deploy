#!/usr/bin/env bash
# Terraform wrapper for CI / ops workflow. Uses SSM tfvars only — no -var enable_* overrides.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ENGRESS_DEPLOY_ROOT="$ROOT"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/workspace.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/terraform-tfvars.sh"
engress_export_workspace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_GUARD="${PLAN_GUARD:-$ROOT/scripts/guards/plan-guard.sh}"

TF_DIR="${ENGRESS_TF_DIR:-$ENGRESS_DEPLOY_ROOT/terraform/_legacy-monolith}"
if [[ ! -d "$TF_DIR" ]]; then
  TF_DIR="$ENGRESS_TF_DIR"
fi

ACTION="${1:?usage: ops-terraform.sh plan|apply|plan-stack|apply-stack|...}"
shift
AWS_REGION="${AWS_REGION:-us-east-2}"
PLAN_FILE="${PLAN_FILE:-terraform.plan.bin}"

cd "$TF_DIR"
export ENGRESS_ADMIN_EMAIL="${ENGRESS_ADMIN_EMAIL:-walter@ghostweasel.net}"
engress_ensure_terraform_tfvars terraform.tfvars

BACKEND_KEY="${ENGRESS_TFSTATE_KEY:-engress/core/terraform.tfstate}"
if [[ "${ENGRESS_ENV:-prod}" == "staging" ]]; then
  BACKEND_KEY="${ENGRESS_TFSTATE_KEY:-engress/deploy/staging/terraform.tfstate}"
fi
terraform init -input=false -reconfigure -backend-config="key=${BACKEND_KEY}"

# Optional: validate SSM canonical flags before mutating applies
if [[ "$ACTION" == apply* ]] && [[ -x "$SCRIPT_DIR/audit-ssm-tfvars.sh" ]]; then
  bash "$SCRIPT_DIR/audit-ssm-tfvars.sh" || true
fi

stack_targets() {
  local stack="$1"
  case "$stack" in
    bootstrap)     echo "-target=aws_s3_bucket.terraform_state" ;;
    network-east)  echo "-target=module.vpc" ;;
    network-west)  echo "-target=module.vpc_west" ;;
    eks-east)      echo "-target=module.eks -target=module.engress_core_irsa -target=module.engress_edge_irsa -target=module.aws_load_balancer_controller_irsa -target=aws_iam_role_policy.engress_core_oasis_dashboard" ;;
    eks-west)      echo "-target=module.eks_west -target=module.engress_edge_irsa_west -target=module.aws_load_balancer_controller_irsa_west" ;;
    edge-routing)  echo "-target=aws_globalaccelerator_accelerator.edge -target=aws_globalaccelerator_listener.edge -target=aws_globalaccelerator_endpoint_group.edge_east -target=aws_globalaccelerator_endpoint_group.edge_west" ;;
    frontend)      echo "-target=aws_s3_bucket.frontend -target=aws_cloudfront_distribution.frontend" ;;
    deploy-config) echo "-target=aws_ssm_parameter.deploy_target" ;;
    foundation|legacy|"") echo "" ;;
    *)
      echo "unknown stack: $stack" >&2
      return 1
      ;;
  esac
}

run_plan() {
  local extra=("$@")
  terraform plan -input=false -var-file=terraform.tfvars -out="$PLAN_FILE" "${extra[@]}"
}

run_apply() {
  local extra=("$@")
  run_plan "${extra[@]}"
  if [[ -x "$PLAN_GUARD" ]]; then
    bash "$PLAN_GUARD" "$PLAN_FILE"
  fi
  terraform apply -input=false "$PLAN_FILE"
}

case "$ACTION" in
  plan)
    run_plan "$@"
    ;;
  apply)
    run_apply "$@"
    ;;
  plan-stack)
    STACK="${1:?stack name}"
    shift
    # shellcheck disable=SC2207
    TARGETS=($(stack_targets "$STACK"))
    run_plan "${TARGETS[@]}" "$@"
    ;;
  apply-stack)
    STACK="${1:?stack name}"
    shift
    # shellcheck disable=SC2207
    TARGETS=($(stack_targets "$STACK"))
    run_apply "${TARGETS[@]}" "$@"
    ;;
  plan-foundation|plan-eks)
    echo "WARN: plan-eks is deprecated — use plan-stack foundation or plan" >&2
    run_plan "$@"
    ;;
  apply-foundation|apply-eks)
    echo "WARN: apply-eks is deprecated — use apply-stack or apply (full SSM tfvars)" >&2
    run_apply "$@"
    ;;
  plan-eks-west)
    echo "WARN: plan-eks-west is deprecated — use plan-stack eks-west" >&2
    # shellcheck disable=SC2207
    TARGETS=($(stack_targets eks-west))
    run_plan "${TARGETS[@]}" "$@"
    ;;
  apply-eks-west)
    echo "WARN: apply-eks-west is deprecated — use apply-stack eks-west" >&2
    # shellcheck disable=SC2207
    TARGETS=($(stack_targets eks-west))
    run_apply "${TARGETS[@]}" "$@"
    ;;
  plan-ga)
    echo "WARN: plan-ga is deprecated — use plan-stack edge-routing" >&2
    # shellcheck disable=SC2207
    TARGETS=($(stack_targets edge-routing))
    run_plan "${TARGETS[@]}" "$@"
    ;;
  apply-ga)
    echo "WARN: apply-ga is deprecated — use apply-stack edge-routing" >&2
    # shellcheck disable=SC2207
    TARGETS=($(stack_targets edge-routing))
    run_apply "${TARGETS[@]}" "$@"
    ;;
  decommission-ec2)
    run_apply \
      -var="decommission_ec2=true" \
      -var="enable_frontend=true" \
      -var="enable_control_instance=true" \
      -var="spa_bucket_name=flux-spa-327796148992" \
      "$@"
    ;;
  recover-frontend)
    exec "$ROOT/scripts/workload/recover-frontend-terraform.sh"
    ;;
  *)
    echo "unknown action: $ACTION" >&2
    exit 1
    ;;
esac
