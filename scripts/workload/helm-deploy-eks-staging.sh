#!/usr/bin/env bash
# Deploy engress-core and/or engress-edge to engress-staging-east.
set -euo pipefail
export ENGRESS_ENV=staging
export HELM_UPGRADE_EXTRA_ARGS="--timeout 10m --wait --atomic"
exec "$(dirname "$0")/helm-deploy-eks.sh" --env staging --values-staging "$@"
