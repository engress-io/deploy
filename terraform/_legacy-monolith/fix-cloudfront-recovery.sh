#!/usr/bin/env bash
# Recover CloudFront after partial destroy: import live distro OR two-phase create (no aliases → DNS → aliases).
set -euo pipefail

cd "$(dirname "$0")"

[[ -f terraform.tfvars ]] || { echo "ERROR: terraform.tfvars missing" >&2; exit 1; }

SPA_BUCKET="${ENGRESS_SPA_BUCKET:-flux-spa-327796148992}"
ADDR='aws_cloudfront_distribution.frontend[0]'

# Inline array — macOS ships Bash 3.2 (no mapfile).
RECOVERY_VARS=(
  -var-file=terraform.tfvars
  -var="enable_eks=true"
  -var="enable_frontend=true"
  -var="enable_control_instance=true"
  -var="decommission_ec2=true"
  -var="deploy_target=eks"
  -var="spa_bucket_name=${SPA_BUCKET}"
)

in_state() {
  terraform state show "$1" >/dev/null 2>&1
}

state_dist_id() {
  terraform state show -no-color "$ADDR" 2>/dev/null | awk '/^[[:space:]]+id[[:space:]]+=/{print $3}' | tr -d '"' | head -1
}

dist_exists() {
  local id="$1"
  [[ -n "$id" && "$id" != "None" ]] && aws cloudfront get-distribution --id "$id" >/dev/null 2>&1
}

find_alias_holder() {
  aws cloudfront list-distributions \
    --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, 'engress.io')].Id | [0]" \
    --output text 2>/dev/null || true
}

apply_recovery() {
  local skip_aliases="$1"
  local plan_out
  plan_out="$(mktemp)"
  terraform plan -input=false -out="$plan_out" "${RECOVERY_VARS[@]}" -var="skip_frontend_aliases=${skip_aliases}"
  if terraform show -no-color "$plan_out" | grep -qE "aws_s3_bucket\.frontend.*(must be replaced|will be destroyed)"; then
    echo "ERROR: plan would replace/destroy SPA bucket ${SPA_BUCKET}" >&2
    rm -f "$plan_out"
    exit 1
  fi
  terraform apply -input=false -auto-approve "$plan_out"
  rm -f "$plan_out"
}

echo "==> Terraform init"
terraform init -input=false

# Drop stale state when AWS object is gone.
if in_state "$ADDR"; then
  sid="$(state_dist_id)"
  if [[ -n "$sid" ]] && ! dist_exists "$sid"; then
    echo "==> Removing stale ${ADDR} from state (AWS id ${sid} gone)"
    terraform state rm "$ADDR"
  fi
fi

holder="$(find_alias_holder)"
if [[ -n "$holder" && "$holder" != "None" ]] && dist_exists "$holder"; then
  echo "==> Found live CloudFront ${holder} with engress.io alias"
  if ! in_state "$ADDR"; then
    echo "==> Importing ${ADDR} <- ${holder}"
    terraform import -input=false "${RECOVERY_VARS[@]}" "$ADDR" "$holder"
  fi
  echo "==> Apply (aliases enabled)"
  apply_recovery false
  exit 0
fi

echo "==> No live CloudFront owns engress.io — two-phase recovery"
echo "    (DNS likely still points at deleted d14hs2jxwtjmu2.cloudfront.net)"

echo "==> Phase 1: create CloudFront WITHOUT custom aliases"
apply_recovery true

NEW_CF="$(terraform output -raw cloudfront_domain)"
echo ""
echo "=============================================="
echo "UPDATE SPACESHIP DNS (required before phase 2)"
echo "=============================================="
echo "  @           ALIAS/CNAME -> ${NEW_CF}"
echo "  get         CNAME       -> ${NEW_CF}"
echo "  downloads   CNAME       -> ${NEW_CF}"
echo ""
if command -v dig >/dev/null 2>&1; then
  echo "Current engress.io DNS:"
  dig +short engress.io CNAME 2>/dev/null | sed 's/^/  CNAME: /' || true
  dig +short engress.io A 2>/dev/null | sed 's/^/  A: /' || true
  echo ""
fi

if [[ -t 0 && "${ENGRESS_SKIP_DNS_WAIT:-}" != "1" ]]; then
  read -r -p "Press Enter after DNS is updated (2-5 min TTL)... "
else
  wait="${ENGRESS_DNS_WAIT_SEC:-120}"
  echo "Waiting ${wait}s for DNS (${ENGRESS_SKIP_DNS_WAIT:-auto})..."
  sleep "$wait"
fi

echo "==> Phase 2: attach engress.io aliases + ACM cert"
apply_recovery false

echo "==> Verify:"
echo "  curl -sS https://engress.io/api/healthz"
echo "  curl -sS -o /dev/null -w '%{http_code}' https://engress.io/"
