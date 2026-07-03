#!/usr/bin/env bash
# audit-deploy-pipeline.sh — staging deploy pipeline audit (D1, D3, D5, D7).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/ssm-deploy-config.sh"

declare -a RESULTS=()
fail_count=0

record() {
  local id="$1"
  local desc="$2"
  local ok="$3"
  if [[ "$ok" == "1" ]]; then
    RESULTS+=("PASS|${id}|${desc}")
  else
    RESULTS+=("FAIL|${id}|${desc}")
    fail_count=$((fail_count + 1))
  fi
}

IMAGE_TAG="${IMAGE_TAG:-${ENGRESS_IMAGE_TAG:-}}"
STAGING_BASE="${ENGRESS_STAGING_BASE:-staging.engress.io}"
REGION="${AWS_REGION:-us-east-2}"

echo "=== Deploy Pipeline Audit ==="
echo "env=${ENGRESS_ENV:-unset} tag=${IMAGE_TAG:-unset}"

# D1 — staging SSM configured
if [[ -n "${ENGRESS_DEPLOY_EKS_CLUSTER:-}" ]]; then
  record "D1" "Staging SSM configured (${ENGRESS_DEPLOY_EKS_CLUSTER})" 1
else
  record "D1" "Staging SSM configured (ENGRESS_DEPLOY_EKS_CLUSTER empty)" 0
fi

# D3 — public API version matches IMAGE_TAG
if [[ -z "$IMAGE_TAG" ]]; then
  record "D3" "Version alignment (IMAGE_TAG unset)" 0
else
  body=""
  if body="$(curl -sf --max-time 20 "https://${STAGING_BASE}/api/healthz" 2>/dev/null)"; then
    if echo "$body" | grep -q "\"version\":\"${IMAGE_TAG}\""; then
      record "D3" "Version alignment (public API=${IMAGE_TAG})" 1
    else
      record "D3" "Version alignment (expected ${IMAGE_TAG})" 0
    fi
  else
    record "D3" "Version alignment (curl https://${STAGING_BASE}/api/healthz failed)" 0
  fi
fi

# D5 — staging agent binary downloadable
AGENT_URL="https://${STAGING_BASE}/downloads/staging/latest/engress-linux-amd64"
agent_code="$(curl -sfI -o /dev/null -w "%{http_code}" --max-time 15 "$AGENT_URL" 2>/dev/null || echo "000")"
if [[ "$agent_code" == "200" ]]; then
  tmp="$(mktemp)"
  if curl -sf --max-time 30 "$AGENT_URL" -o "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    record "D5" "Agent binary staging (${AGENT_URL})" 1
  else
    record "D5" "Agent binary staging (HTTP 200 but empty body)" 0
  fi
  rm -f "$tmp"
else
  record "D5" "Agent binary staging (HTTP ${agent_code})" 0
fi

# D7 — ECR images exist for IMAGE_TAG (core + edge)
if [[ -z "$IMAGE_TAG" ]]; then
  record "D7" "ECR images exist (IMAGE_TAG unset)" 0
else
  d7_ok=1
  for repo in engress-core engress-edge; do
    if ! aws ecr describe-images \
      --repository-name "$repo" \
      --image-ids "imageTag=${IMAGE_TAG}" \
      --region "$REGION" >/dev/null 2>&1; then
      d7_ok=0
      break
    fi
  done
  if [[ "$d7_ok" == "1" ]]; then
    record "D7" "ECR images exist (core+edge:${IMAGE_TAG})" 1
  else
    record "D7" "ECR images exist (missing tag ${IMAGE_TAG})" 0
  fi
fi

echo ""
printf "%-6s %-4s %s\n" "STATUS" "ID" "CHECK"
printf "%-6s %-4s %s\n" "------" "----" "------------------------------"
for row in "${RESULTS[@]}"; do
  IFS='|' read -r status id desc <<< "$row"
  printf "%-6s %-4s %s\n" "$status" "$id" "$desc"
done
echo ""

if [[ "$fail_count" -gt 0 ]]; then
  echo "AUDIT FAILED (${fail_count} check(s))"
  exit 1
fi

echo "AUDIT PASSED (all checks OK)"