#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found at ${SCRIPT_DIR}/.env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source ./.env
set +a

TRAEFIK_PUBLIC_NETWORK="${TRAEFIK_PUBLIC_NETWORK:-public-gateway}"
CONFIG_LOCATION="${CONFIG_LOCATION:-./config}"

if ! command -v htpasswd >/dev/null 2>&1; then
  echo "ERROR: htpasswd is required to generate Traefik basic auth credentials." >&2
  exit 1
fi

if [[ -z "${AFFINE_BASIC_AUTH_USER:-}" || -z "${AFFINE_BASIC_AUTH_PASSWORD:-}" ]]; then
  echo "ERROR: Set AFFINE_BASIC_AUTH_USER and AFFINE_BASIC_AUTH_PASSWORD in .env." >&2
  exit 1
fi

AFFINE_BASIC_AUTH_CREDENTIALS="$(
  htpasswd -nbB "${AFFINE_BASIC_AUTH_USER}" "${AFFINE_BASIC_AUTH_PASSWORD}" \
  | sed 's/\$/$$/g'
)"
export AFFINE_BASIC_AUTH_CREDENTIALS

if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is required to generate LITELLM_MASTER_KEY." >&2
    exit 1
  fi
  LITELLM_MASTER_KEY="sk-local-$(openssl rand -hex 24)"
  export LITELLM_MASTER_KEY
  echo "Generated missing LITELLM_MASTER_KEY."
  echo "Persisting LITELLM_MASTER_KEY to .env for stable restarts..."
  printf '\nLITELLM_MASTER_KEY=%s\n' "${LITELLM_MASTER_KEY}" >> .env
fi

if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
  echo "ERROR: LITELLM_MASTER_KEY is empty." >&2
  exit 1
fi

export LITELLM_MASTER_KEY

COPILOT_OPENAI_API_KEY="${COPILOT_OPENAI_API_KEY:-${LITELLM_MASTER_KEY}}"
export COPILOT_OPENAI_API_KEY

if [[ -z "${AFFINE_OPENAI_API_URL:-}" ]]; then
  if [[ -z "${AFFINE_LLM_DOMAIN:-}" ]]; then
    echo "ERROR: Set AFFINE_OPENAI_API_URL or AFFINE_LLM_DOMAIN in .env." >&2
    exit 1
  fi
  AFFINE_OPENAI_API_URL="https://${AFFINE_LLM_DOMAIN}/v1"
fi
export AFFINE_OPENAI_API_URL

AFFINE_CONFIG_FILE="${CONFIG_LOCATION}/config.json"
if [[ -f "${AFFINE_CONFIG_FILE}" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required to set ${AFFINE_CONFIG_FILE} copilot apiKey." >&2
    exit 1
  fi
  TMP_CONFIG="$(mktemp)"
  jq --arg key "${COPILOT_OPENAI_API_KEY}" --arg url "${AFFINE_OPENAI_API_URL}" \
    '.copilot.enabled = true
    | .copilot["providers.openai"].apiKey = $key
    | .copilot["providers.openai"].baseURL = $url' \
    "${AFFINE_CONFIG_FILE}" > "${TMP_CONFIG}"
  mv "${TMP_CONFIG}" "${AFFINE_CONFIG_FILE}"
  echo "Synced ${AFFINE_CONFIG_FILE} OpenAI copilot settings."
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not available in PATH." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose plugin is not available." >&2
  exit 1
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

echo "Validating compose config..."
docker compose --env-file .env config >/dev/null

echo "Starting compose stack in background..."
docker compose --env-file .env up -d

echo "Service status:"
docker compose --env-file .env ps
