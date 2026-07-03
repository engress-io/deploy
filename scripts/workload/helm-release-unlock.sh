#!/usr/bin/env bash
# helm-release-unlock.sh RELEASE NAMESPACE
# Roll back Helm releases stuck in pending-upgrade or pending-install.
set -euo pipefail

release="${1:?release name required}"
namespace="${2:?namespace required}"

if ! helm status "$release" -n "$namespace" -o json 2>/dev/null | jq -e . >/dev/null 2>&1; then
  exit 0
fi

status="$(helm status "$release" -n "$namespace" -o json | jq -r '.info.status')"
if [[ "$status" == "pending-upgrade" || "$status" == "pending-install" ]]; then
  echo "WARN: clearing pending ${release} helm release (status=${status})"
  helm rollback "$release" -n "$namespace" || true
fi