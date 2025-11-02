# AFFiNE Self-Hosted with Local AI

Self-hosted [AFFiNE](https://affine.pro) workspace with custom AI configuration using local LLMs via Ollama and LiteLLM. Extends the [original example compose file](https://github.com/toeverything/AFFiNE/blob/canary/.docker/selfhost/compose.yml) to have a up and running example of self hosted Affine with AI.

**Status:** Under development

## Overview

This setup enables AFFiNE to use local AI models (running on Ollama) by routing requests through LiteLLM, which acts as an OpenAI-compatible API proxy. AFFiNE makes requests using familiar OpenAI model names (like [`gpt-4o-mini`](config/config.json:12)), which LiteLLM translates to local Ollama models. Affine has a whitelists in the [providers/ files](https://github.com/toeverything/AFFiNE/blob/canary/packages/backend/server/src/plugins/copilot/providers/). Use this as alias names.

Even when using only whitelist names it tries nevertheless to contact the gemini2.5-flash model. Therefore I added model aliase in litellm config as well.

### Architecture

```
AFFiNE → LiteLLM Proxy → Ollama → Local Models
         (OpenAI API)    (Model Translation)
```

**Components:**
- **AFFiNE**: Self-hosted knowledge base and workspace (port 3010)
- **LiteLLM**: API proxy that translates OpenAI API calls to Ollama format (port 4000)
- **Ollama**: Local LLM runtime (port 11434)
- **PostgreSQL**: Database with pgvector extension
- **Redis**: Cache and session store

## Model Configuration

The setup uses lightweight CPU-friendly models optimized for local execution:

| Use Case | AFFiNE Alias | Actual Model | Size |
|----------|-------------|--------------|------|
| Chat & Text Generation | [`gpt-4o-mini`](config/config.json:12) | [`cas/llama-3.2-3b-instruct`](litellm/config.yaml:7) | 3B params |
| Code Generation | [`gpt-4.1-mini`](config/config.json:17) | [`ollama/codellama:7b-instruct`](litellm/config.yaml:12) | 7B params |
| Text Embeddings | [`text-embedding-3-small`](config/config.json:19) | [`ollama/snowflake-arctic-embed:latest`](litellm/config.yaml:24) | ~335M params |
| Images | [`unsplash-photo`](config/config.json:10) | Unsplash API | N/A |

**Configured Scenarios:**
- Complex text generation
- Quick text generation & decision making
- Polish and summarize
- Coding assistance
- Embedding & reranking

> **Note**: Audio transcription is currently disabled.

## Usage

### Start the Stack

```bash
docker-compose up -d
```

This will:
1. Pull and start all required containers
2. Download configured Ollama models (defined in [`.env`](.env:27))
3. Run database migrations
4. Start AFFiNE on http://localhost:3010

### Stop the Stack

```bash
docker-compose down
```

### Cleanup Persistent Data

To remove all data (database and uploaded files):

```bash
./cleanUp.sh
```

Or manually:
```bash
sudo rm -Rf postgres storage
```

> ⚠️ **Warning**: This will permanently delete all your workspaces, documents, and database!

## Configuration

### Environment Variables

Edit [`.env`](.env:1) to customize:
- [`PORT`](.env:5): AFFiNE web interface port (default: 3010)
- [`AFFINE_REVISION`](.env:2): Version to deploy (stable/beta/canary)
- [`OLLAMA_MODELS`](.env:27): Comma-separated list of models to download
- Database credentials and data locations

### AI Models

Edit [`litellm/config.yaml`](litellm/config.yaml:1) to change model mappings or add new models.

Edit [`config/config.json`](config/config.json:1) to modify which model aliases are used for specific scenarios.

## Troubleshooting

Check if all models are ready to be used from litellm
```
affine-selfhosted$ curl -s http://localhost:4000/v1/models | jq .
{
  "data": [
    {
      "id": "gpt-4o-mini",
      "object": "model",
      "created": 1677610602,
      "owned_by": "openai"
    },
    {
      "id": "gpt-4.1-mini",
      "object": "model",
      "created": 1677610602,
      "owned_by": "openai"
    },
    {
      "id": "gpt-4o",
      "object": "model",
      "created": 1677610602,
      "owned_by": "openai"
    },
    {
      "id": "text-embedding-3-small",
      "object": "model",
      "created": 1677610602,
      "owned_by": "openai"
    },
    {
      "id": "gemini-2.5-flash",
      "object": "model",
      "created": 1677610602,
      "owned_by": "openai"
    },
    {
      "id": "gemini-2.5-pro",
      "object": "model",
      "created": 1677610602,
      "owned_by": "openai"
    },
    {
      "id": "claude-sonnet-4-5@20250929",
      "object": "model",
      "created": 1677610602,
      "owned_by": "openai"
    }
  ],
  "object": "list"
}
```

Show the list of models in ollama docker:
```
affine-selfhosted$ docker exec -it $(docker ps --format "{{.ID}}" --filter "name=ollama-llm") ollama list
NAME                                     ID              SIZE      MODIFIED      
snowflake-arctic-embed:latest            21ab8b9b0545    669 MB    5 minutes ago    
mervinpraison/llama3.2-3B-instruct:8b    c3e2903407f0    6.4 GB    5 minutes ago    
codellama:7b-instruct                    8fdf8f752f6e    3.8 GB    5 minutes ago        
llama3.2:3b                              a80c4f17acd5    2.0 GB    17 hours ago     
nomic-embed-text:latest                  0a109f422b47    274 MB    45 hours ago
```



## References

- [Original AFFiNE self-hosted setup guide](https://github.com/toeverything/AFFiNE/issues/11691)
- [AI configuration discussion](https://github.com/toeverything/AFFiNE/discussions/11722#discussioncomment-13379127)


