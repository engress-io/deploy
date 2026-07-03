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
case "$status" in
  pending-upgrade|pending-install|pending-rollback)
    echo "WARN: clearing pending ${release} helm release (status=${status})"
    helm rollback "$release" -n "$namespace" 0 2>/dev/null || helm rollback "$release" -n "$namespace" || true
    ;;
  failed|unknown)
    last="$(helm history "$release" -n "$namespace" -o json 2>/dev/null | jq -r '[.[] | select(.status=="deployed") | .revision] | last // empty')"
    if [[ -n "$last" ]]; then
      echo "WARN: rolling back failed ${release} to revision ${last}"
      helm rollback "$release" -n "$namespace" "$last" || true
    fi
    ;;
esac