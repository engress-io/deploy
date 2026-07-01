#!/usr/bin/env bash
# docker login to ECR using the instance/laptop IAM role or AWS profile.
set -euo pipefail

flux_ecr_login() {
  local region="${1:-${AWS_REGION:-us-east-2}}"
  local registry="${2:-}"

  if [[ -z "$registry" ]]; then
    echo "flux_ecr_login: registry URL required" >&2
    return 1
  fi

  aws ecr get-login-password --region "$region" | \
    docker login --username AWS --password-stdin "$registry"
}
