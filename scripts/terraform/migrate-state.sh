#!/usr/bin/env bash
# Backup monolith state and document per-stack state migration (operator maintenance window).
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/scripts/lib/workspace.sh"
engress_export_workspace

TF_DIR="$ENGRESS_TF_DIR"
BACKUP_PREFIX="${BACKUP_PREFIX:-engress/terraform-backups/$(date -u +%Y%m%dT%H%M%SZ)}"
BUCKET="${TF_STATE_BUCKET:-engress-terraform-state-327796148992}"

echo "=== Terraform state backup ==="
cd "$TF_DIR"
terraform init -input=false
aws s3 cp "s3://${BUCKET}/engress/core/terraform.tfstate" \
  "s3://${BUCKET}/${BACKUP_PREFIX}/monolith.tfstate"

cat <<EOF

Backup written to s3://${BUCKET}/${BACKUP_PREFIX}/monolith.tfstate

Per-stack migration (Phase 3) — run only after split .tf configs exist:
  1. terraform state mv 'module.vpc' ...           → network-east stack
  2. terraform state mv 'module.eks[0]' ...        → eks-east stack
  3. terraform state mv 'module.eks_west[0]' ...     → eks-west stack
  4. terraform state mv 'aws_globalaccelerator_*'  → edge-routing stack

Verify each step: terraform plan must show 0 changes in both old and new stacks.

Until migration completes, use:
  ./deploy/scripts/terraform/apply-stack.sh apply eks-east

EOF
