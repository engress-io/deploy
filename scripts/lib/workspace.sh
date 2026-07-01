#!/usr/bin/env bash
# Path resolution for engress-io/deploy submodule.
if [[ -z "${AWS_PROFILE:-}" ]]; then
  uuid_head=""
  [[ -f /sys/class/dmi/id/product_uuid ]] && uuid_head="$(head -c 3 /sys/class/dmi/id/product_uuid 2>/dev/null || true)"
  if [[ ! "$uuid_head" =~ ^ec2 && -z "${GITHUB_ACTIONS:-}" && -z "${CI:-}" ]]; then
    export AWS_PROFILE="${AWS_PROFILE:-ghostweasel-flux}"
  fi
fi

engress_deploy_root() {
  if [[ -n "${ENGRESS_DEPLOY_ROOT:-}" ]]; then
    printf '%s\n' "$ENGRESS_DEPLOY_ROOT"
    return 0
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  printf '%s\n' "$here"
}

engress_workspace_root() {
  if [[ -n "${ENGRESS_WORKSPACE_ROOT:-}" ]]; then
    printf '%s\n' "$ENGRESS_WORKSPACE_ROOT"
    return 0
  fi
  local deploy_root super
  deploy_root="$(engress_deploy_root)"
  super="$(git -C "$deploy_root" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
  if [[ -n "$super" ]]; then
    printf '%s\n' "$super"
    return 0
  fi
  if [[ -d "$deploy_root/../core" ]]; then
    (cd "$deploy_root/.." && pwd)
    return 0
  fi
  printf '%s\n' "$deploy_root"
}

engress_core_root() {
  if [[ -n "${ENGRESS_CORE_ROOT:-}" ]]; then
    printf '%s\n' "$ENGRESS_CORE_ROOT"
    return 0
  fi
  local ws
  ws="$(engress_workspace_root)"
  if [[ -d "$ws/core" ]]; then
    printf '%s\n' "$ws/core"
    return 0
  fi
  printf '%s\n' "$ws"
}

engress_scripts_root() {
  if [[ -n "${ENGRESS_SCRIPTS_ROOT:-}" ]]; then
    printf '%s\n' "$ENGRESS_SCRIPTS_ROOT"
    return 0
  fi
  local ws
  ws="$(engress_workspace_root)"
  if [[ -d "$ws/scripts" ]]; then
    printf '%s\n' "$ws/scripts"
    return 0
  fi
  printf '%s\n' "$(engress_deploy_root)/scripts"
}

engress_tf_dir() {
  if [[ -n "${ENGRESS_TF_DIR:-}" ]]; then
    printf '%s\n' "$ENGRESS_TF_DIR"
    return 0
  fi
  if [[ -d "$(engress_deploy_root)/terraform/_legacy-monolith" ]]; then
    printf '%s\n' "$(engress_deploy_root)/terraform/_legacy-monolith"
    return 0
  fi
  printf '%s\n' "$(engress_core_root)/deploy/terraform"
}

engress_charts_root() {
  if [[ -n "${ENGRESS_CHARTS_ROOT:-}" ]]; then
    printf '%s\n' "$ENGRESS_CHARTS_ROOT"
    return 0
  fi
  printf '%s\n' "$(engress_deploy_root)/helm"
}

engress_export_workspace() {
  export ENGRESS_DEPLOY_ROOT="${ENGRESS_DEPLOY_ROOT:-$(engress_deploy_root)}"
  export ENGRESS_WORKSPACE_ROOT="${ENGRESS_WORKSPACE_ROOT:-$(engress_workspace_root)}"
  export ENGRESS_CORE_ROOT="${ENGRESS_CORE_ROOT:-$(engress_core_root)}"
  export ENGRESS_SCRIPTS_ROOT="${ENGRESS_SCRIPTS_ROOT:-$(engress_scripts_root)}"
  export ENGRESS_TF_DIR="${ENGRESS_TF_DIR:-$(engress_tf_dir)}"
  export ENGRESS_CHARTS_ROOT="${ENGRESS_CHARTS_ROOT:-$(engress_charts_root)}"
}
