#!/usr/bin/env bash
# cloudwatch-retention-eks.sh — set 7-day retention on all /aws/eks/* CloudWatch log groups.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-ghostweasel-flux}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"

RETENTION_DAYS="${RETENTION_DAYS:-7}"

echo "=== Setting ${RETENTION_DAYS}-day retention on /aws/eks/* log groups ==="
echo "profile=${AWS_PROFILE} region=${AWS_DEFAULT_REGION}"

count=0
for lg in $(aws logs describe-log-groups \
  --log-group-name-prefix /aws/eks/ \
  --query 'logGroups[].logGroupName' \
  --output text); do
  [[ -z "$lg" ]] && continue
  aws logs put-retention-policy \
    --log-group-name "$lg" \
    --retention-in-days "$RETENTION_DAYS"
  echo "retention ${RETENTION_DAYS}d: ${lg}"
  count=$((count + 1))
done

if [[ "$count" -eq 0 ]]; then
  echo "No /aws/eks/* log groups found."
else
  echo "Done. Updated ${count} log group(s)."
fi