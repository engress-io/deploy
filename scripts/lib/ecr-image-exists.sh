#!/usr/bin/env bash
# Check whether engress-edge and engress-core images exist in ECR for a tag.
set -euo pipefail

# shellcheck source=deploy/lib/image-tag.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/image-tag.sh"

flux_ecr_repo_name() {
  echo "${1##*/}"
}

flux_ecr_image_exists() {
  local region="$1" repo_url="$2" tag="$3"
  local name
  name="$(flux_ecr_repo_name "$repo_url")"
  aws ecr describe-images \
    --region "$region" \
    --repository-name "$name" \
    --image-ids "imageTag=${tag}" \
    --query 'length(imageDetails)' \
    --output text 2>/dev/null | grep -q '^[1-9]'
}

flux_ecr_pair_exists() {
  local region="$1" edge_repo="$2" api_repo="$3" tag="$4"
  flux_ecr_image_exists "$region" "$edge_repo" "$tag" && \
    flux_ecr_image_exists "$region" "$api_repo" "$tag"
}

# Prefer git-describe tag; fall back to :latest when ECR has it (common after build-push).
flux_resolve_deploy_tag() {
  local root="$1" tfvars="$2" region="$3" edge_repo="$4" api_repo="$5"
  local tag fallback=""
  tag="$(flux_resolve_image_tag "$root" "$tfvars")"

  if flux_ecr_pair_exists "$region" "$edge_repo" "$api_repo" "$tag"; then
    echo "$tag"
    return 0
  fi

  if [[ "$tag" != "latest" ]] && flux_ecr_pair_exists "$region" "$edge_repo" "$api_repo" "latest"; then
    echo "[ecr] tag=${tag} not in ECR — deploying :latest (run ./dev.sh build-push to publish ${tag})" >&2
    echo "latest"
    return 0
  fi

  echo "$tag"
}

flux_ecr_list_tags() {
  local region="$1" repo_url="$2" max="${3:-5}"
  local name
  name="$(flux_ecr_repo_name "$repo_url")"
  aws ecr describe-images \
    --region "$region" \
    --repository-name "$name" \
    --query 'reverse(sort_by(imageDetails,& imagePushedAt))[:'"$max"'].imageTags' \
    --output text 2>/dev/null || echo "(none)"
}
