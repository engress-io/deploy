#!/usr/bin/env bash
# Deploy engress-core and/or engress-edge to engress-east (us-east-2).
set -euo pipefail
exec "$(dirname "$0")/helm-deploy-eks.sh" --values-east "$@"
