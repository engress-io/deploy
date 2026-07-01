#!/usr/bin/env bash
# Non-interactive AWS CLI defaults for deploy scripts (no less pager on SSM output).
# AWS_PROFILE is set in workspace.sh (sourced by every script).
export AWS_PAGER="${AWS_PAGER:-}"
export PAGER="${PAGER:-cat}"
export AWS_CLI_AUTO_PROMPT=off

# aws_ssm_get_invocation REGION CMD_ID INSTANCE_ID [format: text|yaml]
aws_ssm_get_invocation() {
  local region="$1" cmd_id="$2" instance_id="$3" fmt="${4:-text}"
  aws --no-cli-pager ssm get-command-invocation \
    --region "$region" \
    --command-id "$cmd_id" \
    --instance-id "$instance_id" \
    --output "$fmt" \
    "$@"
}
