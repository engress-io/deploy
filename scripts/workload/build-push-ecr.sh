#!/usr/bin/env bash
# Build linux/arm64 engress-edge and/or engress-core images and push to ECR.
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

BUILD_EDGE=1
BUILD_CORE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --edge-only)
      BUILD_CORE=0
      shift
      ;;
    --core-only)
      BUILD_EDGE=0
      shift
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$BUILD_EDGE" -eq 0 && "$BUILD_CORE" -eq 0 ]]; then
  echo "ERROR: at least one of edge or core must be built" >&2
  exit 1
fi

TF="${TF:-terraform}"

container_tag_from_tfvars() {
  flux_resolve_image_tag "$ROOT" "$TF_DIR/terraform.tfvars"
}

PUSH_LATEST="${PUSH_LATEST:-1}"
TAG="${ENGRESS_IMAGE_TAG:-${FLUX_IMAGE_TAG:-$(container_tag_from_tfvars)}}"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$("$TF" -chdir="$TF_DIR" output -raw aws_region 2>/dev/null || echo us-east-2)}}"
ACCOUNT="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)}"
ACCOUNT="${ACCOUNT:-327796148992}"

if [[ "${ENGRESS_ENV:-prod}" == "staging" ]]; then
  EDGE_REPO="${ECR_EDGE_REPOSITORY:-${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/engress-staging-edge}"
  API_REPO="${ECR_API_REPOSITORY:-${ECR_CORE_REPOSITORY:-${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/engress-staging-core}}"
else
  EDGE_REPO="${ECR_EDGE_REPOSITORY:-$("$TF" -chdir="$TF_DIR" output -raw ecr_edge_repository_url 2>/dev/null || true)}"
  API_REPO="${ECR_API_REPOSITORY:-${ECR_CORE_REPOSITORY:-$("$TF" -chdir="$TF_DIR" output -raw ecr_api_repository_url 2>/dev/null || true)}}"
  if [[ -z "$EDGE_REPO" || -z "$API_REPO" ]]; then
    EDGE_REPO="${EDGE_REPO:-${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/engress-edge}"
    API_REPO="${API_REPO:-${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/engress-core}"
    echo "Using default ECR repositories (terraform outputs unavailable)"
  fi
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

EDGE_IMAGE="${EDGE_REPO}:${TAG}"
API_IMAGE="${API_REPO}:${TAG}"
PUSHED=()

if [[ "$BUILD_EDGE" -eq 1 ]]; then
  echo "==> compiling engress-edge (${GOOS}/${GOARCH}) tag=${TAG}"
  docker run --rm \
    "${DOCKER_SRC[@]}" -v "$ROOT/bin:/out" -w "$DOCKER_WORKDIR" \
    -e CGO_ENABLED=0 -e GOOS="$GOOS" -e GOARCH="$GOARCH" \
    golang:1.25 \
    go build -buildvcs=false -tags=ssm -ldflags="${LDFLAGS}" -o /out/engress-edge ./cmd/engress-edge

  echo "==> building + pushing ${EDGE_IMAGE}"
  docker build -f "$ENGRESS_DEPLOY_ROOT/docker/Dockerfile.edge" -t "$EDGE_IMAGE" "$ROOT"
  docker push "$EDGE_IMAGE"
  PUSHED+=("$EDGE_IMAGE")
  if [[ "$PUSH_LATEST" == "1" && "$TAG" != "latest" ]]; then
    docker tag "$EDGE_IMAGE" "${EDGE_REPO}:latest"
    docker push "${EDGE_REPO}:latest"
  fi
fi

if [[ "$BUILD_CORE" -eq 1 ]]; then
  echo "==> compiling engress-core (${GOOS}/${GOARCH}, ssm) tag=${TAG}"
  docker run --rm \
    "${DOCKER_SRC[@]}" -v "$ROOT/bin:/out" -w "$DOCKER_WORKDIR" \
    -e CGO_ENABLED=0 -e GOOS="$GOOS" -e GOARCH="$GOARCH" \
    golang:1.25 \
    go build -buildvcs=false -tags=ssm -ldflags="${LDFLAGS}" -o /out/engress-core ./cmd/engress-core

  echo "==> building + pushing ${API_IMAGE}"
  docker build -f "$ENGRESS_DEPLOY_ROOT/docker/Dockerfile.core" -t "$API_IMAGE" "$ROOT"
  docker push "$API_IMAGE"
  PUSHED+=("$API_IMAGE")
  if [[ "$PUSH_LATEST" == "1" && "$TAG" != "latest" ]]; then
    docker tag "$API_IMAGE" "${API_REPO}:latest"
    docker push "${API_REPO}:latest"
  fi
fi

# shellcheck source=deploy/lib/ecr-image-exists.sh
source "$SCRIPTS/../lib/ecr-image-exists.sh"
if [[ "${ECR_SKIP_VERIFY:-0}" != "1" ]]; then
  if [[ "$BUILD_EDGE" -eq 1 && "$BUILD_CORE" -eq 1 ]]; then
    if ! flux_ecr_pair_exists "$REGION" "$EDGE_REPO" "$API_REPO" "$TAG"; then
      echo "WARN: ECR verify could not confirm tag ${TAG}" >&2
    fi
  elif [[ "$BUILD_EDGE" -eq 1 ]]; then
    flux_ecr_image_exists "$REGION" "$EDGE_REPO" "$TAG" || echo "WARN: edge tag ${TAG} not verified" >&2
  else
    flux_ecr_image_exists "$REGION" "$API_REPO" "$TAG" || echo "WARN: core tag ${TAG} not verified" >&2
  fi
fi

echo ""
echo "Pushed:"
for img in "${PUSHED[@]}"; do
  echo "  ${img}"
done
echo ""
echo "Image tag: ${TAG}"
