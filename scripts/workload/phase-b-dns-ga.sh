#!/usr/bin/env bash
# Phase B — publish Global Accelerator anycast A records for the edge wildcard at Spaceship.
# Usage:
#   phase-b-dns-ga.sh              # dry-run if update needed; skip if already applied
#   phase-b-dns-ga.sh --apply      # live PUT (+ prune stale records)
#   phase-b-dns-ga.sh --check        # exit 0 when *.edge matches GA IPs, 1 otherwise
#   PHASE_B_DRY_RUN=0 phase-b-dns-ga.sh   # same as --apply
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=deploy/lib/workspace.sh
source "$SCRIPTS/../lib/workspace.sh"
# shellcheck source=deploy/lib/spaceship.sh
source "$SCRIPTS/../lib/spaceship.sh"
engress_export_workspace

DOMAIN="${ENGRESS_DNS_DOMAIN:-engress.io}"
MODE="${PHASE_B_GA_MODE:-auto}"
DRY_RUN="${PHASE_B_DRY_RUN:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply|--live) MODE=apply; DRY_RUN=0 ;;
    --check) MODE=check ;;
    --dry-run) MODE=dry-run; DRY_RUN=1 ;;
    -h|--help)
      cat <<EOF
Usage: phase-b-dns-ga.sh [--apply|--check|--dry-run]

  (default)  Skip if *.edge already matches GA IPs; else dry-run manifest
  --apply    Spaceship PUT + prune stale edge records
  --check    Exit 0 if DNS matches SSM GA IPs, 1 if update needed
  --dry-run  Always print manifest without applying

Apply shortcuts:
  ./scripts/agent/spaceship-dns.sh apply-ga
  ./scripts/agent/dispatch-ops.sh dns-cutover-ga-apply
EOF
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$DRY_RUN" == "0" ]]; then
  MODE=apply
fi

GA_IPS="${ENGRESS_GA_IPS:-}"
if [[ -z "$GA_IPS" ]]; then
  GA_IPS="$(aws ssm get-parameter --name engress-deploy-global-accelerator-ips --region us-east-2 \
    --query Parameter.Value --output text 2>/dev/null || true)"
fi
if [[ -z "$GA_IPS" || "$GA_IPS" == "None" ]]; then
  ROOT="${ENGRESS_CORE_ROOT:-}"
  TF_DIR="${ENGRESS_TF_DIR:-}"
  if [[ -n "$ROOT" && -d "$ROOT" && -n "$TF_DIR" && -d "$TF_DIR" ]]; then
    TF="${TF:-terraform}"
    GA_JSON="$("$TF" -chdir="$TF_DIR" output -json global_accelerator_ips 2>/dev/null || true)"
    if [[ -n "$GA_JSON" && "$GA_JSON" != "null" ]]; then
      GA_IPS="$(jq -r '.[]' <<<"$GA_JSON" | paste -sd, -)"
    fi
  fi
fi

if [[ -z "$GA_IPS" || "$GA_IPS" == "None" ]]; then
  echo "ERROR: Global Accelerator IPs not found (terraform output global_accelerator_ips or SSM)" >&2
  exit 1
fi

IFS=',' read -ra IPS <<< "$GA_IPS"
if [[ ${#IPS[@]} -lt 1 ]]; then
  echo "ERROR: no GA IPs parsed from: $GA_IPS" >&2
  exit 1
fi

CURRENT="$(spaceship_ga_edge_current_ips "$DOMAIN" 2>/dev/null || true)"
if ! spaceship_ga_edge_needs_update "$DOMAIN" "$GA_IPS"; then
  echo "OK: edge wildcard DNS already matches Global Accelerator (${GA_IPS})"
  [[ -n "$CURRENT" ]] && echo "    current: ${CURRENT}"
  exit 0
fi

if [[ "$MODE" == "check" ]]; then
  echo "UPDATE needed: edge wildcard DNS → GA anycast (${GA_IPS})"
  [[ -n "$CURRENT" ]] && echo "    current: ${CURRENT}"
  exit 1
fi

payload_items="["
first=1
for ip in "${IPS[@]}"; do
  [[ -n "$ip" ]] || continue
  if [[ "$first" -eq 0 ]]; then payload_items+=","; fi
  first=0
  payload_items+="$(jq -nc --arg ip "$ip" '{type:"A", name:"*.edge", address:$ip, ttl:300}')"
done
payload_items+="]"
payload="$(jq -nc --argjson items "$payload_items" '{force:true, items:$items}')"

cat <<EOF
=== Phase B GA DNS manifest (${DOMAIN}) ===

Edge wildcard (Global Accelerator anycast):
  Type:  A (one record per IP)
  Name:  edge wildcard (*.edge)
EOF
for ip in "${IPS[@]}"; do
  echo "  Value: ${ip}"
done
[[ -n "$CURRENT" ]] && echo "  Current: ${CURRENT}"

echo
echo "Spaceship PUT payload:"
echo "$payload" | jq .

if [[ "$MODE" != "apply" ]]; then
  echo
  echo "DRY RUN — apply with:"
  echo "  ./scripts/agent/spaceship-dns.sh apply-ga"
  echo "  ./scripts/agent/dispatch-ops.sh dns-cutover-ga-apply"
  exit 0
fi

if ! spaceship_load_credentials; then
  echo "ERROR: Spaceship credentials required (SPACESHIP_API_KEY/SECRET or SSM)" >&2
  exit 1
fi

spaceship_put_records "$DOMAIN" "$payload"
spaceship_remove_stale_edge_cnames "$DOMAIN"
spaceship_remove_stale_edge_a_records "$DOMAIN" "$GA_IPS"
echo
echo "Done. Verify with: ./scripts/agent/dns-cutover-audit.sh"
