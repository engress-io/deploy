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

cloudfront_id_from_tfstate() {
  local state_bucket="engress-terraform-state-${ACCOUNT_ID}"
  local state_key="${ENGRESS_TFSTATE_KEY:-engress/core/terraform.tfstate}"
  local tmp
  tmp="$(mktemp)"
  if ! aws s3 cp "s3://${state_bucket}/${state_key}" "$tmp" --region us-east-2 >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  python3 - "$tmp" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    state = json.load(f)
for res in state.get("resources", []):
    if res.get("type") != "aws_cloudfront_distribution" or res.get("name") != "frontend":
        continue
    for inst in res.get("instances", []):
        attrs = inst.get("attributes", {})
        cid = attrs.get("id")
        if not cid:
            continue
        aliases = attrs.get("aliases") or []
        if isinstance(aliases, list) and "engress.io" in aliases:
            print(cid)
            raise SystemExit(0)
        print(cid)
        raise SystemExit(0)
raise SystemExit(1)
PY
  rm -f "$tmp"
}

# Resolve CloudFront distribution (E1ABUIC4DB7I86 was destroyed in Jun 2026 recovery).
DIST_ID="${ENGRESS_CLOUDFRONT_DISTRIBUTION_ID:-}"
if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]]; then
  DIST_ID="$(aws ssm get-parameter --name engress-deploy-cloudfront-distribution-id --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || true)"
fi
if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]]; then
  DIST_ID="$(aws ssm get-parameter --name engress-cloudfront-distribution-id --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || true)"
fi
CF_DOMAIN="$(cd "$TF_DIR" && terraform output -raw cloudfront_domain 2>/dev/null || true)"
if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]]; then
  DIST_ID="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, 'engress.io')].Id | [0]" --output text 2>/dev/null || true)"
fi
if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]] && [[ -n "$CF_DOMAIN" && "$CF_DOMAIN" != "None" ]]; then
  DIST_ID="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?DomainName=='${CF_DOMAIN}'].Id | [0]" --output text 2>/dev/null || true)"
fi
if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]]; then
  DIST_ID="$(cloudfront_id_from_tfstate || true)"
fi
if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]]; then
  echo "ERROR: CloudFront distribution not found — set ENGRESS_CLOUDFRONT_DISTRIBUTION_ID or SSM engress-deploy-cloudfront-distribution-id" >&2
  exit 1
fi
echo "==> CloudFront distribution: ${DIST_ID}"

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

if [[ ! -d "$WEB/dist" ]]; then
  echo "ERROR: $WEB/dist missing — run npm run build first" >&2
  exit 1
fi

# Fail fast if we are about to ship a stale Oasis bundle.
if grep -rq 'single pane of glass\|no AWS console required' "$WEB/dist/" 2>/dev/null; then
  echo "ERROR: dist/ still contains legacy Oasis marketing copy — wrong core ref?" >&2
  exit 1
fi

echo "==> dist assets:"
ls -la "$WEB/dist/assets/" 2>/dev/null | tail -5 || true

echo "==> syncing dist/ to s3://${BUCKET} (preserving docs/ and downloads/ prefixes)"
aws s3 sync "$WEB/dist/" "s3://${BUCKET}/" --delete \
  --exclude "docs/*" \
  --exclude "downloads/*" \
  --region us-east-2

echo "==> invalidating CloudFront ${DIST_ID}"
INV_ID="$(aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" --query 'Invalidation.Id' --output text)"
echo "    invalidation: ${INV_ID}"

echo "==> done — open https://engress.io"
