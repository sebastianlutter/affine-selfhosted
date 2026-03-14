# AFFiNE Self-Hosted Behind Traefik

# Repository Moved

This project has moved from GitHub to **GitLab**.

Over time, GitHub has become slower and more bloated for my workflow, and since the Microsoft acquisition it no longer fits what I want from a hosting platform. Because of that, I’ve decided to stop using GitHub and continue all development on **gitlab.com** instead.

## Where to find this project now

The active repository lives here:  
**[https://gitlab.com/sebastian-lutter/traefik-public-gateway](https://gitlab.com/sebastian-lutter/affine-selfhosted)**

All future updates, issues, merge requests, and releases will happen there.

## What this means

- This GitHub repository is **archived / no longer maintained**
- No new features or fixes will be pushed here
- Please update your bookmarks, remotes, and CI links to point to GitLab

## Why GitLab?

- Faster and leaner for my use cases
- Better fit for my workflow
- I prefer having everything (issues, CI, registry, etc.) in one integrated platform

Thanks for following the project—and see you on GitLab


---


This repository runs an AFFiNE cloud instance on your server and publishes it through an already running Traefik gateway.

It is designed for this setup:

- Traefik is managed separately (see [traefik-public-gateway stack](https://gitlab.com/sebastian-lutter/traefik-public-gateway))
- Traefik has Docker provider enabled
- Both stacks share an external attachable network named `public-gateway`
- AFFiNE is exposed via your domain over HTTPS

## What You Get

- AFFiNE + PostgreSQL + Redis with persistent storage
- Optional AI stack for Copilot (local Ollama or remote provider via LiteLLM)
- Traefik labels already wired for domain routing and TLS
- Deployment script that validates network/runtime prerequisites

## Compose Modes

- `docker-compose.yml`: local AI mode (`caddy`, `affine_ai_helper`, `litellm`, `ollama-llm`)
- `docker-compose.remote-ai.yml`: remote AI mode (`caddy`, `affine_ai_helper`, `litellm`, no `ollama-llm`)
- `docker-compose.no-ai.yml`: no AI mode (`affine`, `postgres`, `redis`)
- `deployCompose.sh`: deploy helper for all modes (`--no-ai` and `--remote-ai`)
- `deployToServer.sh`: remote deploy helper (copies files via SSH/SCP, then runs `deployCompose.sh` on server)

## Architecture

Local AI mode (`docker-compose.yml`):

```text
Internet
  -> Traefik (public-gateway stack)
  -> affine:3010

AFFiNE Copilot calls
  -> caddy:80/v1
  -> /v1/responses* -> affine_ai_helper:4011 -> litellm:4000 -> ollama-llm:11434
  -> other /v1/*    -> litellm:4000 -> ollama-llm:11434
```

Remote AI mode (`docker-compose.remote-ai.yml`):

```text
Internet
  -> Traefik (public-gateway stack)
  -> affine:3010

AFFiNE Copilot calls
  -> caddy:80/v1
  -> /v1/responses* -> affine_ai_helper:4011 -> litellm:4000 -> remote model provider
  -> other /v1/*    -> litellm:4000 -> remote model provider
```

No AI mode (`docker-compose.no-ai.yml`):

```text
Internet -> Traefik -> affine:3010
```

## How `docker-compose.yml` Is Wired

Service roles:

- `affine`: main web/API service, routed publicly by Traefik
- `affine_migration`: one-shot migration job (`self-host-predeploy.js`) that must finish before `affine` starts
- `postgres`: persistent database (`pgvector/pgvector:pg16-trixie`)
- `redis`: cache/session/queue backend
- `caddy`: internal AI path router (`/v1`)
- `affine_ai_helper`: adapter for AFFiNE `/v1/responses*` behavior
- `litellm`: OpenAI-compatible gateway to models/providers
- `ollama-llm`: local model runtime (`gpus: all`)

`docker-compose.remote-ai.yml` is the same layout without `ollama-llm` (LiteLLM is expected to use remote providers).

Network model:

- Only `affine` joins both `default` and `public-gateway`
- All other services stay internal on `default`
- Public ingress is handled only by Traefik via labels on `affine`

Traefik labels on `affine`:

- `traefik.enable=true`
- `traefik.constraint-label=${TRAEFIK_CONSTRAINT_LABEL}`
- `traefik.docker.network=${TRAEFIK_PUBLIC_NETWORK}`
- router rule: `Host(${AFFINE_SERVER_HOST})`
- TLS resolver: `${TRAEFIK_CERT_RESOLVER}`
- internal service port: `3010`
- optional AFFiNE basic auth middleware from `${AFFINE_BASIC_AUTH_CREDENTIALS}`

## Expected Traefik Side (`public-gateway`)

`../public-gateway/docker-compose.traefik.yaml` shows the gateway assumptions:

- `providers.docker=true`
- `providers.swarm=true`
- both providers scoped to network `public-gateway`
- both providers constrained by `traefik.constraint-label=public-gateway`
- entrypoints on `:80` and `:443`
- ACME resolver `myresolver` (HTTP challenge)

If your Traefik does not match this model, AFFiNE labels may not be discovered.

## Prerequisites

- Linux server with Docker Engine + Docker Compose plugin
- Running Traefik gateway with the behavior above
- DNS `A/AAAA` record for your AFFiNE host pointing to the server
- Ports `80` and `443` reachable from the internet
- Docker access (the deploy script uses `docker run -i contentdev/jq:latest` for automatic AI config sync in `config/config.json`)

Local AI mode only:

- NVIDIA GPU runtime available to Docker (`gpus: all` in `ollama-llm`)

## Setup

1. Create `.env` from template:

```bash
cp _env_example .env
```

2. Set at least these variables in `.env`:

- `AFFINE_SERVER_HOST` (example: `affine.example.org`)
- `AFFINE_SERVER_EXTERNAL_URL` (example: `https://affine.example.org`)
- `AFFINE_BASIC_AUTH_USER`
- `AFFINE_BASIC_AUTH_PASSWORD`
- `DB_USERNAME`, `DB_PASSWORD`, `DB_DATABASE`
- `TRAEFIK_PUBLIC_NETWORK` (normally `public-gateway`)
- `TRAEFIK_CONSTRAINT_LABEL` (normally `public-gateway`)
- `TRAEFIK_CERT_RESOLVER` (normally `myresolver`)
- `SSH_SERVER` (SSH target for remote deploy, example: `user@host`)
- `DEPLOY_REMOTE_DIR` (remote folder, default: `affine-selfhosted`)

3. AI modes (`docker-compose.yml` and `docker-compose.remote-ai.yml`) only, also set:

- `LITELLM_MASTER_KEY` (required)
- `COPILOT_OPENAI_API_KEY` (optional, defaults to `LITELLM_MASTER_KEY`)
- `AFFINE_OPENAI_API_URL` (optional, defaults to `http://caddy:80/v1`)

4. Local AI mode (`docker-compose.yml`) only:

- `OLLAMA_MODELS` (optional preload list)

## Deploy

Local AI mode:

```bash
./deployCompose.sh
```

Remote AI mode:

```bash
./deployCompose.sh --remote-ai
```

No AI mode:

```bash
./deployCompose.sh --no-ai
```

What the script does:

- loads `.env`
- generates escaped Traefik basic-auth credentials from user/password using `httpd:2.4-alpine` (`docker run ... htpasswd`)
- selects compose file by mode (`docker-compose.yml`, `docker-compose.remote-ai.yml`, or `docker-compose.no-ai.yml`)
- in AI modes, syncs copilot OpenAI settings in `config/config.json`
- in no AI mode, disables copilot in `config/config.json`
- validates compose file
- ensures swarm is initialized (for overlay networking)
- ensures `TRAEFIK_PUBLIC_NETWORK` exists as an attachable overlay network
- starts the selected compose stack in background

### Remote Deploy (from workstation)

Local AI mode:

```bash
./deployToServer.sh
```

Remote AI mode:

```bash
./deployToServer.sh --remote-ai
```

No AI mode:

```bash
./deployToServer.sh --no-ai
```

What the script does:

- loads `.env` and reads `SSH_SERVER` / `DEPLOY_REMOTE_DIR`
- ensures the remote directory exists
- copies `.env`, compose files, and required project folders (`affine_ai_helper`, `config`, `litellm`, `llm`)
- runs `./deployCompose.sh` remotely with forwarded arguments

## Operations

Local AI mode commands:

```bash
docker compose -f docker-compose.yml --env-file .env ps
docker compose -f docker-compose.yml --env-file .env logs -f affine caddy affine_ai_helper litellm ollama-llm
docker compose -f docker-compose.yml --env-file .env down
```

Remote AI mode commands:

```bash
docker compose -f docker-compose.remote-ai.yml --env-file .env ps
docker compose -f docker-compose.remote-ai.yml --env-file .env logs -f affine caddy affine_ai_helper litellm
docker compose -f docker-compose.remote-ai.yml --env-file .env down
```

No AI mode commands:

```bash
docker compose -f docker-compose.no-ai.yml --env-file .env ps
docker compose -f docker-compose.no-ai.yml --env-file .env logs -f affine postgres redis
docker compose -f docker-compose.no-ai.yml --env-file .env down
```

## Persistence

Data lives in Docker named volumes:

- `affine_postgres_data`: PostgreSQL data
- `affine_storage`: AFFiNE uploads/storage
- `affine_config`: AFFiNE config (including `config.json`)
- `./ollama-downloads`: local model files (local AI mode only)

## Cleanup

`cleanUp.sh` removes local `postgres` and `storage` directories:

```bash
./cleanUp.sh
```

Use it only if you intentionally want to delete persisted data.

## Troubleshooting

Show rendered Traefik labels for `affine`:

```bash
docker compose -f docker-compose.yml --env-file .env config | sed -n '/affine:/,/^[^ ]/p'
```

Check shared network type and attachable flag:

```bash
docker network inspect public-gateway --format '{{.Driver}} {{.Attachable}}'
```

Expected output:

- `overlay true`
