#!/usr/bin/env bash
# Recover engress.io after a bad decommission apply.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/deploy/lib/workspace.sh"
# shellcheck source=/dev/null
source "$ROOT/deploy/lib/terraform-tfvars.sh"
engress_export_workspace

cd "$ENGRESS_TF_DIR"
export ENGRESS_ADMIN_EMAIL="${ENGRESS_ADMIN_EMAIL:-walter@ghostweasel.net}"
engress_ensure_terraform_tfvars terraform.tfvars
exec ./fix-cloudfront-recovery.sh
