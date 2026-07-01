#!/usr/bin/env bash
# Clerk Backend API helpers for Engress production auth.
# Credentials (first match wins):
#   Cursor cloud: CLERK_SECRET_KEY, CLERK_PUBLISHABLE_KEY, CLERK_WEBHOOK_SECRET
#   Aliases:      CLERK_SK, CLERK_PK, VITE_CLERK_PUBLISHABLE_KEY, NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY
#   SSM:          clerk-secret-key, next-clerk-publishable-key, clerk-webhook-secret
CLERK_API_BASE="${CLERK_API_BASE:-https://api.clerk.com/v1}"

ENGRESS_CLERK_ORG_ID="${ENGRESS_CLERK_ORG_ID:-${CLERK_ORG_ID:-org_3FN4VwPcUUsNUKi0yf6cdFLhG7J}}"
ENGRESS_CLERK_PLATFORM_ADMIN_ID="${ENGRESS_CLERK_PLATFORM_ADMIN_ID:-user_3FN549eRWLmoIm1HJZH1zdN2zin}"
ENGRESS_APP_ORIGIN="${ENGRESS_APP_ORIGIN:-https://engress.io}"

clerk_load_credentials() {
  local region="${1:-us-east-2}"

  # Whitespace-only env (e.g. unset GitHub secret) → fall through to SSM.
  [[ "${CLERK_SECRET_KEY:-}" =~ ^[[:space:]]*$ ]] && unset CLERK_SECRET_KEY
  [[ "${CLERK_PUBLISHABLE_KEY:-}" =~ ^[[:space:]]*$ ]] && unset CLERK_PUBLISHABLE_KEY
  [[ "${CLERK_WEBHOOK_SECRET:-}" =~ ^[[:space:]]*$ ]] && unset CLERK_WEBHOOK_SECRET

  # Cursor / dashboard aliases (including SSM param-style names).
  if [[ -z "${CLERK_SECRET_KEY:-}" ]]; then
    CLERK_SECRET_KEY="${CLERK_SK:-${CLERK_SECRET:-}}"
    # bash disallows hyphens in var names — read via env if set by platform
    CLERK_SECRET_KEY="${CLERK_SECRET_KEY:-$(printenv clerk-secret-key 2>/dev/null || true)}"
  fi
  if [[ -z "${CLERK_PUBLISHABLE_KEY:-}" ]]; then
    CLERK_PUBLISHABLE_KEY="${CLERK_PK:-${CLERK_PUBLISHABLE:-${VITE_CLERK_PUBLISHABLE_KEY:-${NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY:-}}}}"
    CLERK_PUBLISHABLE_KEY="${CLERK_PUBLISHABLE_KEY:-$(printenv next-clerk-publishable-key 2>/dev/null || true)}"
  fi
  if [[ -z "${CLERK_WEBHOOK_SECRET:-}" ]]; then
    CLERK_WEBHOOK_SECRET="${CLERK_WEBHOOK:-$(printenv clerk-webhook-secret 2>/dev/null || true)}"
  fi

  if [[ -z "${CLERK_SECRET_KEY:-}" || -z "${CLERK_PUBLISHABLE_KEY:-}" ]]; then
    if command -v aws >/dev/null; then
      CLERK_SECRET_KEY="${CLERK_SECRET_KEY:-$(aws ssm get-parameter --name clerk-secret-key --with-decryption \
        --region "$region" --query Parameter.Value --output text 2>/dev/null || true)}"
      CLERK_PUBLISHABLE_KEY="${CLERK_PUBLISHABLE_KEY:-$(aws ssm get-parameter --name next-clerk-publishable-key \
        --region "$region" --query Parameter.Value --output text 2>/dev/null || true)}"
      CLERK_WEBHOOK_SECRET="${CLERK_WEBHOOK_SECRET:-$(aws ssm get-parameter --name clerk-webhook-secret --with-decryption \
        --region "$region" --query Parameter.Value --output text 2>/dev/null || true)}"
    fi
  fi

  if [[ -z "${CLERK_SECRET_KEY:-}" || -z "${CLERK_PUBLISHABLE_KEY:-}" ]]; then
    return 1
  fi
  # GitHub/Cursor secrets often include a trailing newline when pasted.
  CLERK_SECRET_KEY="${CLERK_SECRET_KEY%"${CLERK_SECRET_KEY##*[![:space:]]}"}"
  CLERK_PUBLISHABLE_KEY="${CLERK_PUBLISHABLE_KEY%"${CLERK_PUBLISHABLE_KEY##*[![:space:]]}"}"
  [[ -n "${CLERK_WEBHOOK_SECRET:-}" ]] && CLERK_WEBHOOK_SECRET="${CLERK_WEBHOOK_SECRET%"${CLERK_WEBHOOK_SECRET##*[![:space:]]}"}"
  export CLERK_SECRET_KEY CLERK_PUBLISHABLE_KEY CLERK_WEBHOOK_SECRET
  return 0
}

clerk_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local resp http_code
  if [[ -n "$body" ]]; then
    resp="$(curl -sS -w '\n%{http_code}' -X "$method" "${CLERK_API_BASE}${path}" \
      -H "Authorization: Bearer ${CLERK_SECRET_KEY}" \
      -H "Content-Type: application/json" \
      -d "$body")"
  else
    resp="$(curl -sS -w '\n%{http_code}' -X "$method" "${CLERK_API_BASE}${path}" \
      -H "Authorization: Bearer ${CLERK_SECRET_KEY}")"
  fi
  http_code="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"
  printf '%s\n' "$http_code"
  printf '%s' "$resp"
}

clerk_pk_frontend_host() {
  local pk="$1"
  [[ "$pk" == pk_* ]] || return 1
  local payload="${pk#pk_*_}"
  echo "$payload" | python3 -c 'import sys,base64; b=sys.stdin.read().strip(); b+="="*((4-len(b)%4)%4); print(base64.b64decode(b).decode().rstrip("$"))' 2>/dev/null || true
}

clerk_pk_accounts_portal_url() {
  local pk="$1"
  local host slug
  host="$(clerk_pk_frontend_host "$pk")"
  [[ -n "$host" ]] || return 1
  slug="${host%%.clerk.accounts.dev}"
  [[ "$slug" != "$host" ]] || return 1
  echo "https://${slug}.accounts.dev"
}

clerk_primary_domain_host() {
  local code body
  body="$(clerk_api GET "/domains")"
  code="${body%%$'\n'*}"
  body="${body#*$'\n'}"
  [[ "$code" == "200" ]] || return 1
  python3 -c 'import sys,json; d=json.load(sys.stdin).get("data",[]); print(d[0].get("frontend_api_url","").replace("https://","").rstrip("/") if d else "")' <<<"$body"
}

clerk_list_orgs() {
  local code body
  body="$(clerk_api GET "/organizations?limit=50")"
  code="${body%%$'\n'*}"
  body="${body#*$'\n'}"
  [[ "$code" == "200" ]] || { echo "ERROR: list organizations HTTP $code" >&2; return 1; }
  jq -r '.data[]? | "\(.id)\t\(.name // .slug // "?")"' <<<"$body" | sort
}

clerk_verify_engress_org() {
  local code body
  body="$(clerk_api GET "/organizations/${ENGRESS_CLERK_ORG_ID}")"
  code="${body%%$'\n'*}"
  body="${body#*$'\n'}"
  if [[ "$code" == "200" ]] && grep -q '"object"[[:space:]]*:[[:space:]]*"organization"' <<<"$body"; then
    python3 -c 'import sys,json; print(json.load(sys.stdin).get("name",""))' <<<"$body"
    return 0
  fi
  # Domain match already proved the key belongs to this Clerk instance. A 403/404 on
  # /organizations usually means Organizations API isn't available for this instance,
  # or ENGRESS_CLERK_ORG_ID is stale — not that the secret key is "restricted".
  if [[ "$code" == "403" || "$code" == "404" ]]; then
    echo "WARN: Organizations API HTTP ${code} for ${ENGRESS_CLERK_ORG_ID} (keys OK — domain match passed)" >&2
    echo "       Set ENGRESS_CLERK_ORG_ID if the org id changed, or ignore if login works." >&2
    echo "(org API unavailable)"
    return 0
  fi
  echo "ERROR: GET /organizations/${ENGRESS_CLERK_ORG_ID} HTTP ${code}" >&2
  if [[ -n "$body" ]]; then
    echo "       $(jq -c '{errors,message,clerk_trace_id}' <<<"$body" 2>/dev/null || echo "$body" | head -c 200)" >&2
  fi
  echo "       Expected org ${ENGRESS_CLERK_ORG_ID} — listing orgs visible to this secret key:" >&2
  clerk_list_orgs >&2 || true
  return 1
}

clerk_ensure_redirect_urls() {
  local origin="$1"
  local paths=(
    "/"
    "/sign-in"
    "/sign-up"
    "/dashboard"
    "/dashboard/endpoints"
    "/link"
    "/beta/access"
    "/oasis"
  )
  local code body existing path url
  body="$(clerk_api GET "/redirect_urls?limit=100")"
  code="${body%%$'\n'*}"
  body="${body#*$'\n'}"
  if [[ "$code" == "403" ]]; then
    echo "  [skip] redirect_urls list HTTP 403 — assuming configured" >&2
    return 0
  fi
  [[ "$code" == "200" ]] || { echo "ERROR: list redirect_urls HTTP $code" >&2; echo "$body" >&2; return 1; }

  for path in "${paths[@]}"; do
    url="${origin%/}${path}"
    if echo "$body" | jq -e --arg u "$url" '((.data // []) | .[]?.url) | index($u) != null' >/dev/null 2>&1; then
      echo "  [ok] redirect $url"
      continue
    fi
    echo "  [add] redirect $url"
    body="$(clerk_api POST "/redirect_urls" "$(jq -nc --arg url "$url" '{url:$url}')")"
    code="${body%%$'\n'*}"
    body="${body#*$'\n'}"
    if [[ "$code" != "200" && "$code" != "201" ]]; then
      if [[ "$code" == "422" ]] && grep -q 'form_already_exists' <<<"$body"; then
        echo "  [ok] redirect $url (already exists)"
      else
        echo "WARN: create redirect $url failed HTTP $code: $body" >&2
      fi
    fi
  done
}

clerk_configure_beta_auth() {
  local code body
  body="$(clerk_api PATCH "/instance/organization_settings" \
    '{"enabled":false,"force_organization_selection":false}')"
  code="${body%%$'\n'*}"
  body="${body#*$'\n'}"
  [[ "$code" == "200" ]] || { echo "WARN: organization_settings PATCH HTTP $code: $body" >&2; return 1; }
  python3 -c 'import sys,json; d=json.load(sys.stdin); print("  org gate enabled=", d.get("enabled"), "force=", d.get("force_organization_selection"))' <<<"$body"
}

clerk_sync_ssm_from_env() {
  local region="${1:-us-east-2}"
  command -v aws >/dev/null || { echo "ERROR: aws CLI required for SSM sync" >&2; return 1; }
  clerk_load_credentials "$region" || return 1
  local attempt
  for attempt in 1 2 3 4 5; do
    if aws ssm put-parameter --name next-clerk-publishable-key --type String \
      --value "$CLERK_PUBLISHABLE_KEY" --overwrite --region "$region" >/dev/null 2>&1 \
      && aws ssm put-parameter --name clerk-secret-key --type SecureString \
      --value "$CLERK_SECRET_KEY" --overwrite --region "$region" >/dev/null 2>&1; then
      break
    fi
    if [[ "$attempt" -eq 5 ]]; then
      echo "ERROR: SSM PutParameter denied after ${attempt} attempts (IAM propagation?)" >&2
      return 1
    fi
    echo "  SSM write retry ${attempt}/5 (IAM propagation)..." >&2
    sleep 3
  done
  if [[ -n "${CLERK_WEBHOOK_SECRET:-}" ]]; then
    aws ssm put-parameter --name clerk-webhook-secret --type SecureString \
      --value "$CLERK_WEBHOOK_SECRET" --overwrite --region "$region" >/dev/null
  fi
  echo "SSM updated: next-clerk-publishable-key, clerk-secret-key${CLERK_WEBHOOK_SECRET:+, clerk-webhook-secret}"
}
