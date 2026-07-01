#!/usr/bin/env bash
# Build the Engress SPA and upload to the CloudFront S3 origin.
# Requires: docker (for Node build), aws CLI, terraform state with enable_frontend=true.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=deploy/lib/workspace.sh
source "$SCRIPTS/../lib/workspace.sh"
engress_export_workspace
ROOT="$ENGRESS_CORE_ROOT"
TF_DIR="$ENGRESS_TF_DIR"
cd "$ROOT"

WEB="$ROOT/web"

REGION="${AWS_REGION:-$(cd "$TF_DIR" && terraform output -raw aws_region 2>/dev/null || echo us-east-2)}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 327796148992)"
BUCKET="${ENGRESS_SPA_BUCKET:-}"
if [[ -z "$BUCKET" ]]; then
  BUCKET="$(cd "$TF_DIR" && terraform output -raw frontend_bucket 2>/dev/null || true)"
fi
if [[ -z "$BUCKET" || "$BUCKET" == *error* || "$BUCKET" == *Terraform* ]]; then
  BUCKET=""
fi
BUCKET="${BUCKET:-flux-spa-${ACCOUNT_ID}}"
if [[ -z "$BUCKET" ]]; then
  echo "frontend_bucket missing — set ENGRESS_SPA_BUCKET or enable_frontend=true and terraform apply" >&2
  exit 1
fi
CF_DOMAIN="$(cd "$TF_DIR" && terraform output -raw cloudfront_domain 2>/dev/null || true)"
DIST_ID="${ENGRESS_CLOUDFRONT_DISTRIBUTION_ID:-}"
if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]]; then
  DIST_ID="$(AWS_PROFILE="${AWS_PROFILE:-}" aws cloudfront list-distributions \
    --query "DistributionList.Items[?DomainName=='${CF_DOMAIN}'].Id | [0]" --output text 2>/dev/null || true)"
fi
if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]]; then
  DIST_ID="$(AWS_PROFILE="${AWS_PROFILE:-}" aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Aliases.Items, 'engress.io')].Id | [0]" --output text 2>/dev/null || true)"
fi

PK="${VITE_CLERK_PUBLISHABLE_KEY:-}"
CLERK_ORG_ID="${VITE_CLERK_ORG_ID:-}"
if [[ -z "$PK" ]]; then
  PK="$(aws ssm get-parameter --name next-clerk-publishable-key --region "$REGION" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)"
fi
if [[ -z "$PK" ]]; then
  echo "Set VITE_CLERK_PUBLISHABLE_KEY or SSM next-clerk-publishable-key" >&2
  exit 1
fi

SIGN_UP="${VITE_CLERK_SIGN_UP_ENABLED:-true}"

echo "==> syncing dist/ to s3://${BUCKET}"
aws s3 sync "$WEB/dist/" "s3://${BUCKET}/" --delete --region us-east-2

if [[ -n "$DIST_ID" && "$DIST_ID" != "None" ]]; then
  echo "==> invalidating CloudFront ${DIST_ID}"
  aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" --query 'Invalidation.Id' --output text
fi

echo "==> done — open https://engress.io"
