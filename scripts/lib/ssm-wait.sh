#!/usr/bin/env bash
# Poll SSM Run Command until Success, failure, or timeout.
# Usage: wait_ssm_command REGION COMMAND_ID INSTANCE_ID [MAX_ATTEMPTS] [SLEEP_SEC]
wait_ssm_command() {
  local region="$1" cmd_id="$2" instance_id="$3"
  local max_attempts="${4:-120}" sleep_sec="${5:-5}"
  local i status out err

  echo "Waiting for SSM command (up to $((max_attempts * sleep_sec))s, poll every ${sleep_sec}s)..."
  for ((i = 1; i <= max_attempts; i++)); do
    status="$(aws --no-cli-pager ssm get-command-invocation \
      --region "$region" \
      --command-id "$cmd_id" \
      --instance-id "$instance_id" \
      --query Status \
      --output text 2>/dev/null || echo Pending)"
    printf "  %s attempt %d/%d status=%s\r" "$(date +%H:%M:%S)" "$i" "$max_attempts" "$status"
    case "$status" in
      Success)
        echo
        out="$(aws --no-cli-pager ssm get-command-invocation \
          --region "$region" \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --query StandardOutputContent \
          --output text 2>/dev/null || true)"
        err="$(aws --no-cli-pager ssm get-command-invocation \
          --region "$region" \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --query StandardErrorContent \
          --output text 2>/dev/null || true)"
        [[ -n "$out" ]] && printf '%s\n' "$out"
        [[ -n "$err" ]] && printf '%s\n' "$err" >&2
        return 0
        ;;
      Failed|Cancelled|TimedOut|Cancelling)
        echo
        echo "--- SSM command failed (status=$status) ---"
        out="$(aws --no-cli-pager ssm get-command-invocation \
          --region "$region" \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --query StandardOutputContent \
          --output text 2>/dev/null || true)"
        err="$(aws --no-cli-pager ssm get-command-invocation \
          --region "$region" \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --query StandardErrorContent \
          --output text 2>/dev/null || true)"
        [[ -n "$out" ]] && printf '%s\n' "$out"
        [[ -n "$err" ]] && printf '%s\n' "$err" >&2
        return 1
        ;;
    esac
    sleep "$sleep_sec"
  done
  echo
  echo "Timed out waiting for SSM command $cmd_id (last status=$status)" >&2
  echo "Check output: aws --no-cli-pager ssm get-command-invocation --region $region --command-id $cmd_id --instance-id $instance_id" >&2
  return 1
}
