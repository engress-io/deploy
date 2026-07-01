#!/usr/bin/env bash
# Resolve the ECR image tag used by build-push-ecr.sh and app-update.sh.
set -euo pipefail

flux_resolve_image_tag() {
  local root="${1:-.}"
  local tfvars="${2:-}"

  if [[ -n "${FLUX_IMAGE_TAG:-}" ]]; then
    echo "$FLUX_IMAGE_TAG"
    return
  fi

  if [[ -n "$tfvars" && -f "$tfvars" ]]; then
    local t
    t="$(grep -E '^[[:space:]]*container_image_tag[[:space:]]*=' "$tfvars" 2>/dev/null | head -1 \
      | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' || true)"
    if [[ -n "$t" ]]; then
      echo "$t"
      return
    fi
  fi

  if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$root" describe --tags --always --dirty 2>/dev/null | tr '/' '-' || echo latest
    return
  fi

  echo latest
}
