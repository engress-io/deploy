#!/usr/bin/env bash
# Deploy engress-core and/or engress-edge Helm releases to EKS (east).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helm-deploy-eks.sh" "$@"
