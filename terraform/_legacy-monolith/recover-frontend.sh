#!/usr/bin/env bash
# Recover engress.io CloudFront/SPA after a bad decommission apply.
set -euo pipefail

cd "$(dirname "$0")"

ensure_tfvars() {
  local dest="terraform.tfvars"
  local aws_region="${AWS_REGION:-us-east-2}"

  if [[ -f "$dest" ]] && grep -qE '^\s*admin_email\s*=' "$dest" && grep -qE '^\s*elastic_ip_address\s*=' "$dest"; then
    echo "Using existing $dest"
    return 0
  fi

  if command -v aws >/dev/null 2>&1; then
    if aws ssm get-parameter --name engress-terraform-tfvars --with-decryption --region "$aws_region" \
      --query 'Parameter.Value' --output text >"$dest" 2>/dev/null; then
      echo "Using terraform.tfvars from SSM engress-terraform-tfvars"
      return 0
    fi
  fi

  export ENGRESS_ADMIN_EMAIL="${ENGRESS_ADMIN_EMAIL:-walter@ghostweasel.net}"

  cat >"$dest" <<EOF
aws_region              = "${aws_region}"
admin_email             = "${ENGRESS_ADMIN_EMAIL}"
operator_cidr           = "${ENGRESS_OPERATOR_CIDR:-0.0.0.0/0}"
elastic_ip_address      = "${ENGRESS_ELASTIC_IP:-18.216.236.251}"
name_prefix             = "engress"
base_domain             = "engress.io"
domain_suffix           = ".edge.engress.io"
enable_control_instance = true
control_origin_hostname = "core-origin.engress.io"
enable_frontend         = true
enable_eks              = true
decommission_ec2        = true
deploy_target           = "eks"
spa_bucket_name         = "flux-spa-327796148992"
amplify_domain          = "main.dftigsyg375wb.amplifyapp.com"
EOF
  echo "Wrote minimal production $dest"
}

ensure_tfvars
exec ./fix-cloudfront-recovery.sh
