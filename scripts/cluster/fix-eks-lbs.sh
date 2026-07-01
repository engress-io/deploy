#!/usr/bin/env bash
# Fix EKS ALB/NLB provisioning: LBC IRSA via engress-core role, subnet tags, recycle ingress/svc.
set -euo pipefail

CLUSTER="${ENGRESS_DEPLOY_EKS_CLUSTER:-engress-east}"
REGION="${AWS_REGION:-us-east-2}"
ACCOUNT="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
LBC_NAMESPACE="${LBC_NAMESPACE:-engress}"
LBC_SERVICE_ACCOUNT="${LBC_SERVICE_ACCOUNT:-engress-core}"

# West edge-only clusters use engress-core-west IRSA for the LBC service account stub.
if [[ "$CLUSTER" == *west* || "$REGION" == "us-west-1" ]]; then
  CORE_ROLE_NAME="${ENGRESS_CORE_IAM_ROLE_NAME:-engress-core-west}"
else
  CORE_ROLE_NAME="${ENGRESS_CORE_IAM_ROLE_NAME:-engress-core}"
fi

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

echo "==> LBC IAM policy"
curl -sS -o /tmp/iam_policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/iam_policy.json \
  2>/dev/null || echo "  (policy already exists)"

echo "==> Attach LBC policy to ${CORE_ROLE_NAME} (reuse engress-core IRSA)"
if aws iam put-role-policy \
  --role-name "$CORE_ROLE_NAME" \
  --policy-name EngressLoadBalancerController \
  --policy-document file:///tmp/iam_policy.json 2>/dev/null; then
  echo "  inline LBC policy applied"
elif aws iam attach-role-policy \
  --role-name "$CORE_ROLE_NAME" \
  --policy-arn "arn:aws:iam::${ACCOUNT}:policy/AWSLoadBalancerControllerIAMPolicy" 2>/dev/null; then
  echo "  managed LBC policy attached"
else
  echo "WARN: could not attach LBC IAM policy (GHA role lacks iam:PutRolePolicy)" >&2
  echo "  Run: ./scripts/deploy/scripts/bootstrap-lbc-iam.sh  (needs AWS_PROFILE=ghostweasel-flux)" >&2
fi

kubectl create namespace "$LBC_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

ensure_lbc_service_account() {
  if kubectl get serviceaccount "$LBC_SERVICE_ACCOUNT" -n "$LBC_NAMESPACE" >/dev/null 2>&1; then
    return 0
  fi
  local irsa_arn=""
  if [[ "$CLUSTER" == *west* || "$REGION" == "us-west-1" ]]; then
    irsa_arn="$(aws ssm get-parameter --name engress-deploy-core-west-irsa-arn --region us-east-2 \
      --query 'Parameter.Value' --output text 2>/dev/null || true)"
  else
    irsa_arn="$(aws ssm get-parameter --name engress-deploy-core-irsa-arn --region us-east-2 \
      --query 'Parameter.Value' --output text 2>/dev/null || true)"
  fi
  if [[ -z "$irsa_arn" || "$irsa_arn" == "None" ]]; then
    echo "WARN: could not resolve IRSA for ${LBC_NAMESPACE}/${LBC_SERVICE_ACCOUNT}" >&2
    return 0
  fi
  echo "==> Create ${LBC_NAMESPACE}/${LBC_SERVICE_ACCOUNT} SA for LBC (edge-only west)"
  kubectl apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${LBC_SERVICE_ACCOUNT}
  namespace: ${LBC_NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: ${irsa_arn}
YAML
}

ensure_lbc_service_account

VPC_ID="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)"

echo "==> Cluster ${CLUSTER} VPC ${VPC_ID}"

echo "==> Tag subnets kubernetes.io/cluster/${CLUSTER}=shared"
if aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --region "$REGION" \
  --query 'Subnets[].[SubnetId,MapPublicIpOnLaunch]' --output text > /tmp/subnets.txt 2>/dev/null; then
  while read -r sid public; do
    [[ -z "$sid" ]] && continue
    aws ec2 create-tags --resources "$sid" --region "$REGION" \
      --tags "Key=kubernetes.io/cluster/${CLUSTER},Value=shared"
    if [[ "$public" == "True" ]]; then
      aws ec2 create-tags --resources "$sid" --region "$REGION" \
        --tags "Key=kubernetes.io/role/elb,Value=1"
    else
      aws ec2 create-tags --resources "$sid" --region "$REGION" \
        --tags "Key=kubernetes.io/role/internal-elb,Value=1"
    fi
    echo "  tagged ${sid} (public=${public})"
  done < /tmp/subnets.txt
else
  echo "  WARN: ec2:DescribeSubnets denied — relying on Terraform subnet tags"
fi

echo "==> IngressClass alb (Helm-managed)"
if kubectl get ingressclass alb >/dev/null 2>&1; then
  managed="$(kubectl get ingressclass alb -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  if [[ "$managed" != "Helm" ]]; then
    echo "  deleting orphan IngressClass alb (missing Helm ownership metadata)"
    kubectl delete ingressclass alb
  fi
fi

echo "==> AWS Load Balancer Controller (${LBC_NAMESPACE}/${LBC_SERVICE_ACCOUNT})"
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n "$LBC_NAMESPACE" \
  --set clusterName="$CLUSTER" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=false \
  --set serviceAccount.name="$LBC_SERVICE_ACCOUNT" \
  --set createIngressClassResource=true \
  --wait --timeout 5m

kubectl rollout status deployment/aws-load-balancer-controller -n "$LBC_NAMESPACE" --timeout=120s
kubectl rollout restart deployment/aws-load-balancer-controller -n "$LBC_NAMESPACE"
kubectl rollout status deployment/aws-load-balancer-controller -n "$LBC_NAMESPACE" --timeout=120s

if kubectl get namespace engress >/dev/null 2>&1; then
  echo "==> Recycle engress ingress + NLB (pick up subnet tags / chart fixes)"
  kubectl annotate ingress -n engress engress-core engress-edge \
    "alb.ingress.kubernetes.io/reconcile-trigger=$(date +%s)" --overwrite 2>/dev/null || true
  kubectl delete svc -n engress engress-edge-nlb --ignore-not-found
fi

echo "==> LBC recent logs"
kubectl logs -n "$LBC_NAMESPACE" deployment/aws-load-balancer-controller --tail=40 2>/dev/null || true

echo "==> Ingress / NLB status"
kubectl get ingress,svc -n engress 2>/dev/null || echo "(engress namespace not deployed yet)"
