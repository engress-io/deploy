#!/usr/bin/env bash
# validate.sh — P07B staging validation suite (smoke + version + binary checks)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/ssm-deploy-config.sh"

STAGING_BASE="${ENGRESS_STAGING_BASE:-staging.engress.io}"
API_URL="${ENGRESS_SMOKE_API_URL:-https://${STAGING_BASE}/api/healthz}"
EXPECTED_TAG="${IMAGE_TAG:-${ENGRESS_IMAGE_TAG:-}}"

echo "==> P07B validate (base=${STAGING_BASE}, tag=${EXPECTED_TAG:-unset})"

"${SCRIPT_DIR}/smoke-test.sh"

echo "==> TLS on app origin"
curl -sfI "https://${STAGING_BASE}/" >/dev/null
echo "PASS: HTTPS app origin"

echo "==> API health JSON"
body=$(curl -sf "$API_URL")
echo "$body" | grep -q '"service":"engress-core"'
echo "PASS: API health"

if [[ -n "$EXPECTED_TAG" ]]; then
  echo "==> API version matches ${EXPECTED_TAG}"
  echo "$body" | grep -q "\"version\":\"${EXPECTED_TAG}\"" \
    || { echo "FAIL: public API version mismatch (got: ${body})" >&2; exit 1; }
  echo "PASS: public API version"
fi

if [[ -x "${SCRIPT_DIR}/stale-check.sh" ]]; then
  "${SCRIPT_DIR}/stale-check.sh"
fi

if [[ -x "${SCRIPT_DIR}/validate-binary.sh" ]]; then
  "${SCRIPT_DIR}/validate-binary.sh"
fi

echo "==> validate.sh complete"
