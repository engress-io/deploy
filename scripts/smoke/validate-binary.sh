#!/usr/bin/env bash
# validate-binary.sh — P07B v2 binary validation (version, mTLS, optional agent download).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/ssm-deploy-config.sh"

EXPECTED_TAG="${IMAGE_TAG:-${ENGRESS_IMAGE_TAG:-}}"
STAGING_BASE="${ENGRESS_STAGING_BASE:-staging.engress.io}"
STAGING_EDGE="${ENGRESS_STAGING_EDGE:-edge.staging.engress.io}"
CORE_ORIGIN="${ENGRESS_STAGING_CORE_ORIGIN:-core-origin.staging.engress.io}"
REGION="${AWS_REGION:-us-east-2}"
CLUSTER="${ENGRESS_DEPLOY_EKS_CLUSTER:-}"
NAMESPACE="${NAMESPACE:-engress}"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

try_version_json() {
  local name="$1" url="$2"
  local body
  body="$(curl -sf --max-time 20 "$url")" || return 1
  echo "$body" | grep -q '"service":"engress-core"' || return 1
  if [[ -n "$EXPECTED_TAG" ]]; then
    echo "$body" | grep -q "\"version\":\"${EXPECTED_TAG}\"" || return 1
  fi
  pass "${name} version OK"
  return 0
}

echo "==> P07B binary validation (tag=${EXPECTED_TAG:-unset})"

if [[ -n "$CLUSTER" && -n "$EXPECTED_TAG" ]]; then
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
  pod="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=engress-core \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$pod" ]]; then
    pod_body="$(kubectl exec -n "$NAMESPACE" "$pod" -- curl -sf http://127.0.0.1:8080/healthz)"
    echo "$pod_body" | grep -q "\"version\":\"${EXPECTED_TAG}\"" \
      || fail "engress-core pod version mismatch (got: ${pod_body})"
    pass "engress-core pod reports ${EXPECTED_TAG}"
  else
    echo "WARN: no engress-core pod found for in-cluster version check"
  fi
fi

if try_version_json "core-origin-http" "http://${CORE_ORIGIN}/api/healthz"; then
  :
elif try_version_json "core-origin-https" "https://${CORE_ORIGIN}/api/healthz"; then
  :
else
  fail "core-origin version check failed for ${CORE_ORIGIN}"
fi

try_version_json "public-api" "https://${STAGING_BASE}/api/healthz" \
  || fail "public API version check failed for ${STAGING_BASE}"

edge_ip="${ENGRESS_DEPLOY_EDGE_IP:-}"
if [[ -n "$edge_ip" && "$edge_ip" != "0.0.0.0" ]]; then
  echo "==> mTLS port open on ${edge_ip}:4433"
  if timeout 10 bash -c "echo | openssl s_client -connect ${edge_ip}:4433 -servername ${STAGING_EDGE} 2>/dev/null | grep -q 'BEGIN CERTIFICATE'"; then
    pass "edge mTLS port presents certificate"
  else
    fail "edge mTLS port check failed on ${edge_ip}:4433"
  fi
fi

AGENT_URL="https://${STAGING_BASE}/downloads/staging/latest/engress-linux-amd64"
agent_headers="$(curl -sfI --max-time 15 "$AGENT_URL" || true)"
if [[ -z "$agent_headers" ]]; then
  echo "WARN: staging agent binary not published yet (${AGENT_URL})"
elif echo "$agent_headers" | grep -qi 'application/octet-stream\|application/x-executable\|binary'; then
  pass "staging agent binary downloadable"
else
  tmp="$(mktemp)"
  if curl -sf --max-time 30 "$AGENT_URL" -o "$tmp" && [[ -s "$tmp" ]]; then
    pass "staging agent binary downloaded ($(wc -c <"$tmp") bytes)"
    rm -f "$tmp"
  else
    echo "WARN: staging agent URL reachable but binary download failed"
  fi
fi

echo "==> validate-binary.sh complete"
