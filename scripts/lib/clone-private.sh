#!/usr/bin/env bash
# Clone or update the private Engress repo from GitHub (PAT in SSM).
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
export HOME="${HOME:-/root}"

AWS_REGION="${AWS_REGION:-${ENGRESS_AWS_REGION:-${FLUX_AWS_REGION:-us-east-2}}}"
GITHUB_BRANCH="${ENGRESS_GITHUB_BRANCH:-${FLUX_GITHUB_BRANCH:-main}}"
GITHUB_TOKEN_SSM="${ENGRESS_GITHUB_TOKEN_SSM:-${FLUX_GITHUB_TOKEN_SSM:-engress-github-read-token}}"
GITHUB_OWNER="${ENGRESS_GITHUB_OWNER:-${FLUX_GITHUB_OWNER:-engress-io}}"
GITHUB_REPO_NAME="${ENGRESS_GITHUB_REPO_NAME:-${FLUX_GITHUB_REPO_NAME:-core}}"
DEST="${1:-${ENGRESS_INSTALL_DIR:-${FLUX_INSTALL_DIR:-/opt/engress}}}"

if ! command -v aws >/dev/null; then
  echo "ERROR: aws CLI v2 required (see deploy/lib/host-setup.sh)" >&2
  exit 1
fi
if ! command -v git >/dev/null; then
  echo "ERROR: git required" >&2
  exit 1
fi

resolve_github_clone_url() {
  if [[ -n "${ENGRESS_GITHUB_REPO:-${FLUX_GITHUB_REPO:-}}" ]]; then
    echo "${ENGRESS_GITHUB_REPO:-${FLUX_GITHUB_REPO}}"
    return
  fi

  local tf_dir="${ENGRESS_TF_DIR:-${FLUX_TF_DIR:-}}"
  if [[ -z "$tf_dir" && -d "${DEST}/deploy/terraform" ]]; then
    tf_dir="${DEST}/deploy/terraform"
  fi
  if [[ -n "$tf_dir" && -d "$tf_dir" ]] && command -v terraform >/dev/null 2>&1; then
    local url
    url="$("${TF:-terraform}" -chdir="$tf_dir" output -raw github_clone_url 2>/dev/null || true)"
    if [[ -n "$url" ]]; then
      echo "$url"
      return
    fi
  fi

  echo "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO_NAME}.git"
}

github_read_token() {
  aws ssm get-parameter \
    --name "$GITHUB_TOKEN_SSM" \
    --with-decryption \
    --query Parameter.Value \
    --output text \
    --region "$AWS_REGION"
}

authenticated_clone_url() {
  local base="$1"
  local token
  token="$(github_read_token)"
  local path="${base#https://github.com/}"
  path="${path%.git}"
  echo "https://x-access-token:${token}@github.com/${path}.git"
}

git_with_auth() {
  local token
  token="$(github_read_token)"
  GIT_TERMINAL_PROMPT=0 \
    git -c "credential.helper=" \
        -c "credential.helper=!printf '%s\n' 'username=x-access-token' 'password=${token}'" \
        "$@"
}

GITHUB_REPO="$(resolve_github_clone_url)"
AUTH_URL="$(authenticated_clone_url "$GITHUB_REPO")"
PUBLIC_URL="$GITHUB_REPO"

if [[ -d "$DEST/.git" ]]; then
  git -C "$DEST" remote set-url origin "$PUBLIC_URL"
  git_with_auth -C "$DEST" fetch origin "$GITHUB_BRANCH"
  git -C "$DEST" checkout "$GITHUB_BRANCH"
  # Deploy servers: discard chmod/drift; never merge. deploy/data stays (untracked).
  git -C "$DEST" reset --hard "origin/$GITHUB_BRANCH"
  echo "Updated $DEST ($GITHUB_BRANCH)"
else
  mkdir -p "$(dirname "$DEST")"
  git clone --branch "$GITHUB_BRANCH" "$AUTH_URL" "$DEST"
  git -C "$DEST" remote set-url origin "$PUBLIC_URL"
  echo "Cloned $DEST ($GITHUB_BRANCH)"
fi
