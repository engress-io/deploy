#!/usr/bin/env bash
# Deploy engress-edge to engress-west (us-west-1). Core stays in us-east-2.
set -euo pipefail
exec "$(dirname "$0")/helm-deploy-eks.sh" \
  --region us-west-1 \
  --cluster "${ENGRESS_DEPLOY_EKS_WEST_CLUSTER:-engress-west}" \
  --values-west \
  --edge-only \
  "$@"
