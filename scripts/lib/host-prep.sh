#!/usr/bin/env bash
# Shared host prep for EC2 bootstrap: swap, docker daemon, disk checks.
set -euo pipefail

host_prep_swap_gb="${SWAP_SIZE_GB:-2}"
host_prep_min_swap_mb=512

host_prep_log() {
  echo "[host-prep] $*"
}

host_prep_disk_info() {
  host_prep_log "root disk: $(df -h / | awk 'NR==2 {print $2 " total, " $3 " used, " $4 " avail (" $5 " used)"}')"
  host_prep_log "swap: $(free -m | awk '/^Swap:/ {print $2 " MB total, " $3 " MB used"}')"
}

host_prep_ensure_swap() {
  local sw want_mb run
  sw="$(free -m | awk '/^Swap:/ {print $2}')"
  want_mb=$((host_prep_swap_gb * 1024))
  run() {
    if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi
  }
  if [[ "${sw:-0}" -ge "$host_prep_min_swap_mb" ]]; then
    host_prep_log "swap OK (${sw} MB)"
    return 0
  fi

  host_prep_log "adding ${host_prep_swap_gb}G swap (t4g.micro needs swap for go build)"
  if [[ -f /swapfile ]]; then
    run swapoff /swapfile 2>/dev/null || true
    run rm -f /swapfile
  fi
  run bash -c "fallocate -l ${host_prep_swap_gb}G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((host_prep_swap_gb * 1024))"
  run chmod 600 /swapfile
  run mkswap /swapfile
  run swapon /swapfile
  if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
    run bash -c "echo '/swapfile none swap sw 0 0' >> /etc/fstab"
  fi
  host_prep_disk_info
}

host_prep_ensure_docker() {
  if ! command -v docker >/dev/null; then
    host_prep_log "ERROR: docker not installed" >&2
    return 1
  fi

  local run
  run() {
    if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi
  }

  if systemctl is-active --quiet docker 2>/dev/null; then
    host_prep_log "docker daemon running"
  else
    host_prep_log "starting docker daemon"
    run systemctl enable docker
    run systemctl start docker
  fi

  local i
  for i in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
      host_prep_log "docker ready"
      return 0
    fi
    sleep 2
  done

  host_prep_log "ERROR: docker daemon not ready after 60s" >&2
  run systemctl status docker --no-pager >&2 || true
  return 1
}
