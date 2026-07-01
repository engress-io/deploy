#!/usr/bin/env bash
# P05/Oasis Phase 0 — verify observability prerequisites (no Datadog).
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-2}"
FAIL=0

check() {
  local label="$1"
  shift
  if "$@"; then
    echo "OK  $label"
  else
    echo "FAIL $label"
    FAIL=1
  fi
}

warn() { echo "WARN $1"; }

echo "=== Oasis dashboard prerequisites check ==="
echo

check "EKS east cluster SSM param" aws ssm get-parameter \
  --name engress-deploy-eks-cluster-name --region "$AWS_REGION" >/dev/null 2>&1

check "deploy target is eks" bash -c '
  t=$(aws ssm get-parameter --name engress-deploy-target --region '"$AWS_REGION"' --query Parameter.Value --output text 2>/dev/null)
  [[ "$t" == "eks" ]]
'

check "metrics ingest secret in SSM" aws ssm get-parameter \
  --name engress-metrics-ingest-secret --with-decryption --region "$AWS_REGION" >/dev/null 2>&1

if aws ssm get-parameter --name engress-deploy-eks-west-cluster-name --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "OK  West EKS cluster SSM param"
else
  warn "West EKS cluster not in SSM"
fi

check "core healthz reachable" curl -sf --max-time 15 https://engress.io/api/healthz >/dev/null

echo
echo "Manual checks (operator):"
echo "  - Renovate GitHub App on engress-io org (optional)"
echo "  - DOWNSTREAM_DISPATCH_TOKEN on engress-io/sdk (optional)"
echo "  - Terraform apply for engress-core IRSA oasis-dashboard policy (Cost Explorer + EKS read)"
echo

exit "$FAIL"
