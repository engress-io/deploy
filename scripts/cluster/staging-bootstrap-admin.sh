#!/usr/bin/env bash
# Bootstrap platform admin on staging engress-core (EKS).
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/scripts/lib/ssm-deploy-config.sh"

EMAIL="${1:-}"
if [[ -z "$EMAIL" ]]; then
  echo "Usage: $0 <email>" >&2
  echo "Example: $0 dave@engress.io" >&2
  echo "" >&2
  echo "User must exist in the STAGING Clerk app (sign up at https://staging.engress.io/sign-up first)." >&2
  exit 1
fi

REGION="${AWS_REGION:-us-east-2}"
CLUSTER="${ENGRESS_DEPLOY_EKS_CLUSTER:-engress-staging-east}"
NAMESPACE="${NAMESPACE:-engress}"

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
POD="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=engress-core \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$POD" ]] || { echo "ERROR: no engress-core pod in ${NAMESPACE}" >&2; exit 1; }

echo "==> bootstrap platform admin ${EMAIL} on ${CLUSTER}/${POD}"
kubectl exec -n "$NAMESPACE" "$POD" -- \
  engress-core admin bootstrap-platform-admin --email "${EMAIL}"
