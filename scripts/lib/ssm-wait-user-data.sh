#!/usr/bin/env bash
# Wait until EC2 user-data bootstrap finished (or the Engress checkout exists).
wait_user_data_ready() {
  local region="$1" instance_id="$2"
  local max_attempts="${3:-90}" sleep_sec="${4:-10}"
  local i status out cmd_id

  echo "Waiting for user-data bootstrap (up to $((max_attempts * sleep_sec))s)..."
  for ((i = 1; i <= max_attempts; i++)); do
    cmd_id="$(aws ssm send-command \
      --region "$region" \
      --instance-ids "$instance_id" \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["export PATH=/usr/local/bin:/usr/bin:/bin; if [ -f /var/log/flux-user-data.log ] && grep -q \"flux terraform user-data complete\" /var/log/flux-user-data.log; then echo ready-user-data; elif [ -d /opt/engress/core/.git ]; then echo ready-checkout; elif [ -d /opt/flux/.git ]; then echo ready-legacy-checkout; elif [ -x /usr/local/bin/aws ] && [ -d /opt/korg/.git ]; then echo ready-korg; else echo pending; tail -n 2 /var/log/flux-user-data.log 2>/dev/null || true; fi"]' \
      --query Command.CommandId \
      --output text)"

    sleep 5
    out="$(aws --no-cli-pager ssm get-command-invocation \
      --region "$region" \
      --command-id "$cmd_id" \
      --instance-id "$instance_id" \
      --query StandardOutputContent \
      --output text 2>/dev/null || true)"
    status="$(aws --no-cli-pager ssm get-command-invocation \
      --region "$region" \
      --command-id "$cmd_id" \
      --instance-id "$instance_id" \
      --query Status \
      --output text 2>/dev/null || echo Pending)"

    if [[ "$status" == "Success" ]] && [[ "$out" == ready-* ]]; then
      echo "  $(date +%H:%M:%S) $out"
      echo "Host bootstrap ready"
      return 0
    fi
    printf "  %s attempt %d/%d pending\r" "$(date +%H:%M:%S)" "$i" "$max_attempts"
    sleep "$sleep_sec"
  done
  echo
  echo "Timed out waiting for user-data — app-update will install deps if needed" >&2
  return 1
}
