#!/usr/bin/env bash
# smoke-test.sh — verify deploy health (EC2 IP or HTTPS URL per environment)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/ssm-deploy-config.sh"

MAX_RETRIES=10
RETRY_SLEEP=6

check_health() {
  local name="$1" url="$2" expect="$3"
  local attempt=1
  while [ "$attempt" -le "$MAX_RETRIES" ]; do
    local body
    body=$(curl -sf "$url" || echo "FAIL")
    if echo "$body" | grep -q "$expect"; then
      echo "PASS: $name healthy (attempt $attempt)"
      return 0
    fi
    echo "  attempt $attempt/$MAX_RETRIES: $name not ready yet..."
    sleep "$RETRY_SLEEP"
    attempt=$((attempt + 1))
  done
  echo "FAIL: $name did not become healthy after $MAX_RETRIES attempts"
  return 1
}

if [[ -n "${ENGRESS_SMOKE_API_URL:-}" && "${ENGRESS_ENV:-prod}" != "ec2" ]]; then
  echo "=== API health (${ENGRESS_ENV:-prod}) ==="
  check_health "api" "${ENGRESS_SMOKE_API_URL}" '"service":"engress-core"'
  echo "=== All checks passed ==="
  exit 0
fi

ENGRESS_EDGE_IP="${ENGRESS_EDGE_IP:-${ENGRESS_DEPLOY_EDGE_IP:-}}"
ENGRESS_CORE_IP="${ENGRESS_CORE_IP:-${ENGRESS_DEPLOY_CORE_IP:-}}"

: "${ENGRESS_EDGE_IP:?set ENGRESS_EDGE_IP or engress-deploy-edge-ip in SSM}"
: "${ENGRESS_CORE_IP:?set ENGRESS_CORE_IP or engress-deploy-core-ip in SSM}"

echo "=== Edge health ==="
check_health "edge" "http://${ENGRESS_EDGE_IP}:80/healthz" '"service":"engress-edge"'

echo "=== Core health ==="
check_health "core" "http://${ENGRESS_CORE_IP}:8080/healthz" '"service":"engress-core"'

echo "=== All checks passed ==="
