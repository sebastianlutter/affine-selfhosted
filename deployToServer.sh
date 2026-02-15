#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

usage() {
  cat <<'EOF'
Usage: ./deployToServer.sh [deployCompose.sh args]

Examples:
  ./deployToServer.sh
  ./deployToServer.sh --no-ai
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found at ${SCRIPT_DIR}/.env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source ./.env
set +a

if [[ -z "${SSH_SERVER:-}" ]]; then
  echo "ERROR: SSH_SERVER is not set in .env." >&2
  exit 1
fi

REMOTE_DIR="${DEPLOY_REMOTE_DIR:-affine-selfhosted}"

FILES_TO_COPY=(
  ".env"
  "deployCompose.sh"
  "docker-compose.yml"
  "docker-compose.no-ai.yml"
  "affine_ai_helper"
  "config"
  "litellm"
  "llm"
)

for file in "${FILES_TO_COPY[@]}"; do
  if [[ ! -e "${file}" ]]; then
    echo "ERROR: Required path not found: ${SCRIPT_DIR}/${file}" >&2
    exit 1
  fi
done

echo "Ensuring remote directory exists: ${REMOTE_DIR}"
ssh "${SSH_SERVER}" "mkdir -p \"${REMOTE_DIR}\""

echo "Copying deployment files to ${SSH_SERVER}:${REMOTE_DIR}/"
scp -rp "${FILES_TO_COPY[@]}" "${SSH_SERVER}:${REMOTE_DIR}/"

REMOTE_CMD="cd $(printf '%q' "${REMOTE_DIR}") && chmod +x deployCompose.sh && ./deployCompose.sh"
for arg in "$@"; do
  REMOTE_CMD+=" $(printf '%q' "${arg}")"
done

echo "Running remote deployment: ${REMOTE_CMD}"
ssh "${SSH_SERVER}" "${REMOTE_CMD}"
