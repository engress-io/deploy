#!/usr/bin/env bash
# Cross-compile engress agent with staging embedded defaults and upload to staging downloads path.
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/scripts/lib/workspace.sh"
engress_export_workspace
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/scripts/lib/ssm-deploy-config.sh"

AGENT_ROOT="${ENGRESS_AGENT_ROOT:-$ENGRESS_WORKSPACE_ROOT/agent}"
REGION="${AWS_REGION:-us-east-2}"
BUCKET="${ENGRESS_STAGING_DOWNLOADS_BUCKET:-}"
if [[ -z "$BUCKET" ]]; then
  BUCKET="$(aws ssm get-parameter --name engress-staging-downloads-bucket --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || true)"
fi
BUCKET="${BUCKET:-flux-downloads-327796148992}"
if [[ "${ENGRESS_ENV:-prod}" == "staging" && -z "${ENGRESS_STAGING_DOWNLOADS_BUCKET:-}" ]]; then
  # staging.engress.io CloudFront serves /downloads/* from the SPA origin bucket
  BUCKET="$(aws ssm get-parameter --name engress-staging-spa-bucket --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || true)"
  BUCKET="${BUCKET:-engress-staging-spa-327796148992}"
fi
PREFIX="${ENGRESS_STAGING_DOWNLOADS_PREFIX:-downloads/staging/latest}"

EDGE_ADDR="${ENGRESS_STAGING_EDGE_ADDR:-}"
if [[ -z "$EDGE_ADDR" ]]; then
  ip="${ENGRESS_DEPLOY_EDGE_IP:-}"
  [[ -n "$ip" && "$ip" != "0.0.0.0" ]] && EDGE_ADDR="${ip}:4433"
fi
EDGE_ADDR="${EDGE_ADDR:-staging-edge:4433}"
BASE_DOMAIN="${ENGRESS_DEPLOY_BASE_DOMAIN:-staging.engress.io}"

VERSION="${ENGRESS_AGENT_STAGING_VERSION:-staging-$(git -C "$ENGRESS_CORE_ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d)}"
SDK_VERSION=$(grep 'github.com/engress-io/sdk' "$AGENT_ROOT/go.mod" | grep -v '^replace' | awk '{print $2}' | sed 's/^v//')

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$AGENT_ROOT/internal/config/agent_defaults.yaml" <<EOF
edge_addr: "${EDGE_ADDR}"
base_domain: "${BASE_DOMAIN}"
domain_suffix: ".edge.${BASE_DOMAIN}"
EOF

LDFLAGS="-s -w -X 'github.com/engress-io/agent/internal/version.Version=${VERSION}' -X 'github.com/engress-io/agent/internal/version.SDKVersion=${SDK_VERSION}'"

mkdir -p "$TMP/dist"
cd "$AGENT_ROOT"
targets="linux:amd64 linux:arm64 darwin:amd64 darwin:arm64 windows:amd64 windows:arm64"
for target in $targets; do
  IFS=':' read -r goos goarch <<< "$target"
  out="engress-${goos}-${goarch}"
  [[ "$goos" == "windows" ]] && out="${out}.exe"
  CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" go build -buildvcs=false \
    -ldflags="${LDFLAGS}" -o "$TMP/dist/${out}" ./cmd/engress
  (cd "$TMP/dist" && sha256sum "${out}" > "${out}.sha256")
done

echo "==> upload s3://${BUCKET}/${PREFIX}/"
aws s3 sync "$TMP/dist/" "s3://${BUCKET}/${PREFIX}/" --delete --region "$REGION"

CORE_ROOT="${ENGRESS_CORE_ROOT:-$ENGRESS_WORKSPACE_ROOT/core}"
if [[ -f "$CORE_ROOT/packaging/install.sh" ]]; then
  sed "s|https://engress.io/downloads/latest|https://staging.engress.io/downloads/staging/latest|g" \
    "$CORE_ROOT/packaging/install.sh" > "$TMP/dist/install.sh"
  chmod +x "$TMP/dist/install.sh"
  aws s3 cp "$TMP/dist/install.sh" "s3://${BUCKET}/${PREFIX}/install.sh" --region "$REGION"
fi
if [[ -f "$CORE_ROOT/packaging/install.ps1" ]]; then
  sed "s|https://engress.io/downloads/latest|https://staging.engress.io/downloads/staging/latest|g" \
    "$CORE_ROOT/packaging/install.ps1" > "$TMP/dist/install.ps1"
  aws s3 cp "$TMP/dist/install.ps1" "s3://${BUCKET}/${PREFIX}/install.ps1" --region "$REGION"
fi

echo "Staging agent binaries published (version=${VERSION})"
