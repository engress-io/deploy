#!/usr/bin/env bash
# Spaceship DNS API helpers.
# Credential env (first match wins):
#   GitHub Actions: SPACESHIP_API_KEY + SPACESHIP_API_SECRET
#   Cursor cloud:   SPACESHIP_API + SPACESHIP_SECRET
#   SSM:            spaceship-api-key, spaceship-api-secret (us-east-2)
spaceship_api_base() {
  printf '%s\n' "${SPACESHIP_API_URL:-https://spaceship.dev/api/v1}"
}

spaceship_load_credentials() {
  local region="${1:-us-east-2}"

  if [[ -z "${SPACESHIP_API_KEY:-}" && -n "${SPACESHIP_API:-}" && "${SPACESHIP_API}" != http* ]]; then
    SPACESHIP_API_KEY="$SPACESHIP_API"
  fi
  if [[ -z "${SPACESHIP_API_SECRET:-}" && -n "${SPACESHIP_SECRET:-}" ]]; then
    SPACESHIP_API_SECRET="$SPACESHIP_SECRET"
  fi

  if [[ -z "${SPACESHIP_API_KEY:-}" || -z "${SPACESHIP_API_SECRET:-}" ]]; then
    if command -v aws >/dev/null; then
      SPACESHIP_API_KEY="${SPACESHIP_API_KEY:-$(aws ssm get-parameter --name spaceship-api-key --with-decryption \
        --region "$region" --query Parameter.Value --output text 2>/dev/null || true)}"
      SPACESHIP_API_SECRET="${SPACESHIP_API_SECRET:-$(aws ssm get-parameter --name spaceship-api-secret --with-decryption \
        --region "$region" --query Parameter.Value --output text 2>/dev/null || true)}"
    fi
  fi

  if [[ -z "${SPACESHIP_API_KEY:-}" || -z "${SPACESHIP_API_SECRET:-}" ]]; then
    return 1
  fi
  export SPACESHIP_API_KEY SPACESHIP_API_SECRET
  return 0
}

spaceship_get_records() {
  local domain="$1"
  local base
  base="$(spaceship_api_base)"
  curl -sS -G "${base}/dns/records/${domain}" \
    -H "X-API-Key: ${SPACESHIP_API_KEY}" \
    -H "X-API-Secret: ${SPACESHIP_API_SECRET}" \
    --data-urlencode "skip=0" \
    --data-urlencode "take=500"
}

spaceship_put_records() {
  local domain="$1"
  local payload="$2"
  local base resp http_code body
  base="$(spaceship_api_base)"
  resp="$(curl -sS -w '\n%{http_code}' -X PUT "${base}/dns/records/${domain}" \
    -H "X-API-Key: ${SPACESHIP_API_KEY}" \
    -H "X-API-Secret: ${SPACESHIP_API_SECRET}" \
    -H "Content-Type: application/json" \
    -d "$payload")"
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [[ "$http_code" == "204" ]]; then
    return 0
  fi
  if [[ "$http_code" == "422" && "$body" == *"already exists"* ]]; then
    echo "    (record already present — skipping)"
    return 0
  fi
  echo "$body" >&2
  return 1
}

spaceship_delete_records() {
  local domain="$1"
  local payload="$2"
  local base resp http_code body
  base="$(spaceship_api_base)"
  resp="$(curl -sS -w '\n%{http_code}' -X DELETE "${base}/dns/records/${domain}" \
    -H "X-API-Key: ${SPACESHIP_API_KEY}" \
    -H "X-API-Secret: ${SPACESHIP_API_SECRET}" \
    -H "Content-Type: application/json" \
    -d "$payload")"
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [[ "$http_code" == "204" ]]; then
    return 0
  fi
  if [[ -n "$body" ]]; then
    echo "$body" >&2
  fi
  return 1
}

spaceship_normalize_ip_csv() {
  echo "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -E '^[0-9]+\.' | sort -u | paste -sd, -
}

spaceship_ga_ips_match() {
  local cur="$1" want="$2"
  [[ "$(spaceship_normalize_ip_csv "$cur")" == "$(spaceship_normalize_ip_csv "$want")" ]]
}

# Live *.edge A record IPs (Spaceship authoritative, else public DNS probe).
spaceship_ga_edge_current_ips() {
  local domain="$1"
  local region="${2:-us-east-2}"
  local json cur
  if spaceship_load_credentials "$region" 2>/dev/null; then
    json="$(spaceship_get_records "$domain")"
    if jq -e '.items' >/dev/null 2>&1 <<<"$json"; then
      cur="$(jq -r '[.items[]? | select(.type=="A" and .name=="*.edge") | .address]
        | map(select(. != null and . != "")) | unique | join(",")' <<<"$json")"
      if [[ -n "$cur" && "$cur" != "null" ]]; then
        echo "$cur"
        return 0
      fi
    fi
  fi
  if command -v dig >/dev/null 2>&1; then
    dig @8.8.8.8 +short "probe.edge.${domain}" A 2>/dev/null | paste -sd, -
  fi
}

spaceship_ga_edge_needs_update() {
  local domain="$1" want_ips="$2" region="${3:-us-east-2}"
  local cur
  cur="$(spaceship_ga_edge_current_ips "$domain" "$region")"
  [[ -z "$cur" ]] && return 0
  spaceship_ga_ips_match "$cur" "$want_ips" && return 1
  return 0
}

# Remove stale *.edge CNAME when GA A records are authoritative (P03).
spaceship_remove_stale_edge_cnames() {
  local domain="$1"
  local json cnames
  json="$(spaceship_get_records "$domain")"
  if ! jq -e '.items' >/dev/null 2>&1 <<<"$json"; then
    echo "WARN: could not list Spaceship records to prune *.edge CNAMEs" >&2
    return 0
  fi
  cnames="$(jq -c '[.items[]? | select(.type=="CNAME" and .name=="*.edge") |
    {type:"CNAME", name:"*.edge", cname:(.cname // "")} | select(.cname != "")]' <<<"$json")"
  if [[ "$cnames" == "[]" ]]; then
    return 0
  fi
  echo "==> removing stale *.edge CNAME(s) (GA A records are authoritative)"
  spaceship_delete_records "$domain" "$cnames"
}

# Remove *.edge A records not in the target GA IP set (GA recreation / IP churn).
spaceship_remove_stale_edge_a_records() {
  local domain="$1"
  local target_ips_csv="$2"
  local json stale
  json="$(spaceship_get_records "$domain")"
  if ! jq -e '.items' >/dev/null 2>&1 <<<"$json"; then
    echo "WARN: could not list Spaceship records to prune stale *.edge A records" >&2
    return 0
  fi
  stale="$(jq -c --arg ips "$target_ips_csv" '
    ($ips | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $want |
    [.items[]? | select(.type=="A" and .name=="*.edge" and (.address // "") != "")
      | select(.address as $a | ($want | index($a)) | not)
      | {type:"A", name:"*.edge", address:.address}]' <<<"$json")"
  if [[ "$stale" == "[]" ]]; then
    return 0
  fi
  echo "==> removing stale *.edge A record(s)"
  jq -c '.[]' <<<"$stale" | while read -r rec; do
    jq -r '"  delete A *.edge → \(.address)"' <<<"$rec"
  done
  spaceship_delete_records "$domain" "$stale"
}
