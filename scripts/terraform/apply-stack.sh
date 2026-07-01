#!/usr/bin/env bash
# Apply a single Terraform stack (targeted on legacy monolith until state split completes).
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ENGRESS_DEPLOY_ROOT="$DEPLOY_ROOT"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/scripts/lib/workspace.sh"

MODE="${1:?usage: apply-stack.sh plan|apply <stack>}"
STACK="${2:?stack name}"
shift 2 || true

ACTION="apply-stack"
if [[ "$MODE" == "plan" ]]; then
  ACTION="plan-stack"
fi

exec "$DEPLOY_ROOT/scripts/terraform/ops-terraform.sh" "$ACTION" "$STACK" "$@"
