#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

usage() {
  cat <<'EOF'
Usage: ./deployCompose.sh [--no-ai]

Options:
  --no-ai   Deploy using docker-compose.no-ai.yml and skip AI configuration.
  -h, --help  Show this help message.
EOF
}

USE_NO_AI=false
COMPOSE_FILE="docker-compose.yml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-ai)
      USE_NO_AI=true
      COMPOSE_FILE="docker-compose.no-ai.yml"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument '$1'." >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found at ${SCRIPT_DIR}/.env" >&2
  exit 1
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "ERROR: ${COMPOSE_FILE} not found at ${SCRIPT_DIR}/${COMPOSE_FILE}" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source ./.env
set +a

TRAEFIK_PUBLIC_NETWORK="${TRAEFIK_PUBLIC_NETWORK:-public-gateway}"
CONFIG_LOCATION="${CONFIG_LOCATION:-./config}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not available in PATH." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose plugin is not available." >&2
  exit 1
fi

if [[ -z "${AFFINE_BASIC_AUTH_USER:-}" || -z "${AFFINE_BASIC_AUTH_PASSWORD:-}" ]]; then
  echo "ERROR: Set AFFINE_BASIC_AUTH_USER and AFFINE_BASIC_AUTH_PASSWORD in .env." >&2
  exit 1
fi

HTPASSWD_DOCKER_IMAGE="${HTPASSWD_DOCKER_IMAGE:-httpd:2.4-alpine}"
JQ_DOCKER_IMAGE="${JQ_DOCKER_IMAGE:-stedolan/jq}"

generate_basic_auth_credentials() {
  local raw

  if raw="$(docker run --rm --entrypoint /usr/local/apache2/bin/htpasswd "${HTPASSWD_DOCKER_IMAGE}" \
      -nbB "${AFFINE_BASIC_AUTH_USER}" "${AFFINE_BASIC_AUTH_PASSWORD}" 2>/dev/null)"; then
    printf '%s' "${raw}" | sed -e 's/\\$/\\$\\$/g'
    return 0
  fi

  if raw="$(docker run --rm --entrypoint /usr/bin/htpasswd "${HTPASSWD_DOCKER_IMAGE}" \
      -nbB "${AFFINE_BASIC_AUTH_USER}" "${AFFINE_BASIC_AUTH_PASSWORD}" 2>/dev/null)"; then
    printf '%s' "${raw}" | sed -e 's/\\$/\\$\\$/g'
    return 0
  fi

  return 1
}

run_jq() {
  docker run --rm -i "${JQ_DOCKER_IMAGE}" "$@"
}

if ! AFFINE_BASIC_AUTH_CREDENTIALS="$(generate_basic_auth_credentials)"; then
  echo "ERROR: Failed to generate Traefik basic auth credentials using Docker image ${HTPASSWD_DOCKER_IMAGE}." >&2
  echo "Ensure Docker can pull/run this image and that it contains the htpasswd binary." >&2
  exit 1
fi
export AFFINE_BASIC_AUTH_CREDENTIALS

AFFINE_CONFIG_FILE="${CONFIG_LOCATION}/config.json"
if [[ "${USE_NO_AI}" == "false" ]]; then
  if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
    echo "ERROR: LITELLM_MASTER_KEY is empty." >&2
    exit 1
  fi

  export LITELLM_MASTER_KEY

  COPILOT_OPENAI_API_KEY="${COPILOT_OPENAI_API_KEY:-${LITELLM_MASTER_KEY}}"
  export COPILOT_OPENAI_API_KEY

  if [[ -z "${AFFINE_OPENAI_API_URL:-}" ]]; then
    AFFINE_OPENAI_API_URL="http://caddy:80/v1"
  fi
  export AFFINE_OPENAI_API_URL

  if [[ -f "${AFFINE_CONFIG_FILE}" ]]; then
    TMP_CONFIG="$(mktemp)"
    if ! run_jq --arg key "${COPILOT_OPENAI_API_KEY}" --arg url "${AFFINE_OPENAI_API_URL}" \
      '.copilot.enabled = true
      | .copilot["providers.openai"].apiKey = $key
      | .copilot["providers.openai"].baseURL = $url' \
      < "${AFFINE_CONFIG_FILE}" > "${TMP_CONFIG}"; then
      rm -f "${TMP_CONFIG}"
      echo "ERROR: Failed to update ${AFFINE_CONFIG_FILE} via Docker image ${JQ_DOCKER_IMAGE}." >&2
      exit 1
    fi
    mv "${TMP_CONFIG}" "${AFFINE_CONFIG_FILE}"
    echo "Synced ${AFFINE_CONFIG_FILE} OpenAI copilot settings."
  fi
else
  if [[ -f "${AFFINE_CONFIG_FILE}" ]]; then
    TMP_CONFIG="$(mktemp)"
    if run_jq '.copilot.enabled = false' < "${AFFINE_CONFIG_FILE}" > "${TMP_CONFIG}"; then
      mv "${TMP_CONFIG}" "${AFFINE_CONFIG_FILE}"
      echo "Disabled copilot in ${AFFINE_CONFIG_FILE} (--no-ai)."
    else
      rm -f "${TMP_CONFIG}"
      echo "WARN: Failed to update ${AFFINE_CONFIG_FILE} via Docker image ${JQ_DOCKER_IMAGE}; skipping copilot disable step." >&2
    fi
  fi
fi

SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
if [[ -z "${SWARM_STATE}" || "${SWARM_STATE}" == "inactive" ]]; then
  echo "Initializing docker swarm for overlay network support..."
  docker swarm init >/dev/null
fi

if ! docker network inspect "${TRAEFIK_PUBLIC_NETWORK}" >/dev/null 2>&1; then
  echo "Creating attachable overlay network '${TRAEFIK_PUBLIC_NETWORK}'..."
  docker network create --driver overlay --attachable "${TRAEFIK_PUBLIC_NETWORK}" >/dev/null
else
  DRIVER="$(docker network inspect -f '{{.Driver}}' "${TRAEFIK_PUBLIC_NETWORK}")"
  ATTACHABLE="$(docker network inspect -f '{{.Attachable}}' "${TRAEFIK_PUBLIC_NETWORK}")"

  if [[ "${DRIVER}" != "overlay" ]]; then
    echo "ERROR: network '${TRAEFIK_PUBLIC_NETWORK}' exists but uses driver '${DRIVER}', expected 'overlay'." >&2
    exit 1
  fi

  if [[ "${ATTACHABLE}" != "true" ]]; then
    echo "ERROR: network '${TRAEFIK_PUBLIC_NETWORK}' exists but is not attachable." >&2
    echo "Recreate it with '--attachable' so regular compose containers can join it." >&2
    exit 1
  fi
fi

echo "Using compose file: ${COMPOSE_FILE}"

echo "Validating compose config..."
docker compose -f "${COMPOSE_FILE}" --env-file .env config >/dev/null

echo "Starting compose stack in background..."
docker compose -f "${COMPOSE_FILE}" --env-file .env up -d

echo "Service status:"
docker compose -f "${COMPOSE_FILE}" --env-file .env ps
