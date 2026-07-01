#!/usr/bin/env bash
# Shared helpers for phase verify scripts. Source from each verify-*.sh.
set -euo pipefail

# --- Compose setup ---
if [[ "${FLUX_USE_ECR:-0}" == "1" ]]; then
  COMPOSE=(docker compose -f docker-compose.ecr.yml)
else
  COMPOSE=(docker compose -f docker-compose.yml)
fi
COMPOSE_API=("${COMPOSE[@]}" --profile api)

# --- Result helpers ---
FAILED=0
red() { echo "FAIL: $*" >&2; FAILED=1; }
ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; }
expect() { echo "EXPECT: $*"; }

# --- HTTP helpers ---
curl_code() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
curl_body() { curl -sf "$@"; }

# --- Domain resolution ---
base_domain() {
  if [[ -n "${FLUX_BASE_DOMAIN:-}" ]]; then
    echo "$FLUX_BASE_DOMAIN"
    return
  fi
  local f
  for f in data/edge.yaml "$ENGRESS_CORE_ROOT/deploy/data/edge.yaml" "$ENGRESS_CORE_ROOT/edge.yaml"; do
    if [[ -f "$f" ]]; then
      grep '^base_domain:' "$f" 2>/dev/null | awk '{print $2}' | tr -d '"' || true
      return
    fi
  done
}

domain_suffix() {
  local base="$1" f
  for f in data/edge.yaml "$ENGRESS_CORE_ROOT/deploy/data/edge.yaml"; do
    if [[ -f "$f" ]]; then
      grep '^domain_suffix:' "$f" 2>/dev/null | awk '{print $2}' | tr -d '"' && return
    fi
  done
  if [[ "$base" == *.* ]]; then
    echo ".${base#*.}"
  else
    echo ".$base"
  fi
}

# --- Container checks ---
container_running() {
  local name="$1"
  if "${COMPOSE[@]}" ps --status running 2>/dev/null | grep -qE "(^|[-_])${name}[-_]|SERVICE.*${name}"; then
    return 0
  fi
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$name"
}

api_container_running() {
  if "${COMPOSE_API[@]}" ps --status running 2>/dev/null | grep -qE '(^|[-_])api[-_]|SERVICE.*api'; then
    return 0
  fi
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qE 'api'
}

# --- Health check helpers ---
check_healthz() {
  local url="$1" expected_service="$2" label="${3:-$1}"
  local body
  if body="$(curl_body --connect-timeout 3 "$url" 2>/dev/null)"; then
    if [[ -n "$expected_service" ]]; then
      if echo "$body" | grep -q '"service"[[:space:]]*:[[:space:]]*"'"$expected_service"'"'; then
        ok "$label /healthz ($expected_service)"
        echo "$body"
        return 0
      else
        red "$label /healthz unexpected body: $body"
        return 1
      fi
    else
      if echo "$body" | grep -q '"status"'; then
        ok "$label /healthz"
        return 0
      fi
    fi
    red "$label /healthz unexpected: $body"
    return 1
  else
    red "$label /healthz failed"
    return 1
  fi
}

# --- Standard binary check ---
check_binaries() {
  local ok=1
  if [[ "${FLUX_USE_ECR:-0}" == "1" ]]; then
    ok "ECR mode (no on-host bin/ required)"
  else
    local bin
    for bin in engress-edge engress-core; do
      if [[ -x "bin/$bin" ]]; then
        ok "bin/$bin present"
      else
        red "bin/$bin missing — run ./deploy/scripts/build.sh"
        ok=0
      fi
    done
  fi
  return $(( ! ok ))
}

# --- Standard infra check (binaries + edge + api containers + healthz) ---
check_phase_a_infra() {
  local with_api="${1:-1}"
  local ok=1

  echo "--- binaries ---"
  check_binaries || ok=0
  echo

  echo "--- engress-edge ---"
  if container_running edge; then
    ok "edge container running"
  else
    red "edge container not running"
    ok=0
  fi
  if ! check_healthz "http://127.0.0.1:80/healthz" "engress-edge"; then
    ok=0
  fi
  echo

  if [[ "$with_api" -eq 1 ]]; then
    echo "--- engress-core ---"
    if api_container_running; then
      ok "api container running"
    else
      red "api container not running — run: ./dev.sh api-up"
      ok=0
    fi
    if ! check_healthz "http://127.0.0.1:8080/healthz" "engress-core"; then
      "${COMPOSE_API[@]}" logs --tail=40 api 2>/dev/null || true
      ok=0
    fi
    echo
  fi

  return $(( ! ok ))
}
