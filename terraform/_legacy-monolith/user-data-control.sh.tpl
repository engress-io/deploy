#!/bin/bash
set -euo pipefail
exec > /var/log/flux-control-user-data.log 2>&1

echo "flux control user-data version=${user_data_version}"

source /dev/stdin <<'FLUX_HOST_SETUP'
${host_setup_script}
FLUX_HOST_SETUP
flux_setup_all "${swap_size_gb}"

AWS_REGION="${aws_region}"
GITHUB_REPO="${github_repo}"
GITHUB_BRANCH="${github_branch}"
SCRIPTS_REPO="${scripts_repo}"
SCRIPTS_BRANCH="${scripts_branch}"
APP_ROOT="/opt/engress"
CORE_DEST="$APP_ROOT/core"
SCRIPTS_DEST="$APP_ROOT/scripts"
LEGACY_DEST="/opt/flux"

install -m 0755 /dev/stdin /usr/local/bin/flux-clone-private.sh <<'FLUX_CLONE_PRIVATE'
${clone_private_script}
FLUX_CLONE_PRIVATE

mkdir -p "$APP_ROOT"
FLUX_GITHUB_REPO="$GITHUB_REPO" \
FLUX_GITHUB_BRANCH="$GITHUB_BRANCH" \
AWS_REGION="$AWS_REGION" \
/usr/local/bin/flux-clone-private.sh "$CORE_DEST"

FLUX_GITHUB_REPO="$SCRIPTS_REPO" \
FLUX_GITHUB_BRANCH="$SCRIPTS_BRANCH" \
AWS_REGION="$AWS_REGION" \
/usr/local/bin/flux-clone-private.sh "$SCRIPTS_DEST"

if [[ ! -e "$LEGACY_DEST" ]]; then
  ln -s "$CORE_DEST" "$LEGACY_DEST"
fi

export ENGRESS_CORE_ROOT="$CORE_DEST"
export ENGRESS_SCRIPTS_ROOT="$SCRIPTS_DEST"
export ENGRESS_TF_DIR="$CORE_DEST/deploy/terraform"

cd "$CORE_DEST"
chmod +x "$SCRIPTS_DEST"/deploy/scripts/*.sh "$SCRIPTS_DEST"/deploy/lib/*.sh 2>/dev/null || true

export FLUX_USE_ECR=1
export FLUX_API_IMAGE="${ecr_api_image}"
export FLUX_BASE_DOMAIN="${base_domain}"
export FLUX_DOMAIN_SUFFIX="${domain_suffix}"
export FLUX_CORS_ORIGIN="https://${base_domain}"
export FLUX_EDGE_INSTANCE_ID="${edge_instance_id}"
export AWS_REGION="${aws_region}"

echo "[control user-data] starting engress-core"
"$SCRIPTS_DEST/deploy/scripts/control-bootstrap.sh"

echo "[control user-data] complete"
docker compose -f deploy/docker-compose.control.ecr.yml ps || true
