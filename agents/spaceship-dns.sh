#!/usr/bin/env bash
# Spaceship DNS CLI for engress.io — uses deploy/lib/spaceship.sh credentials.
# Usage:
#   spaceship-dns.sh list [domain]
#   spaceship-dns.sh list-table [domain]
#   spaceship-dns.sh get <name> [domain]          # e.g. get '*.edge'
#   spaceship-dns.sh put '<json>' [domain]
#   spaceship-dns.sh put-file path.json [domain]
#   spaceship-dns.sh delete '<json-array>' [domain]
#   spaceship-dns.sh audit
#   spaceship-dns.sh apply-ga [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=deploy/lib/spaceship.sh
source "$ROOT/deploy/lib/spaceship.sh"
# shellcheck source=agent/cloud-env-bootstrap.sh
source "$ROOT/agent/cloud-env-bootstrap.sh" 2>/dev/null || true
export CLOUD_ENV_CHECK=0

DOMAIN="${ENGRESS_DNS_DOMAIN:-engress.io}"
CMD="${1:-}"

usage() {
  cat <<EOF
Usage: spaceship-dns.sh <command> [args]

Commands:
  list [domain]              JSON dump of all DNS records (skip=0, take=500)
  list-table [domain]        TSV table: type, name, value, ttl
  get <name> [domain]        Filter records by Spaceship name (e.g. '*.edge', 'core-origin')
  put '<json>' [domain]      PUT {force, items} payload
  put-file <file> [domain]   PUT payload from JSON file
  delete '<json-array>' [domain]   DELETE bare JSON array of records
  audit                      Run dns-cutover-audit.sh (EKS targets + cutover table)
  apply-ga [--dry-run]       Apply *.edge Global Accelerator A records (+ prune stale)

Credentials (auto-resolved):
  Cursor:  SPACESHIP_API + SPACESHIP_SECRET
  GHA:     SPACESHIP_API_KEY + SPACESHIP_API_SECRET
  SSM:     spaceship-api-key, spaceship-api-secret (us-east-2)

Domain default: ${DOMAIN}
EOF
}

require_creds() {
  if ! spaceship_load_credentials; then
    echo "ERROR: Spaceship credentials missing." >&2
    echo "  Cursor secrets: SPACESHIP_API, SPACESHIP_SECRET" >&2
    echo "  Or: SPACESHIP_API_KEY, SPACESHIP_API_SECRET" >&2
    echo "  Or SSM: spaceship-api-key, spaceship-api-secret" >&2
    exit 1
  fi
}

case "$CMD" in
  list|ls)
    shift
    d="${1:-$DOMAIN}"
    require_creds
    spaceship_get_records "$d" | jq .
    ;;

  list-table|table)
    shift
    d="${1:-$DOMAIN}"
    require_creds
    spaceship_get_records "$d" | jq -r '.items[]? | "\(.type)\t\(.name)\t\(.address // .cname // "-")\t\(.ttl // "-")"' | sort
    ;;

  get)
    shift
    name="${1:?record name required (quote wildcards in zsh, e.g. '*.edge')}"
    d="${2:-$DOMAIN}"
    require_creds
    spaceship_get_records "$d" | jq --arg n "$name" '[.items[]? | select(.name == $n)]'
    ;;

  put)
    shift
    payload="${1:?JSON payload required}"
    d="${2:-$DOMAIN}"
    require_creds
    echo "$payload" | jq . >/dev/null
    spaceship_put_records "$d" "$payload"
    echo "OK: PUT ${d}"
    ;;

  put-file)
    shift
    file="${1:?json file required}"
    d="${2:-$DOMAIN}"
    require_creds
    [[ -f "$file" ]] || { echo "ERROR: file not found: $file" >&2; exit 1; }
    payload="$(cat "$file")"
    echo "$payload" | jq . >/dev/null
    spaceship_put_records "$d" "$payload"
    echo "OK: PUT ${d} from ${file}"
    ;;

  delete|del)
    shift
    payload="${1:?JSON array required, e.g. [{\"type\":\"A\",\"name\":\"*.edge\",\"address\":\"1.2.3.4\"}]}"
    d="${2:-$DOMAIN}"
    require_creds
    echo "$payload" | jq 'if type == "array" then . else error("delete expects JSON array") end' >/dev/null
    spaceship_delete_records "$d" "$payload"
    echo "OK: DELETE on ${d}"
    ;;

  audit)
    exec bash "$ROOT/agent/dns-cutover-audit.sh"
    ;;

  apply-ga)
    shift
    export PHASE_B_DRY_RUN=0
    if [[ "${1:-}" == "--dry-run" ]]; then
      export PHASE_B_DRY_RUN=1
    fi
    exec bash "$ROOT/deploy/scripts/phase-b-dns-ga.sh"
    ;;

  -h|--help|help|"")
    usage
    exit 0
    ;;

  *)
    echo "unknown command: $CMD" >&2
    usage >&2
    exit 1
    ;;
esac
