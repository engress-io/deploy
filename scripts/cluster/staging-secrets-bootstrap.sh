#!/usr/bin/env bash
# Create staging Kubernetes secrets from SSM (run once after Terraform + SSM app secrets exist).
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_ROOT/scripts/lib/ssm-deploy-config.sh"

export ENGRESS_ENV=staging
AWS_REGION="${AWS_REGION:-us-east-2}"
NAMESPACE="${NAMESPACE:-engress}"
CLUSTER="${ENGRESS_DEPLOY_EKS_CLUSTER:-}"

_ssm_staging() {
  aws ssm get-parameter --name "$1" --region "$AWS_REGION" --with-decryption \
    --query 'Parameter.Value' --output text
}

: "${CLUSTER:?set ENGRESS_DEPLOY_EKS_CLUSTER or load staging SSM deploy config}"

aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

SESSION_KEY="${ENGRESS_STAGING_SESSION_KEY:-$(_ssm_staging engress-staging-session-key 2>/dev/null || true)}"
if [[ -z "$SESSION_KEY" ]]; then
  SESSION_KEY="$(openssl rand -base64 32)"
  aws ssm put-parameter --name engress-staging-session-key --type SecureString \
    --value "$SESSION_KEY" --overwrite --region "$AWS_REGION"
  echo "Created engress-staging-session-key in SSM"
fi

kubectl create secret generic engress-core-secrets-staging -n "$NAMESPACE" \
  --from-literal=FLUX_SESSION_KEY="$SESSION_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

METRICS_SECRET="${ENGRESS_STAGING_METRICS_SECRET:-$(_ssm_staging engress-staging-metrics-ingest-secret 2>/dev/null || true)}"
if [[ -z "$METRICS_SECRET" ]]; then
  METRICS_SECRET="$(openssl rand -hex 32)"
  aws ssm put-parameter --name engress-staging-metrics-ingest-secret --type SecureString \
    --value "$METRICS_SECRET" --overwrite --region "$AWS_REGION"
  echo "Created engress-staging-metrics-ingest-secret in SSM"
fi

CA_CERT="${ENGRESS_STAGING_TUNNEL_CA_CERT:-$(_ssm_staging engress-staging-tunnel-ca-cert-pem 2>/dev/null || true)}"
CA_KEY="${ENGRESS_STAGING_TUNNEL_CA_KEY:-$(_ssm_staging engress-staging-tunnel-ca-key-pem 2>/dev/null || true)}"
if [[ -z "$CA_CERT" || -z "$CA_KEY" ]]; then
  echo "ERROR: set engress-staging-tunnel-ca-cert-pem and engress-staging-tunnel-ca-key-pem in SSM first" >&2
  echo "  (copy prod CA for test tenants only, or mint a new staging CA)" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '%s' "$CA_CERT" > "$TMP/cert.pem"
printf '%s' "$CA_KEY" > "$TMP/key.pem"

kubectl create secret generic engress-edge-secrets-staging -n "$NAMESPACE" \
  --from-literal=FLUX_METRICS_INGEST_SECRET="$METRICS_SECRET" \
  --from-file=cert.pem="$TMP/cert.pem" \
  --from-file=key.pem="$TMP/key.pem" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Staging K8s secrets applied in namespace ${NAMESPACE} (cluster ${CLUSTER})"
