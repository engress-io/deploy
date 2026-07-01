#!/usr/bin/env bash
# Prepended to every SSM remote script. SSM RunShellScript uses a minimal PATH
# (/usr/bin:/bin) so /usr/local/bin/aws (AWS CLI v2) is invisible unless we fix it.
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

flux_ssm_require_cmd() {
  local name="$1"
  shift
  command -v "$name" >/dev/null 2>&1 && return 0
  local p
  for p in "$@"; do
    if [[ -x "$p" ]]; then
      export PATH="$(dirname "$p"):$PATH"
      return 0
    fi
  done
  return 1
}

flux_ssm_install_aws_cli() {
  local zip=""
  case "$(uname -m)" in
    x86_64|amd64) zip="awscli-exe-linux-x86_64.zip" ;;
    aarch64|arm64) zip="awscli-exe-linux-aarch64.zip" ;;
    *)
      echo "[ssm-remote-env] unsupported CPU: $(uname -m)" >&2
      return 1
      ;;
  esac
  echo "[ssm-remote-env] installing AWS CLI v2 ($zip)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl unzip ca-certificates
  curl -fsSL "https://awscli.amazonaws.com/${zip}" -o /tmp/awscliv2.zip
  rm -rf /tmp/aws
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
  export PATH="/usr/local/bin:$PATH"
}

flux_ssm_install_git() {
  echo "[ssm-remote-env] installing git"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq git
}

flux_ssm_ensure_host_deps() {
  if ! flux_ssm_require_cmd aws /usr/local/bin/aws /usr/bin/aws; then
    flux_ssm_install_aws_cli
  fi
  flux_ssm_require_cmd aws /usr/local/bin/aws /usr/bin/aws || {
    echo "[ssm-remote-env] ERROR: aws CLI still missing after install" >&2
    exit 127
  }
  if ! flux_ssm_require_cmd git /usr/bin/git; then
    flux_ssm_install_git
  fi
  flux_ssm_require_cmd curl /usr/bin/curl || {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq curl
  }
}

flux_ssm_ensure_host_deps
