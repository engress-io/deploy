#!/usr/bin/env bash
# Clerk auth CLI — verify, configure instance, sync SSM, refresh login (prod + staging).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/clerk.sh
source "$ROOT/scripts/lib/clerk.sh"
# Superproject shim (optional): scripts/agent/cloud-env-bootstrap.sh
SUPERPROJECT_ROOT="$(cd "$ROOT/.." && pwd)"
# shellcheck source=/dev/null
source "$SUPERPROJECT_ROOT/scripts/agent/cloud-env-bootstrap.sh" 2>/dev/null || true
export CLOUD_ENV_CHECK=0

CMD="${1:-}"
REGION="${AWS_REGION:-us-east-2}"
STAGING=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --staging) STAGING=1; ENGRESS_ENV=staging; export ENGRESS_ENV; shift ;;
    -h|--help|help) CMD=help; shift ;;
    *) break ;;
  esac
done
CMD="${1:-${CMD:-}}"
clerk_resolve_env

usage() {
  cat <<EOF
Usage: clerk-auth.sh [--staging] <command>

Commands:
  verify              Check keys match Engress Clerk app (+ org for prod)
  diagnose            List orgs + HTTP status (debug org id mismatch)
  configure           Ensure redirect URLs + beta org settings (API only)
  sync-ssm            Write env Clerk keys → SSM (needs aws CLI)
  build-spa           npm build + S3 sync + CF invalidation (needs aws CLI)
  refresh             configure + sync-ssm + build-spa + restart core (full login fix)
  list-redirect-urls  Show whitelisted redirect URLs
  get-domains         Show Clerk domains / frontend API host

Staging (--staging or ENGRESS_ENV=staging):
  Origin ${ENGRESS_APP_ORIGIN:-https://staging.engress.io}; SSM engress-staging-clerk-*
  Dev instances use *.accounts.dev for sign-in — custom Domains in Dashboard not required.

Credentials (Cursor cloud agent):
  Prod: CLERK_SECRET_KEY, CLERK_PUBLISHABLE_KEY
  Staging: STAGING_CLERK_* or SSM engress-staging-clerk-*

Or dispatch: ./scripts/agent/dispatch-ops.sh clerk-refresh
             ./scripts/agent/dispatch-ops.sh clerk-configure-staging
EOF
}

clerk_require_secret() {
  if ! clerk_load_credentials "$REGION"; then
    echo "ERROR: Clerk credentials missing." >&2
    if [[ "${ENGRESS_ENV:-prod}" == "staging" ]]; then
      echo "  SSM: engress-staging-clerk-secret-key + engress-staging-clerk-publishable-key" >&2
      echo "  Or: STAGING_CLERK_SECRET_KEY + STAGING_CLERK_PUBLISHABLE_KEY" >&2
    else
      echo "  Cursor: CLERK_SECRET_KEY + CLERK_PUBLISHABLE_KEY" >&2
      echo "  GitHub: add same names to repo secrets for dispatch-ops clerk-refresh" >&2
    fi
    exit 1
  fi
}

cmd_verify() {
  clerk_require_secret
  if [[ "${ENGRESS_ENV:-prod}" == "staging" ]]; then
    local pk_host inst
    pk_host="$(clerk_pk_frontend_host "$CLERK_PUBLISHABLE_KEY")"
    echo "=== Clerk verify (staging) ==="
    echo "Publishable host: ${pk_host:-unknown}"
    echo "App origin:       ${ENGRESS_APP_ORIGIN}"
    if ! inst="$(clerk_verify_instance)"; then
      echo "[FAIL] secret key invalid or Clerk API unreachable"
      exit 1
    fi
    echo "[ok] instance: $inst"
    echo "[ok] staging keys valid (dev sign-in uses ${pk_host:-accounts.dev}, not custom Domains)"
    return 0
  fi
  local pk_host clerk_host org_name
  pk_host="$(clerk_pk_frontend_host "$CLERK_PUBLISHABLE_KEY")"
  clerk_host="$(clerk_primary_domain_host || true)"
  echo "=== Clerk verify (Engress) ==="
  echo "Publishable host: ${pk_host:-unknown}"
  echo "Clerk API domain: ${clerk_host:-unknown}"
  echo "Expected org:     ${ENGRESS_CLERK_ORG_ID}"
  if [[ -n "$pk_host" && -n "$clerk_host" && "$pk_host" != "$clerk_host" ]]; then
    echo "[FAIL] publishable key host ($pk_host) != Clerk domain ($clerk_host)"
    echo "       Keys are from the wrong Clerk application. Use Engress app keys."
    exit 1
  fi
  if ! org_name="$(clerk_verify_engress_org 2>/dev/null)"; then
    clerk_verify_engress_org >&2 || true
    echo "[FAIL] org verify failed (see above)"
    echo "       Update keys from Clerk Dashboard → Applications → Engress → API keys"
    exit 1
  fi
  if [[ "$org_name" == "(org API unavailable)" ]]; then
    echo "[warn] org API unavailable — keys verified via clerk.engress.io domain match"
  else
    echo "[ok] org: $org_name"
  fi
  echo "[ok] keys match Engress Clerk application"
}

cmd_configure() {
  clerk_require_secret
  if [[ "${ENGRESS_ENV:-prod}" != "staging" ]]; then
    clerk_verify_engress_org >/dev/null || exit 1
  else
    clerk_verify_instance >/dev/null || exit 1
  fi
  echo "==> redirect URLs for ${ENGRESS_APP_ORIGIN}"
  clerk_ensure_redirect_urls "$ENGRESS_APP_ORIGIN"
  echo "==> beta auth (no org gate on sign-up)"
  clerk_configure_beta_auth
  echo "==> done — configure instance only (SSM/SPA unchanged)"
}

cmd_sync_ssm() {
  clerk_require_secret
  clerk_sync_ssm_from_env "$REGION"
}

cmd_build_spa() {
  exec bash "$ROOT/scripts/workload/spa-build-deploy.sh"
}

cmd_refresh() {
  clerk_require_secret
  echo "==> 1/4 verify"
  cmd_verify
  echo "==> 2/4 configure Clerk instance"
  clerk_ensure_redirect_urls "$ENGRESS_APP_ORIGIN"
  clerk_configure_beta_auth
  if command -v aws >/dev/null; then
    echo "==> 3/4 sync SSM + rebuild SPA"
    clerk_sync_ssm_from_env "$REGION"
    bash "$ROOT/scripts/workload/spa-build-deploy.sh"
    echo "==> 4/4 restart engress-core (if kubectl configured)"
    if command -v kubectl >/dev/null && aws eks update-kubeconfig --name engress-east --region us-east-2 >/dev/null 2>&1; then
      kubectl rollout restart deployment/engress-core -n engress
      kubectl rollout status deployment/engress-core -n engress --timeout=300s || {
        echo "WARN: engress-core rollout failed — collecting logs and rolling back" >&2
        kubectl logs -n engress -l app.kubernetes.io/name=engress-core --tail=40 --prefix=true 2>/dev/null || true
        kubectl logs -n engress -l app.kubernetes.io/name=engress-core --previous --tail=40 --prefix=true 2>/dev/null || true
        kubectl rollout undo deployment/engress-core -n engress 2>/dev/null || true
        kubectl rollout status deployment/engress-core -n engress --timeout=120s || true
        kubectl get pods -n engress -o wide || true
        echo "    After fixing the image/config, run: ./scripts/agent/dispatch-ops.sh helm-deploy" >&2
      }
    else
      echo "    skip kubectl — run: ./scripts/agent/dispatch-ops.sh clerk-refresh"
    fi
  else
    echo "==> 3/4 no aws CLI — dispatch GHA for SSM + SPA + core restart:"
    echo "    ./scripts/agent/dispatch-ops.sh clerk-refresh"
  fi
  echo "==> done — open https://${ENGRESS_APP_ORIGIN:-engress.io}/sign-in"
}

cmd_diagnose() {
  clerk_require_secret
  local pk_host clerk_host code body
  pk_host="$(clerk_pk_frontend_host "$CLERK_PUBLISHABLE_KEY")"
  clerk_host="$(clerk_primary_domain_host || true)"
  echo "=== Clerk diagnose ==="
  echo "Publishable host: ${pk_host:-unknown}"
  echo "Clerk API domain: ${clerk_host:-unknown}"
  echo "Expected org:     ${ENGRESS_CLERK_ORG_ID}"
  echo "Secret key prefix: ${CLERK_SECRET_KEY:0:8}… (len=${#CLERK_SECRET_KEY})"
  echo "Publishable prefix: ${CLERK_PUBLISHABLE_KEY:0:12}… (len=${#CLERK_PUBLISHABLE_KEY})"
  echo
  echo "Organizations visible to secret key:"
  clerk_list_orgs || true
  echo
  body="$(clerk_api GET "/organizations/${ENGRESS_CLERK_ORG_ID}")"
  code="${body%%$'\n'*}"
  body="${body#*$'\n'}"
  echo "GET /organizations/${ENGRESS_CLERK_ORG_ID} → HTTP $code"
  [[ "$code" == "200" ]] && jq '{id,name,slug}' <<<"$body" || jq -c . <<<"$body" 2>/dev/null || echo "$body"
}

cmd_list_redirect_urls() {
  clerk_require_secret
  local code body
  body="$(clerk_api GET "/redirect_urls?limit=100")"
  code="${body%%$'\n'*}"
  body="${body#*$'\n'}"
  [[ "$code" == "200" ]] || { echo "$body" >&2; exit 1; }
  jq -r '.data[]? | "\(.id)\t\(.url)"' <<<"$body" | sort
}

cmd_get_domains() {
  clerk_require_secret
  local code body
  body="$(clerk_api GET "/domains")"
  code="${body%%$'\n'*}"
  body="${body#*$'\n'}"
  [[ "$code" == "200" ]] || { echo "$body" >&2; exit 1; }
  jq . <<<"$body"
}

case "$CMD" in
  verify) cmd_verify ;;
  diagnose) cmd_diagnose ;;
  configure) cmd_configure ;;
  sync-ssm) cmd_sync_ssm ;;
  build-spa) cmd_build_spa ;;
  refresh) cmd_refresh ;;
  list-redirect-urls|redirects) cmd_list_redirect_urls ;;
  get-domains|domains) cmd_get_domains ;;
  -h|--help|help|"") usage ;;
  *) echo "unknown command: $CMD" >&2; usage >&2; exit 1 ;;
esac
