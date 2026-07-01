#!/usr/bin/env bash
# Upload tfvars example to SSM (prod: engress-terraform-tfvars, staging: engress-terraform-tfvars-staging).
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${1:-$DEPLOY_ROOT/terraform/env/prod.tfvars.example}"
SSM_NAME="${2:-engress-terraform-tfvars}"
AWS_REGION="${AWS_REGION:-us-east-2}"

[[ -f "$SRC" ]] || { echo "missing: $SRC" >&2; exit 1; }

aws ssm put-parameter \
  --name "$SSM_NAME" \
  --type SecureString \
  --overwrite \
  --region "$AWS_REGION" \
  --value "file://$SRC"

echo "Uploaded $SRC → SSM $SSM_NAME ($AWS_REGION)"
