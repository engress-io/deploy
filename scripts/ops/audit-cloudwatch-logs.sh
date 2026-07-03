#!/usr/bin/env bash
# audit-cloudwatch-logs.sh — CloudWatch log group size audit and EKS logging config.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-ghostweasel-flux}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"

echo "=== CloudWatch Log Groups by size (top 20) ==="
aws logs describe-log-groups \
  --query 'logGroups | sort_by(@, &storedBytes) | [-20:].{name:logGroupName,bytes:storedBytes,retention:retentionInDays}' \
  --output table

echo
echo "=== EKS cluster logging ==="
for cluster in engress-east engress-west engress-staging-east; do
  echo "--- ${cluster} ---"
  if aws eks describe-cluster --name "$cluster" \
    --query 'cluster.logging.clusterLogging' \
    --output json 2>/dev/null; then
    :
  else
    echo "skip ${cluster} (not found or no access)"
  fi
done

echo
echo "=== EKS log group retention (/aws/eks/*) ==="
aws logs describe-log-groups \
  --log-group-name-prefix /aws/eks/ \
  --query 'logGroups[].{name:logGroupName,bytes:storedBytes,retention:retentionInDays}' \
  --output table

echo
echo "=== Recommendations ==="
cat <<'EOF'
1. Set 7-day retention on all /aws/eks/* log groups:
     ./deploy/scripts/ops/cloudwatch-retention-eks.sh

2. Disable EKS control plane logs in Terraform (eks.tf, eks-west.tf):
     cluster_enabled_log_types = []
     cloudwatch_log_group_retention_in_days = 7
   Then plan/apply via dispatch-ops (stack=eks-east, eks-west).

3. If any log group shows retention=null, apply retention ≤ 7 days to cap storage cost.

4. Check VPC flow logs if large non-EKS groups appear:
     aws ec2 describe-flow-logs --query 'FlowLogs[].{id:FlowLogId,group:LogGroupName,status:FlowLogStatus}' --output table

5. Runtime visibility: use kubectl logs + Oasis; defer centralized log aggregation until needed.

Target: CloudWatch Logs ingestion + storage < $5/mo; budget alarm at $10/mo.
EOF