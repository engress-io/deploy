#!/usr/bin/env bash
# Verify SSM engress-terraform-tfvars contains required production flags.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-2}"
FAIL=0

check_flag() {
  local name="$1"
  local expected="$2"
  if grep -qE "^[[:space:]]*${name}[[:space:]]*=[[:space:]]*${expected}" "$TMPVARS"; then
    echo "OK  ${name}=${expected}"
  else
    echo "FAIL ${name} must be ${expected} in engress-terraform-tfvars" >&2
    FAIL=1
  fi
}

TMPVARS="$(mktemp)"
trap 'rm -f "$TMPVARS"' EXIT

if ! aws ssm get-parameter --name engress-terraform-tfvars --with-decryption \
  --region "$AWS_REGION" --query 'Parameter.Value' --output text >"$TMPVARS" 2>/dev/null; then
  echo "FAIL engress-terraform-tfvars not found in SSM ($AWS_REGION)" >&2
  exit 1
fi

echo "=== SSM terraform.tfvars audit ==="
check_flag "enable_eks" "true"
check_flag "enable_eks_west" "true"
check_flag "enable_global_accelerator" "true"
check_flag "deploy_target" "\"eks\""

exit "$FAIL"
