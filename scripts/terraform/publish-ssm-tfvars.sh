#!/usr/bin/env bash
# Upload canonical prod.tfvars.example to SSM engress-terraform-tfvars (one-time operator setup).
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${1:-$DEPLOY_ROOT/terraform/env/prod.tfvars.example}"
AWS_REGION="${AWS_REGION:-us-east-2}"

[[ -f "$SRC" ]] || { echo "missing: $SRC" >&2; exit 1; }

aws ssm put-parameter \
  --name engress-terraform-tfvars \
  --type SecureString \
  --overwrite \
  --region "$AWS_REGION" \
  --value "file://$SRC"

echo "Uploaded $SRC → SSM engress-terraform-tfvars ($AWS_REGION)"
