#!/usr/bin/env bash
# Install AWS Load Balancer Controller + metrics-server on EKS (one-time per cluster).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/deploy/lib/workspace.sh"
engress_export_workspace
# shellcheck source=/dev/null
source "$ROOT/deploy/lib/ssm-deploy-config.sh"

AWS_REGION="${AWS_REGION:-us-east-2}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
CLUSTER_NAME="${CLUSTER_NAME:-${ENGRESS_DEPLOY_EKS_CLUSTER:-engress-east}}"

install_eksctl() {
  if command -v eksctl >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing eksctl..."
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) EKSCTL_ARCH=amd64 ;;
    aarch64|arm64) EKSCTL_ARCH=arm64 ;;
    *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
  esac
  curl -sSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_${EKSCTL_ARCH}.tar.gz" \
    | tar xz -C /tmp
  sudo install -m 0755 /tmp/eksctl /usr/local/bin/eksctl
}

echo "=== Cluster: ${CLUSTER_NAME} (${AWS_REGION}) ==="
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

install_eksctl

echo "=== AWS Load Balancer Controller IAM ==="
curl -sS -o /tmp/iam_policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/iam_policy.json \
  2>/dev/null || echo "LBC policy already exists"

eksctl create iamserviceaccount \
  --cluster="$CLUSTER_NAME" \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" \
  --override-existing-serviceaccounts \
  --approve \
  --region="$AWS_REGION"

echo "=== Helm: AWS Load Balancer Controller ==="
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait --timeout 5m

echo "=== metrics-server ==="
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s

kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get deployment -n kube-system metrics-server
echo "=== Cluster add-ons ready ==="
