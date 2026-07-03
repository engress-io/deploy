#!/usr/bin/env bash
# Ensure core/deploy/terraform/terraform.tfvars exists with required production values.

engress_ensure_terraform_tfvars() {
  local dest="${1:-terraform.tfvars}"
  local aws_region="${AWS_REGION:-us-east-2}"

  if [[ -f "$dest" ]] && grep -qE '^\s*admin_email\s*=' "$dest"; then
    if [[ "${ENGRESS_ENV:-prod}" == "staging" ]] && grep -qE 'environment\s*=\s*"staging"' "$dest"; then
      echo "Using existing staging $dest"
      return 0
    fi
    if [[ "${ENGRESS_ENV:-prod}" != "staging" ]] && grep -qE '^\s*elastic_ip_address\s*=' "$dest"; then
      echo "Using existing $dest"
      return 0
    fi
  fi

  if [[ -n "${TERRAFORM_TFVARS_FILE:-}" && -f "$TERRAFORM_TFVARS_FILE" ]]; then
    cp "$TERRAFORM_TFVARS_FILE" "$dest"
    echo "Copied TERRAFORM_TFVARS_FILE -> $dest"
    return 0
  fi

  if command -v aws >/dev/null 2>&1; then
    local ssm_name="engress-terraform-tfvars"
    if [[ "${ENGRESS_ENV:-prod}" == "staging" ]]; then
      ssm_name="engress-terraform-tfvars-staging"
    fi
    if aws ssm get-parameter --name "$ssm_name" --with-decryption --region "$aws_region" \
      --query 'Parameter.Value' --output text >"$dest" 2>/dev/null; then
      echo "Using terraform.tfvars from SSM $ssm_name"
      return 0
    fi
  fi

  : "${ENGRESS_ADMIN_EMAIL:?set ENGRESS_ADMIN_EMAIL or create terraform.tfvars with admin_email}"

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
enable_eks                  = true
enable_eks_west             = true
enable_global_accelerator   = true
decommission_ec2            = true
deploy_target               = "eks"
spa_bucket_name         = "flux-spa-327796148992"
amplify_domain          = "main.dftigsyg375wb.amplifyapp.com"
EOF
  echo "Wrote minimal production $dest (set ENGRESS_ADMIN_EMAIL to override admin_email)"
}
