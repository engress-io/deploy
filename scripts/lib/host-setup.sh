#!/usr/bin/env bash
# EC2 host setup: SSM agent, apt packages, Docker, AWS CLI v2, swap.
# Used by Terraform user-data (embedded) and manual installs (./deploy/lib/host-setup.sh).
set -euo pipefail

flux_setup_run() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

flux_setup_log() {
  echo "[host-setup] $*"
}

flux_setup_ensure_ssm_agent() {
  flux_setup_log "ensuring SSM agent"
  if snap list amazon-ssm-agent >/dev/null 2>&1; then
    flux_setup_log "using snap amazon-ssm-agent (Ubuntu AMI default)"
    snap start amazon-ssm-agent || true
  elif command -v snap >/dev/null 2>&1; then
    flux_setup_log "installing amazon-ssm-agent via snap"
    snap install amazon-ssm-agent --classic
    snap start amazon-ssm-agent || true
  elif dpkg -l amazon-ssm-agent >/dev/null 2>&1; then
    flux_setup_log "using deb amazon-ssm-agent"
    flux_setup_run systemctl enable amazon-ssm-agent || true
    flux_setup_run systemctl start amazon-ssm-agent || true
  else
    flux_setup_log "installing amazon-ssm-agent via deb (no snap)"
    local arch deb=""
    case "$(dpkg --print-architecture)" in
      arm64) deb="https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_arm64/amazon-ssm-agent.deb" ;;
      amd64) deb="https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb" ;;
    esac
    if [[ -n "$deb" ]]; then
      curl -fsSL "$deb" -o /tmp/amazon-ssm-agent.deb
      if flux_setup_run dpkg -i /tmp/amazon-ssm-agent.deb 2>/dev/null; then
        flux_setup_run systemctl enable amazon-ssm-agent || true
        flux_setup_run systemctl start amazon-ssm-agent || true
      else
        flux_setup_log "WARN: deb install failed — retrying via snap"
        flux_setup_run apt-get install -y snapd
        snap install amazon-ssm-agent --classic || true
        snap start amazon-ssm-agent || true
      fi
    fi
  fi
  local i
  for i in $(seq 1 30); do
    systemctl is-active --quiet amazon-ssm-agent 2>/dev/null && break
    snap services amazon-ssm-agent 2>/dev/null | grep -q active && break
    sleep 2
  done
  flux_setup_log "SSM agent running (registration may take 1–2 min)"
}

flux_setup_install_apt_base() {
  export DEBIAN_FRONTEND=noninteractive
  flux_setup_run apt-get update
  flux_setup_run apt-get install -y git curl openssl ca-certificates unzip
}

flux_setup_install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    flux_setup_log "docker already installed"
    return 0
  fi
  flux_setup_log "installing Docker via get.docker.com"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  flux_setup_run sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
}

flux_setup_install_aws_cli() {
  if command -v aws >/dev/null 2>&1 && aws --version 2>&1 | grep -q 'aws-cli/2'; then
    flux_setup_log "AWS CLI v2 already installed"
    return 0
  fi
  local zip
  case "$(uname -m)" in
    x86_64|amd64) zip="awscli-exe-linux-x86_64.zip" ;;
    aarch64|arm64) zip="awscli-exe-linux-aarch64.zip" ;;
    *)
      flux_setup_log "ERROR: unsupported CPU architecture: $(uname -m)" >&2
      return 1
      ;;
  esac
  flux_setup_log "installing AWS CLI v2 ($zip)"
  curl -fsSL "https://awscli.amazonaws.com/${zip}" -o /tmp/awscliv2.zip
  rm -rf /tmp/aws
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  flux_setup_run /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
}

flux_setup_install_deps() {
  flux_setup_install_apt_base
  flux_setup_install_docker
  flux_setup_install_aws_cli
}

flux_setup_ensure_swap() {
  local swap_gb="${1:-2}"
  local sw min_mb=512
  sw="$(free -m | awk '/^Swap:/ {print $2}')"
  if [[ "${sw:-0}" -ge "$min_mb" ]]; then
    flux_setup_log "swap OK (${sw} MB)"
    return 0
  fi
  flux_setup_log "adding ${swap_gb}G swap"
  flux_setup_run bash -c "fallocate -l ${swap_gb}G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((swap_gb * 1024))"
  flux_setup_run chmod 600 /swapfile
  flux_setup_run mkswap /swapfile
  flux_setup_run swapon /swapfile
  if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
    flux_setup_run bash -c "echo '/swapfile none swap sw 0 0' >> /etc/fstab"
  fi
}

flux_setup_ensure_docker_ready() {
  flux_setup_run systemctl enable docker
  flux_setup_run systemctl start docker
  local i
  for i in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
      flux_setup_log "docker ready"
      return 0
    fi
    sleep 2
  done
  flux_setup_log "ERROR: docker not ready" >&2
  flux_setup_run systemctl status docker --no-pager >&2 || true
  return 1
}

flux_setup_disk_info() {
  flux_setup_log "root disk: $(df -h / | awk 'NR==2 {print $2" total, "$4" free"}')"
  flux_setup_log "swap: $(free -m | awk '/^Swap:/ {print $2" MB total"}')"
}

flux_setup_all() {
  local swap_gb="${1:-${SWAP_SIZE_GB:-2}}"
  flux_setup_ensure_ssm_agent
  flux_setup_install_deps
  flux_setup_ensure_swap "$swap_gb"
  flux_setup_ensure_docker_ready
  flux_setup_disk_info
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-all}" in
    all) flux_setup_all "${2:-${SWAP_SIZE_GB:-2}}" ;;
    ssm) flux_setup_ensure_ssm_agent ;;
    deps) flux_setup_install_deps; flux_setup_ensure_docker_ready ;;
    apt) flux_setup_install_apt_base ;;
    docker) flux_setup_install_docker; flux_setup_ensure_docker_ready ;;
    aws) flux_setup_install_aws_cli ;;
    swap) flux_setup_ensure_swap "${2:-${SWAP_SIZE_GB:-2}}" ;;
    *)
      echo "usage: $0 [all|ssm|deps|apt|docker|aws|swap] [swap_gb]" >&2
      exit 1
      ;;
  esac
fi
