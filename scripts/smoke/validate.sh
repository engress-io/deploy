#!/usr/bin/env bash
# validate.sh — P07B staging validation suite (smoke + API + TLS basics)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/ssm-deploy-config.sh"

STAGING_BASE="${ENGRESS_STAGING_BASE:-staging.engress.io}"
STAGING_EDGE="${ENGRESS_STAGING_EDGE:-edge.staging.engress.io}"
API_URL="${ENGRESS_SMOKE_API_URL:-https://${STAGING_BASE}/api/healthz}"

echo "==> P07B validate (base=${STAGING_BASE})"

"${SCRIPT_DIR}/smoke-test.sh"

echo "==> TLS on app origin"
curl -sfI "https://${STAGING_BASE}/" >/dev/null
echo "PASS: HTTPS app origin"

echo "==> API health JSON"
body=$(curl -sf "$API_URL")
echo "$body" | grep -q '"service":"engress-core"'
echo "PASS: API health"

if [[ -x "${SCRIPT_DIR}/stale-check.sh" ]]; then
  "${SCRIPT_DIR}/stale-check.sh" || true
fi

echo "==> validate.sh complete"
