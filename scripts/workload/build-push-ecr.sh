#!/usr/bin/env bash
# Build linux/arm64 engress-edge + engress-core images and push to ECR. Run from your laptop/CI.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEPLOY_ROOT="$(cd "$SCRIPTS/../.." && pwd)"
export ENGRESS_DEPLOY_ROOT="$DEPLOY_ROOT"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/scripts/lib/workspace.sh"
engress_export_workspace
ROOT="$ENGRESS_CORE_ROOT"
TF_DIR="$ENGRESS_TF_DIR"
cd "$ROOT"

# shellcheck source=/dev/null
source "$DEPLOY_ROOT/scripts/lib/image-tag.sh"
cd "$ROOT"

TF="${TF:-terraform}"

container_tag_from_tfvars() {
  flux_resolve_image_tag "$ROOT" "$TF_DIR/terraform.tfvars"
}

PUSH_LATEST="${PUSH_LATEST:-1}"
TAG="${ENGRESS_IMAGE_TAG:-${FLUX_IMAGE_TAG:-$(container_tag_from_tfvars)}}"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$("$TF" -chdir="$TF_DIR" output -raw aws_region 2>/dev/null || echo us-east-2)}}"
EDGE_REPO="${ECR_EDGE_REPOSITORY:-$("$TF" -chdir="$TF_DIR" output -raw ecr_edge_repository_url 2>/dev/null || true)}"
API_REPO="${ECR_API_REPOSITORY:-${ECR_CORE_REPOSITORY:-$("$TF" -chdir="$TF_DIR" output -raw ecr_api_repository_url 2>/dev/null || true)}}"

if [[ -z "$EDGE_REPO" || -z "$API_REPO" ]]; then
  ACCOUNT="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)}"
  ACCOUNT="${ACCOUNT:-327796148992}"
  EDGE_REPO="${EDGE_REPO:-${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/engress-edge}"
  API_REPO="${API_REPO:-${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/engress-core}"
  echo "Using default ECR repositories (terraform outputs unavailable)"
fi

# shellcheck source=/dev/null
source "$DEPLOY_ROOT/scripts/lib/ecr-login.sh"
flux_ecr_login "$REGION" "${EDGE_REPO%%/*}"

GOOS=linux
GOARCH=arm64
VERSION="$TAG"
LDFLAGS="-s -w -X github.com/engress-io/core/internal/version.Version=${VERSION}"

mkdir -p bin

# go.mod uses replace github.com/engress-io/sdk => ../sdk — mount superproject root when sdk is a sibling.
WORKSPACE="$(engress_workspace_root)"
if [[ -d "$WORKSPACE/sdk" && -d "$WORKSPACE/core" ]]; then
  DOCKER_SRC=(-v "$WORKSPACE:/ws")
  DOCKER_WORKDIR=/ws/core
else
  DOCKER_SRC=(-v "$ROOT:/src")
  DOCKER_WORKDIR=/src
fi

echo "==> compiling engress-edge (${GOOS}/${GOARCH}) tag=${TAG}"
docker run --rm \
  "${DOCKER_SRC[@]}" -v "$ROOT/bin:/out" -w "$DOCKER_WORKDIR" \
  -e CGO_ENABLED=0 -e GOOS="$GOOS" -e GOARCH="$GOARCH" \
  golang:1.25 \
  go build -buildvcs=false -tags=ssm -ldflags="${LDFLAGS}" -o /out/engress-edge ./cmd/engress-edge

echo "==> compiling engress-core (${GOOS}/${GOARCH}, ssm) tag=${TAG}"
docker run --rm \
  "${DOCKER_SRC[@]}" -v "$ROOT/bin:/out" -w "$DOCKER_WORKDIR" \
  -e CGO_ENABLED=0 -e GOOS="$GOOS" -e GOARCH="$GOARCH" \
  golang:1.25 \
  go build -buildvcs=false -tags=ssm -ldflags="${LDFLAGS}" -o /out/engress-core ./cmd/engress-core

EDGE_IMAGE="${EDGE_REPO}:${TAG}"
API_IMAGE="${API_REPO}:${TAG}"

echo "==> building + pushing ${EDGE_IMAGE}"
docker build -f "$ENGRESS_DEPLOY_ROOT/docker/Dockerfile.edge" -t "$EDGE_IMAGE" "$ROOT"
docker push "$EDGE_IMAGE"

echo "==> building + pushing ${API_IMAGE}"
docker build -f "$ENGRESS_DEPLOY_ROOT/docker/Dockerfile.core" -t "$API_IMAGE" "$ROOT"
docker push "$API_IMAGE"

if [[ "$PUSH_LATEST" == "1" && "$TAG" != "latest" ]]; then
  docker tag "$EDGE_IMAGE" "${EDGE_REPO}:latest"
  docker tag "$API_IMAGE" "${API_REPO}:latest"
  docker push "${EDGE_REPO}:latest"
  docker push "${API_REPO}:latest"
fi

# shellcheck source=deploy/lib/ecr-image-exists.sh
source "$SCRIPTS/../lib/ecr-image-exists.sh"
if [[ "${ECR_SKIP_VERIFY:-0}" != "1" ]]; then
  if ! flux_ecr_pair_exists "$REGION" "$EDGE_REPO" "$API_REPO" "$TAG"; then
    echo "WARN: ECR verify could not confirm tag ${TAG} (missing ecr:DescribeImages? set ECR_SKIP_VERIFY=1)" >&2
    echo "  engress-edge tags: $(flux_ecr_list_tags "$REGION" "$EDGE_REPO" 8)" >&2
    echo "  engress-core tags: $(flux_ecr_list_tags "$REGION" "$API_REPO" 8)" >&2
  fi
fi
if [[ "$TAG" != "latest" ]] && ! flux_ecr_image_exists "$REGION" "$EDGE_REPO" "latest"; then
  echo "WARN: :latest tag missing on engress-edge (PUSH_LATEST=${PUSH_LATEST})" >&2
fi

cat <<EOF

Pushed:
  ${EDGE_IMAGE}
  ${API_IMAGE}

Deploy on EC2:
  cd deploy/terraform && ./dev.sh app-update
  # or full Phase A: ./dev.sh phase-a-deploy -auto-approve

Image tag: ${TAG}
EOF
