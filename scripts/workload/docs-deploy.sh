#!/usr/bin/env bash
# Build Docusaurus docs and sync to S3 under docs/ prefix + invalidate CloudFront.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=deploy/lib/workspace.sh
source "$SCRIPTS/../lib/workspace.sh"
engress_export_workspace

WORKSPACE="$(engress_workspace_root)"
DOCS="${ENGRESS_DOCS_ROOT:-$WORKSPACE/docs}"
TF_DIR="$ENGRESS_TF_DIR"

REGION="${AWS_REGION:-us-east-2}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 327796148992)"
BUCKET="${ENGRESS_SPA_BUCKET:-flux-spa-${ACCOUNT_ID}}"

DIST_ID="${ENGRESS_CLOUDFRONT_DISTRIBUTION_ID:-}"
if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]]; then
  DIST_ID="$(aws ssm get-parameter --name engress-deploy-cloudfront-distribution-id --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || true)"
fi
if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]]; then
  DIST_ID="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, 'engress.io')].Id | [0]" --output text 2>/dev/null || true)"
fi

PK="${VITE_CLERK_PUBLISHABLE_KEY:-${CLERK_PUBLISHABLE_KEY:-}}"
if [[ -z "$PK" ]]; then
  PK="$(aws ssm get-parameter --name next-clerk-publishable-key --region "$REGION" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)"
fi
if [[ -z "$PK" ]]; then
  PK="$(aws ssm get-parameter --name engress-clerk-publishable-key --region "$REGION" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)"
fi
[[ -n "$PK" ]] || { echo "ERROR: Clerk publishable key required for internal docs gate" >&2; exit 1; }

[[ -d "$DOCS" ]] || { echo "ERROR: docs not found at $DOCS" >&2; exit 1; }

echo "==> building Docusaurus ($DOCS)"
cd "$DOCS"
if command -v npm >/dev/null 2>&1; then
  if [[ -f package-lock.json ]]; then
    npm ci
  else
    npm install
  fi
  export VITE_CLERK_PUBLISHABLE_KEY="$PK"
  export CLERK_PUBLISHABLE_KEY="$PK"
  npm run build
else
  echo "==> npm not found — building with node:22 docker image"
  docker run --rm \
    -v "$DOCS:/app" -w /app \
    -e VITE_CLERK_PUBLISHABLE_KEY="$PK" \
    -e CLERK_PUBLISHABLE_KEY="$PK" \
    node:22-bookworm \
    bash -c 'npm ci && npm run build'
fi

echo "==> syncing build/ to s3://${BUCKET}/docs/"
aws s3 sync build/ "s3://${BUCKET}/docs/" --delete --region "$REGION"

if [[ -n "$DIST_ID" && "$DIST_ID" != "None" ]]; then
  echo "==> invalidating CloudFront ${DIST_ID} /docs/*"
  aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/docs/*" --query 'Invalidation.Id' --output text
fi

echo "==> done — open https://engress.io/docs/"
