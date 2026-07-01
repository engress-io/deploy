#!/usr/bin/env bash
# Send a local script to EC2 via SSM (base64 pipe — no /opt/flux checkout required on instance).
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSM_ENV_SCRIPT="$LIB_DIR/ssm-remote-env.sh"

# run_ssm_bash_script REGION INSTANCE_ID SCRIPT_PATH [ENV=VALUE ...]
run_ssm_bash_script() {
  local region="$1" instance_id="$2" script_path="$3"
  shift 3

  if [[ ! -f "$script_path" ]]; then
    echo "missing script: $script_path" >&2
    return 1
  fi
  if [[ ! -f "$SSM_ENV_SCRIPT" ]]; then
    echo "missing ssm env: $SSM_ENV_SCRIPT" >&2
    return 1
  fi

  local b64 env_prefix="" cmd_id
  b64="$(cat "$SSM_ENV_SCRIPT" "$script_path" | base64 | tr -d '\n')"

  for kv in "$@"; do
    env_prefix+="${kv} "
  done

  local remote_cmd="echo '${b64}' | base64 -d | ${env_prefix}bash"

  cmd_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --parameters "$(python3 -c "import json,sys; print(json.dumps({'commands': [sys.argv[1]]}))" "$remote_cmd")" \
    --query Command.CommandId \
    --output text)"

  echo "$cmd_id"
}
