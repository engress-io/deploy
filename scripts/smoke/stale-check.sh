#!/usr/bin/env bash
# stale-check.sh — fail when running image tag does not match expected SHA
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/ssm-deploy-config.sh"

EXPECTED_TAG="${IMAGE_TAG:-${ENGRESS_IMAGE_TAG:-}}"
CLUSTER="${ENGRESS_DEPLOY_EKS_CLUSTER:-}"
NAMESPACE="${NAMESPACE:-engress}"
AWS_REGION="${AWS_REGION:-us-east-2}"

if [[ -z "$EXPECTED_TAG" || -z "$CLUSTER" ]]; then
  echo "SKIP: stale-check (set IMAGE_TAG and cluster via SSM)"
  exit 0
fi

aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION" >/dev/null

check_deploy() {
  local deploy="$1"
  local required="${2:-1}"
  local running
  running=$(kubectl get deploy "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  if [[ -z "$running" ]]; then
    if [[ "$required" == "1" ]]; then
      echo "FAIL: $deploy not found in namespace ${NAMESPACE}" >&2
      return 1
    fi
    echo "SKIP: $deploy not found"
    return 0
  fi
  if [[ "$running" == *":${EXPECTED_TAG}" ]]; then
    echo "PASS: $deploy image tag matches ${EXPECTED_TAG}"
    return 0
  fi
  echo "FAIL: $deploy running $running (expected *:${EXPECTED_TAG})" >&2
  return 1
}

stale=0
check_deploy engress-core 1 || stale=1
# Edge may be unchanged on core-only deploys; still report mismatch when IMAGE_TAG is set.
check_deploy engress-edge 0 || stale=1

exit "$stale"
