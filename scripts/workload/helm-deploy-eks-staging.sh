#!/usr/bin/env bash
# Deploy engress-core and/or engress-edge to engress-staging-east.
set -euo pipefail
export ENGRESS_ENV=staging
exec "$(dirname "$0")/helm-deploy-eks.sh" --env staging --values-staging "$@"
