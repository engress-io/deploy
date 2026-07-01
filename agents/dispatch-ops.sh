#!/usr/bin/env bash
# Dispatch engress ops via GitHub Actions (deploy submodule).
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ENGRESS_DEPLOY_ROOT="$DEPLOY_ROOT"

usage() {
  cat <<'EOF'
Usage: dispatch-ops.sh <action> [stack=eks-east] [value=eks]

Terraform (SSM tfvars only — no partial enable_* overrides):
  plan-stack stack=<name>     Plan one stack (eks-east, eks-west, edge-routing, ...)
  apply-stack stack=<name>    Apply one stack (plan-guard enforced)
  plan-foundation             Plan full foundation (alias: plan-eks)
  apply-foundation          Apply full foundation (alias: apply-eks)
  plan-eks / apply-eks      Deprecated aliases
  plan-eks-west / apply-eks-west / plan-ga / apply-ga  Deprecated stack aliases
  audit-ssm-tfvars          Verify SSM engress-terraform-tfvars flags
  decommission-ec2          EC2 teardown (explicit vars only)
  recover-frontend          CloudFront/SPA recovery

Workloads (prefer component-scoped actions):
  helm-deploy-core    Helm upgrade engress-core only (east)
  helm-deploy-edge    Helm upgrade engress-edge (east + west)
  helm-deploy-east    Helm upgrade both charts (east only)
  helm-deploy-staging Helm upgrade both charts (staging east)
  helm-deploy         Helm upgrade both charts (east) — alias for helm-deploy-east
  helm-deploy-west    Helm upgrade edge only (west)
  helm-deploy-all     Full east + west (manual reconcile only)
  spa-deploy          Build SPA + S3 sync + CloudFront invalidation only
  docs-deploy         Build Docusaurus + S3 sync under docs/ + CF invalidation
  install-addons / install-addons-west
  p05-prereqs-check / smoke-test / clerk-refresh
  dns-audit / dns-cutover-ga / dns-cutover-ga-apply / p03-rollout
  fix-lbs / fix-lbs-west / deploy-target value=eks

See deploy/docs/deployment-matrix.md for path → action rules.
EOF
}

VALID_ACTIONS=(
  plan-stack apply-stack plan-foundation apply-foundation audit-ssm-tfvars
  plan-eks apply-eks plan-eks-west apply-eks-west plan-ga apply-ga
  install-addons install-addons-west p05-prereqs-check
  helm-deploy helm-deploy-core helm-deploy-edge helm-deploy-east helm-deploy-staging helm-deploy-west helm-deploy-all
  spa-deploy docs-deploy
  kubectl-status kubectl-status-west core-rollback dns-audit dns-cutover-ga dns-cutover-ga-apply
  p03-rollout fix-lbs fix-lbs-west deploy-target smoke-test decommission-ec2 recover-frontend clerk-refresh
)

ACTION="${1:-}"
if [[ -z "$ACTION" || "$ACTION" == "-h" || "$ACTION" == "--help" ]]; then
  usage
  exit "$([[ -z "$ACTION" ]] && echo 1 || echo 0)"
fi

valid=0
for a in "${VALID_ACTIONS[@]}"; do
  [[ "$ACTION" == "$a" ]] && valid=1 && break
done
if [[ "$valid" -ne 1 ]]; then
  echo "ERROR: unknown action: $ACTION" >&2
  usage >&2
  exit 1
fi

case "$ACTION" in
  helm-deploy-all|apply-foundation|p03-rollout|fix-lbs)
    echo "WARN: full-scope action '${ACTION}' — confirm this is intentional (see deploy/docs/deployment-matrix.md)" >&2
    ;;
esac

shift || true
GH_REPO="${GH_REPO:-engress-io/engress}"
DEPLOY_TARGET="both"
DNS_APPLY="false"
STACK=""
EXTRA_ARGS=()
for kv in "$@"; do
  case "$kv" in
    value=*) DEPLOY_TARGET="${kv#value=}" ;;
    deploy_target=*) DEPLOY_TARGET="${kv#deploy_target=}" ;;
    stack=*) STACK="${kv#stack=}" ;;
    dns=apply) DNS_APPLY="true" ;;
    *) EXTRA_ARGS+=("$kv") ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${GITHUB_ACTIONS:-}${CI:-}" ]] && command -v aws >/dev/null 2>&1 && aws sts get-caller-identity >/dev/null 2>&1; then
  case "$ACTION" in
    audit-ssm-tfvars)
      exec "$DEPLOY_ROOT/scripts/terraform/audit-ssm-tfvars.sh"
      ;;
    plan-stack|apply-stack)
      [[ -n "$STACK" ]] || { echo "stack= required" >&2; exit 1; }
      mode=apply
      [[ "$ACTION" == plan-stack ]] && mode=plan
      exec "$DEPLOY_ROOT/scripts/terraform/apply-stack.sh" "$mode" "$STACK" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
      ;;
    decommission-ec2|recover-frontend|apply-foundation|plan-foundation|apply-eks|plan-eks|apply-eks-west|plan-eks-west|apply-ga|plan-ga)
      OPS_TF="$DEPLOY_ROOT/scripts/terraform/ops-terraform.sh"
      echo "Running Terraform locally ($ACTION)"
      exec "$OPS_TF" "$ACTION" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
      ;;
    dns-cutover-ga|dns-cutover-ga-apply)
      GA_DNS="$DEPLOY_ROOT/scripts/workload/phase-b-dns-ga.sh"
      [[ "$ACTION" == "dns-cutover-ga-apply" ]] && exec "$GA_DNS" --apply || exec "$GA_DNS" --dry-run
      ;;
    clerk-refresh)
      exec "$SCRIPT_DIR/clerk-auth.sh" refresh
      ;;
    helm-deploy-east|helm-deploy|helm-deploy-core)
      exec "$DEPLOY_ROOT/scripts/workload/helm-deploy-eks-east.sh" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
      ;;
    helm-deploy-staging)
      exec "$DEPLOY_ROOT/scripts/workload/helm-deploy-eks-staging.sh" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
      ;;
    helm-deploy-edge)
      exec "$DEPLOY_ROOT/scripts/workload/helm-deploy-eks-east.sh" --edge-only
      exec "$DEPLOY_ROOT/scripts/workload/helm-deploy-eks-west.sh"
      ;;
    helm-deploy-west)
      exec "$DEPLOY_ROOT/scripts/workload/helm-deploy-eks-west.sh" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
      ;;
    smoke-test)
      exec "$DEPLOY_ROOT/scripts/smoke/smoke-test.sh"
      ;;
  esac
fi

command -v gh >/dev/null 2>&1 || { echo "gh required" >&2; exit 1; }
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

payload_stack() {
  if [[ -n "$STACK" ]]; then
    echo "\"stack\": \"${STACK}\","
  fi
}

gh api "repos/${GH_REPO}/dispatches" --method POST --input - <<EOF
{
  "event_type": "ops",
  "client_payload": {
    "action": "${ACTION}",
    $(payload_stack)
    "deploy_target": "${DEPLOY_TARGET}",
    "dns_apply": ${DNS_APPLY}
  }
}
EOF

sleep 8
RUN_ID="$(gh run list -R "$GH_REPO" --workflow=ops.yml --limit 1 --json databaseId -q '.[0].databaseId')"
echo "Run: https://github.com/${GH_REPO}/actions/runs/${RUN_ID}"
gh run watch "$RUN_ID" -R "$GH_REPO" --exit-status
