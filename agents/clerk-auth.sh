#!/usr/bin/env bash
# Clerk auth CLI — verify, configure instance, sync SSM, refresh production login.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=deploy/lib/clerk.sh
source "$ROOT/deploy/lib/clerk.sh"
# Normalize Cursor secret aliases before any command.
# shellcheck source=agent/cloud-env-bootstrap.sh
source "$ROOT/agent/cloud-env-bootstrap.sh" 2>/dev/null || true
export CLOUD_ENV_CHECK=0

CMD="${1:-}"
REGION="${AWS_REGION:-us-east-2}"

usage() {
  cat <<EOF
Usage: clerk-auth.sh <command>

Commands:
  verify              Check keys match Engress Clerk app + org ${ENGRESS_CLERK_ORG_ID}
  diagnose            List orgs + HTTP status (debug org id mismatch)
  configure           Ensure redirect URLs + beta org settings (no AWS)
  sync-ssm            Write env Clerk keys → SSM (needs aws CLI)
  build-spa           npm build + S3 sync + CF invalidation (needs aws CLI)
  refresh             configure + sync-ssm + build-spa + restart core (full login fix)
  list-redirect-urls  Show whitelisted redirect URLs
  get-domains         Show Clerk domains / frontend API host

Credentials (Cursor cloud agent):
  CLERK_SECRET_KEY, CLERK_PUBLISHABLE_KEY, CLERK_WEBHOOK_SECRET (optional)

Then restart engress-core on EKS after sync-ssm:
  kubectl rollout restart deployment/engress-core -n engress

Or dispatch: ./scripts/agent/dispatch-ops.sh clerk-refresh
EOF
}

clerk_require_secret() {
  if ! clerk_load_credentials "$REGION"; then
    echo "ERROR: Clerk credentials missing." >&2
    echo "  Cursor: CLERK_SECRET_KEY + CLERK_PUBLISHABLE_KEY" >&2
    echo "  GitHub: add same names to repo secrets for dispatch-ops clerk-refresh" >&2
    exit 1
  fi
}

cmd_verify() {
  clerk_require_secret
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
  clerk_verify_engress_org >/dev/null || exit 1
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
  exec bash "$ROOT/deploy/scripts/spa-build-deploy.sh"
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
    bash "$ROOT/deploy/scripts/spa-build-deploy.sh"
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
