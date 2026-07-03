#!/usr/bin/env bash
# Cross-compile engress agent with production embedded defaults and upload to prod downloads path.
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/scripts/lib/workspace.sh"
engress_export_workspace
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/scripts/lib/ssm-deploy-config.sh"

AGENT_ROOT="${ENGRESS_AGENT_ROOT:-$ENGRESS_WORKSPACE_ROOT/agent}"
REGION="${AWS_REGION:-us-east-2}"
BUCKET="${ENGRESS_DOWNLOADS_BUCKET:-flux-downloads-327796148992}"
PREFIX_LATEST="${ENGRESS_DOWNLOADS_PREFIX:-downloads/latest}"

EDGE_ADDR="${ENGRESS_PROD_EDGE_ADDR:-}"
if [[ -z "$EDGE_ADDR" ]]; then
  ip="${ENGRESS_DEPLOY_EDGE_IP:-}"
  [[ -n "$ip" && "$ip" != "0.0.0.0" ]] && EDGE_ADDR="${ip}:4433"
fi
EDGE_ADDR="${EDGE_ADDR:-edge.engress.io:4433}"
BASE_DOMAIN="${ENGRESS_DEPLOY_BASE_DOMAIN:-engress.io}"

VERSION="${ENGRESS_AGENT_PROD_VERSION:-${IMAGE_TAG:-${ENGRESS_IMAGE_TAG:-}}}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(git -C "$ENGRESS_CORE_ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d)"
fi
SDK_VERSION=$(grep 'github.com/engress-io/sdk' "$AGENT_ROOT/go.mod" | awk '{print $2}' | sed 's/v//')

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$AGENT_ROOT/internal/config/agent_defaults.yaml" <<EOF
edge_addr: "${EDGE_ADDR}"
base_domain: "${BASE_DOMAIN}"
domain_suffix: ".edge.${BASE_DOMAIN}"
EOF

LDFLAGS="-s -w -X github.com/engress-io/agent/internal/version.Version=${VERSION} -X github.com/engress-io/agent/internal/version.SDKVersion=${SDK_VERSION}"

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

echo "==> upload s3://${BUCKET}/${PREFIX_LATEST}/"
aws s3 sync "$TMP/dist/" "s3://${BUCKET}/${PREFIX_LATEST}/" --delete --region "$REGION"
echo "==> upload s3://${BUCKET}/downloads/versions/${VERSION}/"
aws s3 sync "$TMP/dist/" "s3://${BUCKET}/downloads/versions/${VERSION}/" --region "$REGION"
echo "Production agent binaries published (version=${VERSION})"
