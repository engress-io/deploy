#!/usr/bin/env bash
# Build Engress SPA with VITE_CLERK_PUBLISHABLE_KEY and sync to S3 + CloudFront.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=deploy/lib/workspace.sh
source "$SCRIPTS/../lib/workspace.sh"
# shellcheck source=deploy/lib/clerk.sh
source "$SCRIPTS/../lib/clerk.sh"
engress_export_workspace

ROOT="$ENGRESS_CORE_ROOT"
WEB="$ROOT/web"
TF_DIR="$ENGRESS_TF_DIR"
cd "$ROOT"

REGION="${AWS_REGION:-$(cd "$TF_DIR" && terraform output -raw aws_region 2>/dev/null || echo us-east-2)}"
PK="${VITE_CLERK_PUBLISHABLE_KEY:-${CLERK_PUBLISHABLE_KEY:-}}"
if [[ -z "$PK" ]]; then
  clerk_load_credentials "$REGION" || true
  PK="${CLERK_PUBLISHABLE_KEY:-}"
fi
[[ -n "$PK" ]] || { echo "ERROR: Clerk publishable key required" >&2; exit 1; }

echo "==> npm build (web/)"
cd "$WEB"
if [[ -f package-lock.json ]]; then
  npm ci
else
  npm install
fi
export VITE_CLERK_PUBLISHABLE_KEY="$PK"
export VITE_CLERK_SIGN_UP_ENABLED="${VITE_CLERK_SIGN_UP_ENABLED:-true}"
if [[ "${ENGRESS_ENV:-prod}" == "staging" ]]; then
  export VITE_CLERK_IS_SATELLITE="${VITE_CLERK_IS_SATELLITE:-true}"
  export VITE_CLERK_DOMAIN="${VITE_CLERK_DOMAIN:-staging.engress.io}"
  export VITE_CLERK_SIGN_IN_URL="${VITE_CLERK_SIGN_IN_URL:-https://staging.engress.io/sign-in}"
  export VITE_CLERK_SIGN_UP_URL="${VITE_CLERK_SIGN_UP_URL:-https://staging.engress.io/sign-up}"
  export VITE_STAGING_STAFF_ONLY="${VITE_STAGING_STAFF_ONLY:-true}"
  export VITE_CLERK_SIGN_UP_ENABLED="${VITE_CLERK_SIGN_UP_ENABLED:-false}"
fi
npm run build

echo "==> S3 sync + CloudFront invalidation"
exec "$SCRIPTS/spa-deploy.sh"
