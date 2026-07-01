#!/usr/bin/env bash
# Shared edge.yaml generation for bootstrap.sh and build.sh.
set -euo pipefail

flux_config_dir="${ENGRESS_CONFIG_DIR:-${FLUX_CONFIG_DIR:-deploy/data}}"
flux_config_path="${ENGRESS_CONFIG_PATH:-${FLUX_CONFIG_PATH:-$flux_config_dir/edge.yaml}}"
flux_mtls_mode="${ENGRESS_MTLS_MODE:-${FLUX_MTLS_MODE:-optional}}"

flux_derive_domain_suffix() {
  local base="$1"
  if [[ "$base" == *.sslip.io ]]; then
    echo ".sslip.io"
    return
  fi
  if [[ "$base" == *.* ]]; then
    echo ".${base#*.}"
    return
  fi
  echo ".$base"
}

# Agent tunnel address: always IP:4433 (not hostname:4433).
flux_resolve_edge_addr() {
  local base="${1:-}"
  if [[ -n "${ENGRESS_ELASTIC_IP:-${FLUX_ELASTIC_IP:-}}" ]]; then
    echo "${ENGRESS_ELASTIC_IP:-${FLUX_ELASTIC_IP}}:4433"
    return
  fi
  if [[ "$base" == *.sslip.io ]]; then
    echo "${base%.sslip.io}:4433"
    return
  fi
  local ip=""
  if ip="$(flux_detect_public_ip 2>/dev/null)"; then
    echo "${ip}:4433"
    return
  fi
  echo "${base}:4433"
}

flux_detect_public_ip() {
  local ip=""
  if ip=$(curl -sf --connect-timeout 2 -H "X-aws-ec2-metadata-token: $(curl -sf --connect-timeout 1 -X PUT \
    http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)" \
    http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null); then
    echo "$ip"
    return
  fi
  if ip=$(curl -sf --connect-timeout 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null); then
    echo "$ip"
    return
  fi
  if ip=$(curl -sf --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]'); then
    echo "$ip"
    return
  fi
  echo "ERROR: could not detect public IP; set ENGRESS_BASE_DOMAIN (or FLUX_BASE_DOMAIN) or --base-domain" >&2
  return 1
}

# CloudFront /api/* origin hostname — edge must accept this Host for API proxying.
flux_resolve_control_origin_host() {
  local tf_dir="${1:-deploy/terraform}"
  local tf="${TF:-terraform}"
  local host="" base="" tfvars="${tf_dir}/terraform.tfvars"

  host="$("$tf" -chdir="$tf_dir" output -raw api_origin_hostname 2>/dev/null || true)"
  if [[ -n "$host" ]]; then
    echo "$host"
    return 0
  fi

  host="$("$tf" -chdir="$tf_dir" output -raw edge_origin_hostname 2>/dev/null || true)"
  if [[ -n "$host" ]]; then
    echo "$host"
    return 0
  fi

  if [[ -f "$tfvars" ]]; then
    host="$(grep -E '^[[:space:]]*edge_origin_hostname[[:space:]]*=' "$tfvars" 2>/dev/null | head -1 \
      | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' || true)"
    if [[ -n "$host" ]]; then
      echo "$host"
      return 0
    fi
    base="$(grep -E '^[[:space:]]*base_domain[[:space:]]*=' "$tfvars" 2>/dev/null | head -1 \
      | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' || true)"
  fi

  if [[ -z "$base" ]]; then
    base="$("$tf" -chdir="$tf_dir" output -raw base_domain 2>/dev/null || true)"
  fi
  if [[ -n "$base" ]]; then
    echo "edge-origin.${base}"
    return 0
  fi
  return 1
}

# Appends mtls_mode to edge.yaml when absent (non-secret operational setting).
flux_patch_mtls_mode_yaml() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  if grep -q '^mtls_mode:' "$path" 2>/dev/null; then
    return 0
  fi
  printf '\nmtls_mode: "%s"\n' "$flux_mtls_mode" >> "$path"
  echo "patched mtls_mode into $path"
}

# Writes deploy/data/edge.yaml. Respects existing session_key unless force=1.
# Env/vars: BASE_DOMAIN, DOMAIN_SUFFIX, ACME_EMAIL, ACME_PRODUCTION, SESSION_KEY, FORCE_CONFIG
# Tunnel CA PEM: SSM engress-tunnel-ca-{cert,key}-pem (see deploy/scripts/tunnel-ca-ssm.sh).
flux_write_edge_config() {
  local force="${FORCE_CONFIG:-0}"
  local base="${BASE_DOMAIN:-}"
  local suffix="${DOMAIN_SUFFIX:-}"
  local acme_email="${ACME_EMAIL:-ops@example.com}"
  local acme_dir="https://acme-staging-v02.api.letsencrypt.org/directory"
  local session_key="${SESSION_KEY:-}"
  local control_origin="${ENGRESS_CONTROL_ORIGIN_HOST:-${FLUX_CONTROL_ORIGIN_HOST:-${CONTROL_ORIGIN_HOST:-}}}"

  mkdir -p "$flux_config_dir"

  if [[ -f "$flux_config_path" && "$force" -eq 0 ]]; then
    if [[ -z "$session_key" ]]; then
      session_key="$(grep '^session_key:' "$flux_config_path" | awk '{print $2}' | tr -d '"' || true)"
    fi
    if [[ -z "$base" ]]; then
      base="$(grep '^base_domain:' "$flux_config_path" | awk '{print $2}' | tr -d '"' || true)"
    fi
  fi

  if [[ -z "$base" ]]; then
    base="$(flux_detect_public_ip).sslip.io"
  fi
  if [[ -z "$suffix" ]]; then
    if [[ "$base" == *.sslip.io ]]; then
      suffix=".sslip.io"
    else
      suffix=".${base#*.}"
    fi
  fi
  if [[ "${ACME_PRODUCTION:-0}" == "1" ]]; then
    acme_dir="https://acme-v02.api.letsencrypt.org/directory"
  fi
  if [[ -z "$session_key" ]]; then
    session_key="$(openssl rand -base64 32)"
  fi
  if [[ -z "$control_origin" && -n "$base" ]]; then
    control_origin="edge-origin.${base}"
  fi

  cat > "$flux_config_path" <<EOF
http_addr: ":80"
https_addr: ":443"
tunnel_addr: ":4433"
domain_suffix: "${suffix}"
base_domain: "${base}"
control_origin_host: "${control_origin}"
control_api_url: "http://api:8080"
session_key: "${session_key}"
cert_cache_dir: "/data/certs"
mtls_mode: "${flux_mtls_mode}"
db:
  driver: sqlite
  dsn: "/data/engress.db"
acme:
  directory: "${acme_dir}"
  email: "${acme_email}"
EOF
  echo "wrote $flux_config_path (base_domain=$base domain_suffix=$suffix)"
}

# Writes deploy/data/api.yaml for engress-core (Neon/Clerk/tunnel CA from SSM on EC2).
flux_write_api_config() {
  local force="${FORCE_CONFIG:-0}"
  local base="${BASE_DOMAIN:-}"
  local suffix="${DOMAIN_SUFFIX:-}"
  local api_path="${ENGRESS_API_CONFIG_PATH:-${FLUX_API_CONFIG_PATH:-deploy/data/api.yaml}}"

  if [[ -f "$api_path" && "$force" -eq 0 ]]; then
    if [[ -z "$base" ]]; then
      base="$(grep '^base_domain:' "$api_path" | awk '{print $2}' | tr -d '"' || true)"
    fi
    if [[ -z "$suffix" ]]; then
      suffix="$(grep '^domain_suffix:' "$api_path" | awk '{print $2}' | tr -d '"' || true)"
    fi
    return 0
  fi

  if [[ -z "$base" && -f deploy/data/edge.yaml ]]; then
    base="$(grep '^base_domain:' deploy/data/edge.yaml | awk '{print $2}' | tr -d '"' || true)"
  fi
  if [[ -z "$base" ]]; then
    base="$(flux_detect_public_ip).sslip.io"
  fi
  if [[ -z "$suffix" ]]; then
    suffix="$(flux_derive_domain_suffix "$base")"
  fi

  mkdir -p "$(dirname "$api_path")"
  cat > "$api_path" <<EOF
listen_addr: ":8080"
base_domain: "${base}"
domain_suffix: "${suffix}"
cors_origin: "https://${base}"
db:
  driver: postgres
EOF
  echo "wrote $api_path (base_domain=$base)"
}

# Engress aliases (FLUX_* function names kept for deploy script compatibility).
engress_derive_domain_suffix() { flux_derive_domain_suffix "$@"; }
engress_resolve_edge_addr() { flux_resolve_edge_addr "$@"; }
engress_detect_public_ip() { flux_detect_public_ip "$@"; }
engress_resolve_control_origin_host() { flux_resolve_control_origin_host "$@"; }
engress_write_edge_config() { flux_write_edge_config "$@"; }
engress_write_api_config() { flux_write_api_config "$@"; }
engress_patch_mtls_mode_yaml() { flux_patch_mtls_mode_yaml "$@"; }

# Idempotent: create tunnel CA in SSM when missing (called from app-update / api-up).
flux_ensure_tunnel_ca_ssm() {
  local region="${1:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}}"
  local cert_param="engress-tunnel-ca-cert-pem"
  local key_param="engress-tunnel-ca-key-pem"

  if aws ssm get-parameter --name "$cert_param" --region "$region" >/dev/null 2>&1 \
    && aws ssm get-parameter --name "$key_param" --region "$region" >/dev/null 2>&1; then
    return 0
  fi

  command -v openssl >/dev/null 2>&1 || {
    echo "ERROR: openssl required to bootstrap tunnel CA in SSM" >&2
    return 1
  }

  local tmpdir cert key
  tmpdir="$(mktemp -d)"
  cert="$tmpdir/ca.crt"
  key="$tmpdir/ca.key"

  openssl ecparam -name prime256v1 -genkey -noout -out "$key"
  openssl req -new -x509 -key "$key" -out "$cert" -days 825 \
    -subj "/O=Engress/CN=Engress Tunnel CA" 2>/dev/null

  echo "==> creating SSM tunnel CA (${cert_param}, ${key_param})"
  aws ssm put-parameter --name "$cert_param" --type SecureString --value "file://$cert" \
    --overwrite --region "$region" >/dev/null
  aws ssm put-parameter --name "$key_param" --type SecureString --value "file://$key" \
    --overwrite --region "$region" >/dev/null
  rm -rf "$tmpdir"
  echo "==> tunnel CA stored in SSM (region=$region)"
}

engress_ensure_tunnel_ca_ssm() { flux_ensure_tunnel_ca_ssm "$@"; }
