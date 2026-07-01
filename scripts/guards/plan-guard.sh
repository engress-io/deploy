#!/usr/bin/env bash
# Fail Terraform plans that destroy protected foundation resources.
# Usage: plan-guard.sh <plan.bin>
set -euo pipefail

PLAN="${1:?usage: plan-guard.sh <plan.bin>}"
ALLOW="${ALLOW_INFRA_DESTROY:-0}"

if [[ ! -f "$PLAN" ]]; then
  echo "ERROR: plan file not found: $PLAN" >&2
  exit 1
fi

if ! command -v terraform >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: terraform and jq required" >&2
  exit 1
fi

PROTECTED_TYPES='aws_eks_cluster|aws_eks_node_group|aws_globalaccelerator_accelerator|aws_globalaccelerator_listener|aws_globalaccelerator_endpoint_group|aws_vpc|aws_s3_bucket|aws_cloudfront_distribution'

mapfile -t DESTROYS < <(
  terraform show -json "$PLAN" | jq -r --arg re "$PROTECTED_TYPES" '
    .resource_changes[]?
    | select(.change.actions[]? == "delete")
    | select(.type | test($re))
    | "\(.type) \(.address)"
  '
)

if [[ ${#DESTROYS[@]} -eq 0 ]]; then
  echo "plan-guard: OK (no protected resource destroys)"
  exit 0
fi

echo "plan-guard: protected resource(s) slated for DESTROY:" >&2
printf '  - %s\n' "${DESTROYS[@]}" >&2

if [[ "$ALLOW" == "1" ]]; then
  echo "plan-guard: ALLOW_INFRA_DESTROY=1 — proceeding" >&2
  exit 0
fi

echo "plan-guard: blocked — set ALLOW_INFRA_DESTROY=1 to override" >&2
exit 1
