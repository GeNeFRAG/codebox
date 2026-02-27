# OpenCode Web — Docker

Persistent AI coding agent running in Docker with a browser-based web interface. Each repo gets its own isolated container with dedicated data volumes, MCP servers, and port.

## Overview

- **Web UI**: Browser-based coding agent at `http://localhost:3000`
- **Models**: Claude (Sonnet/Opus/Haiku 4.x), GPT-5/4.1/4o, o3/o4, Mistral, Llama
- **Providers**: Any OpenAI-compatible API, OpenRouter
- **MCP Integrations**: memory, web search, sequential thinking, time (enabled by default); GitHub, Jira, Confluence, Grafana, browser automation (available, disabled by default)
- **Multi-repo**: Run parallel instances on different ports for different projects
- **Runtime**: Node 22 (Bookworm Slim), Bun, Docker CLI, ripgrep, git

## Quick Start

```bash
# 1. Clone the repo
git clone <repo-url> && cd opencode-docker

# 2. Copy environment template and edit
cp .env.example .env
vim .env          # Set LLM_BASE_URL, LLM_API_KEY, OPENCODE_MODEL at minimum

# 3. (Optional) Add CA certificate for corporate proxies
# cp /path/to/your/ca-bundle.pem ./ca-bundle.pem
# Set CA_CERT_PATH in .env

# 4. Start
./opencode-web.sh start

# 5. Open browser
# Default port 3000 (set OPENCODE_PORT in .env to change)
open http://localhost:3000
```

## Project Structure

```
.
├── Dockerfile                          # Multi-stage build (builder → runtime)
├── docker-compose.yml                  # Base service definition + shared config
├── docker-compose.override.yml.example # Template for adding your own repos
├── docker-compose.override.yml         # Your personal repo services (gitignored)
├── .env.example                        # Environment variable template
├── .env                                # Your secrets and config (gitignored)
├── entrypoint.sh                       # Container startup script
├── opencode-web.sh                     # Host-side CLI wrapper
├── opencode.json.template              # OpenCode config template (envsubst)
├── prefill-proxy.mjs                   # LLM proxy (strips assistant prefill)
├── ca-bundle.pem                       # CA certificate bundle (gitignored)
└── .gitignore
```

## CLI Wrapper (`opencode-web.sh`)

Convenience script for managing services from the host. Automatically includes `docker-compose.override.yml` if present.

```bash
./opencode-web.sh start                   # Build and start all services
./opencode-web.sh start opencode-docker   # Start only one service
./opencode-web.sh stop                    # Stop all
./opencode-web.sh stop my-project         # Stop one service
./opencode-web.sh restart                 # Restart all
./opencode-web.sh logs opencode-docker    # Follow logs for a service
./opencode-web.sh shell opencode-docker   # Bash into a running container
./opencode-web.sh rebuild                 # Force rebuild and start
./opencode-web.sh status                  # Show all services
./opencode-web.sh urls                    # Show running URLs/ports
./opencode-web.sh down                    # Stop and remove all containers
```

## Container Startup Sequence (`entrypoint.sh`)

When a container starts, the entrypoint runs these steps in order:

1. **Config generation** — Runs `envsubst` on `opencode.json.template` to produce `/root/.config/opencode/opencode.json`, substituting environment variables (`LLM_BASE_URL`, `LLM_API_KEY`, `OPENCODE_MODEL`, tokens, etc.)
2. **Auth setup** — If `LLM_API_KEY` is set, writes `/root/.local/share/opencode/auth.json` with the key for both `anthropic` and `llm` providers.
3. **CA certificate install** — If `/certs/zscaler.pem` is mounted, copies it into the system CA store and sets `NODE_EXTRA_CA_CERTS` and `REQUESTS_CA_BUNDLE`.
4. **Plugin install** — Runs `npm install` in the config directory if `package.json` exists (offline-first).
5. **Project config check** — Checks for `/workspace/.opencode` directory and merges any project-level OpenCode configuration.
6. **Docker socket check** — Verifies the Docker socket is available (`/var/run/docker.sock`) for MCP containers that require it.
7. **Git safe.directory** — Sets `/workspace` as a safe directory for git operations (`git config --global safe.directory /workspace`).
8. **Prefill proxy startup** — Launches `prefill-proxy.mjs` on `127.0.0.1:18080` as a background process (see below).
9. **OpenCode web launch** — Starts `opencode web` on `0.0.0.0:${OPENCODE_PORT:-3000}`.

## Prefill Proxy (`prefill-proxy.mjs`)

A local HTTP proxy that sits between OpenCode and the upstream LLM API:

- **Listens on**: `http://127.0.0.1:18080`
- **Forwards to**: `$LLM_BASE_URL`
- **Purpose**: Strips trailing assistant messages from `/chat/completions` requests. Some models (e.g., Claude 4.6) don't support assistant message prefill, but OpenCode sends them. The proxy intercepts and removes them before forwarding.
- **Fallback**: If the proxy fails to start, the container logs a warning. You can point `opencode.json` directly at the upstream URL if needed.

The `opencode.json.template` routes all LLM traffic through this proxy (`baseURL: http://127.0.0.1:18080`).

## Docker Build (`Dockerfile`)

Multi-stage build for minimal image size:

### Stage 1: Builder
- Base: `node:22-bookworm-slim`
- Installs build tools (`build-essential`, `python3`)
- Installs `opencode-ai@1.2.15` globally via `npm install -g`
- Installs provider SDKs: `@ai-sdk/openai-compatible`, `@ai-sdk/groq`, `@openrouter/ai-sdk-provider`
- Installs MCP server packages globally via `npm install -g` (no `npx` / no registry checks at runtime):
  - `@modelcontextprotocol/server-memory`
  - `@upstash/context7-mcp`
  - `@modelcontextprotocol/server-sequential-thinking`
  - `mcp-time-server`
  - `@playwright/mcp`
  - `@cyanheads/git-mcp-server`

### Stage 2: Runtime
- Base: `node:22-bookworm-slim` (no build tools)
- Runtime tools: `git`, `curl`, `openssh-client`, `jq`, `ripgrep`, `unzip`
- Docker CLI (static binary, ~50 MB)
- Bun runtime
- Copies compiled `node_modules` from builder stage
- Re-creates global bin symlinks for all installed packages — MCP servers start instantly without any npm registry checks at runtime

## Configuration

### Environment Variables (`.env`)

| Variable | Required | Description |
|----------|----------|-------------|
| `LLM_BASE_URL` | **Yes** | OpenAI-compatible API endpoint |
| `LLM_API_KEY` | **Yes** | API key for the LLM provider |
| `OPENCODE_MODEL` | **Yes** | Model identifier (e.g., `llm/claude-opus-4-6`) |
| `OPENROUTER_API_KEY` | No | OpenRouter API key (for Llama, DeepSeek, etc.) |
| `OPENCODE_PORT` | No | Web UI port (default: `3000`) |
| `REPOS_PATH` | No | Host path to your repos (default: `~/repos`) |
| `CA_CERT_PATH` | No | Path to CA certificate bundle on host |
| `GITHUB_ENTERPRISE_TOKEN` | No | GitHub Enterprise PAT |
| `GITHUB_ENTERPRISE_URL` | No | GitHub Enterprise URL |
| `GITHUB_PERSONAL_TOKEN` | No | GitHub.com PAT |
| `CONFLUENCE_URL` | No | Confluence instance URL |
| `CONFLUENCE_USERNAME` | No | Confluence username/email |
| `CONFLUENCE_TOKEN` | No | Confluence API token |
| `JIRA_URL` | No | Jira instance URL |
| `JIRA_USERNAME` | No | Jira username/email |
| `JIRA_TOKEN` | No | Jira API token |
| `GRAFANA_URL` | No | Grafana instance URL |
| `GRAFANA_API_KEY` | No | Grafana API key |
| `OPENCODE_EXTRA_ARGS` | No | Extra arguments passed to `opencode web` |

### Supported Models

Configured in `opencode.json.template`:

**Via LLM Provider (OpenAI-compatible):**
| Model ID | Label |
|----------|-------|
| `claude-opus-4-6` | Claude Opus 4.6 |
| `claude-sonnet-4-6` | Claude Sonnet 4.6 |
| `claude-sonnet-4-5` | Claude Sonnet 4.5 |
| `claude-opus-4-5` | Claude Opus 4.5 |
| `claude-haiku-4-5` | Claude Haiku 4.5 |
| `gpt-5` | GPT-5 |
| `gpt-5-pro` | GPT-5 Pro |
| `gpt-5-mini` | GPT-5 Mini |
| `gpt-5-nano` | GPT-5 Nano |
| `gpt-5-codex` | GPT-5 Codex |
| `gpt-4.1` | GPT-4.1 |
| `gpt-4.1-mini` | GPT-4.1 Mini |
| `gpt-4.1-nano` | GPT-4.1 Nano |
| `gpt-4o` | GPT-4o |
| `gpt-4o-mini` | GPT-4o Mini |
| `o3` | OpenAI o3 |
| `o3-mini` | OpenAI o3 Mini |
| `o3-deep-research` | OpenAI o3 Deep Research |
| `o4-mini` | OpenAI o4 Mini |
| `model-router` | Model Router (Auto) |
| `Mistral-Large-3` | Mistral Large 3 |
| `llama3-2-3b-instruct-v1` | Llama 3.2 3B Instruct |

**Via OpenRouter:**
| Model ID | Label |
|----------|-------|
| `meta-llama/llama-4-scout` | Llama 4 Scout (10M context) |
| `meta-llama/llama-4-maverick` | Llama 4 Maverick (Vision) |
| `deepseek/deepseek-r1` | DeepSeek R1 (Reasoning) |
| `deepseek/deepseek-v3` | DeepSeek V3 |

### Config Generation Flow

```
.env  ──→  entrypoint.sh (envsubst)  ──→  /root/.config/opencode/opencode.json
           opencode.json.template
```

Only these variables are substituted (to avoid clobbering `$schema` etc.):
`LLM_BASE_URL`, `LLM_API_KEY`, `OPENROUTER_API_KEY`, `OPENCODE_MODEL`, `GITHUB_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_URL`, `GITHUB_PERSONAL_TOKEN`, `CONFLUENCE_URL`, `CONFLUENCE_USERNAME`, `CONFLUENCE_TOKEN`, `JIRA_URL`, `JIRA_USERNAME`, `JIRA_TOKEN`, `GRAFANA_URL`, `GRAFANA_API_KEY`, `CA_CERT_PATH`

## MCP Servers

| Server | Type | Enabled by Default | Description |
|--------|------|---------------------|-------------|
| `memory` | local | Yes | Persistent memory across sessions (`/root/.config/opencode/memory.json`) |
| `context7` | local | Yes | Context7 knowledge search |
| `websearch` | remote | Yes | Web search via Exa (`https://mcp.exa.ai/mcp`) |
| `sequential-thinking` | local | Yes | Advanced multi-step reasoning |
| `time` | local | Yes | Time/timezone utilities |
| `github` | local (Docker) | **No** | GitHub Enterprise — requires `GITHUB_ENTERPRISE_TOKEN` |
| `github_personal` | local (Docker) | **No** | GitHub.com — requires `GITHUB_PERSONAL_TOKEN` |
| `mcp-atlassian` | local (Docker) | **No** | Jira + Confluence — requires Atlassian tokens |
| `grafana` | local (Docker) | **No** | Grafana dashboards — requires `GRAFANA_API_KEY` |
| `playwright` | local | **No** | Browser automation |
| `git` | local | **No** | Git operations via MCP |

**Local** servers run as Node processes inside the container. **Local (Docker)** servers launch separate Docker containers (requires Docker socket mount).

To enable a disabled server, set `"enabled": true` in the template or override the generated config.

## Plugin System

The `opencode.json.template` includes a `"plugin"` field that activates the oh-my-opencode plugin system:

```json
"plugin": ["oh-my-opencode-slim"]
```

The `@opencode-ai/plugin` package is pre-installed in the Docker image. The plugin is configured via `~/.config/opencode/oh-my-opencode-slim.json`, which is mounted read-only into the container at `/root/.config/opencode/oh-my-opencode-slim.json`.

The plugin config defines **agent roles**, each with:
- A **model** selection (can differ per role)
- **MCP server** assignments (which tools each role can access)
- **Fallback chains** (alternative models if the primary is unavailable)

Roles defined in the default config:
| Role | Purpose |
|------|---------|
| `orchestrator` | Top-level task planning and delegation |
| `oracle` | Knowledge lookup and Q&A |
| `librarian` | Documentation and context retrieval |
| `explorer` | Code exploration and understanding |
| `designer` | Architecture and design decisions |
| `fixer` | Targeted code fixes and implementation |

To customise agent behaviour, edit `~/.config/opencode/oh-my-opencode-slim.json` on the host — the container will pick up changes on next start.

## Multi-Repo Setup

Each project gets its own container, port, data volume, and memory store.

### 1. Create your override file

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
```

### 2. Add a service per repo

```yaml
services:
  my-project:
    extends:
      file: docker-compose.yml
      service: opencode-docker
    container_name: opencode-my-project
    ports:
      !override
      - "3001:3001"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3001/"]
    environment:
      !override
      - NODE_EXTRA_CA_CERTS=/certs/ca-bundle.pem
      - REQUESTS_CA_BUNDLE=/certs/ca-bundle.pem
      - OPENCODE_PORT=3001
    volumes:
      !override
      - ${REPOS_PATH:-~/repos}/my-project:/workspace
      - opencode-data-my-project:/root/.local/share/opencode
      - opencode-memory-my-project:/root/.config/opencode/memory
      - ${HOME}/.config/opencode/commands:/root/.config/opencode/commands:ro
      - ${HOME}/.config/opencode/skills:/root/.config/opencode/skills:ro
      - ${HOME}/.config/opencode/oh-my-opencode-slim.json:/root/.config/opencode/oh-my-opencode-slim.json:ro
      - ${HOME}/.agents/skills:/root/.agents/skills:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - ${HOME}/.ssh:/root/.ssh:ro
      - ${HOME}/.gitconfig:/root/.gitconfig:ro
      - ${CA_CERT_PATH:-/dev/null}:/certs/ca-bundle.pem:ro

volumes:
  opencode-data-my-project:
    name: opencode-data-my-project
  opencode-memory-my-project:
    name: opencode-memory-my-project
```

> **Note:** `!override` (Docker Compose v2.24+) replaces inherited lists instead of merging them.

### 3. Start

```bash
./opencode-web.sh start                   # All services
./opencode-web.sh start my-project        # Just one
```

## Volumes

| Mount | Purpose |
|-------|---------|
| `/workspace` | Project source code |
| `/root/.local/share/opencode` | OpenCode data, auth, database |
| `/root/.config/opencode/memory` | MCP memory persistence |
| `/root/.config/opencode/commands` | Custom slash commands (read-only) |
| `/root/.config/opencode/skills` | Custom skills (read-only) |
| `/root/.config/opencode/oh-my-opencode-slim.json` | oh-my-opencode plugin config (read-only) |
| `/root/.agents/skills` | Agent skills (read-only) |
| `/root/.ssh` | SSH keys for git (read-only) |
| `/root/.gitconfig` | Git config (read-only) |
| `/var/run/docker.sock` | Docker socket for MCP containers |
| `/certs/ca-bundle.pem` | CA certificate (read-only) |

## Resource Limits

Defined in `docker-compose.yml`:
- **Memory limit**: 4 GB
- **Memory reservation**: 1 GB

## Healthcheck

Each container runs a healthcheck every 30 seconds:
```
curl -f http://localhost:${OPENCODE_PORT:-3000}/
```
- Interval: 30s
- Timeout: 10s
- Start period: 15s
- Retries: 3

## Gitignored Files

These files are local-only and not committed:
- `.env` — secrets
- `docker-compose.override.yml` — personal repo services
- `*.pem`, `ca-bundle.*` — certificates
- `opencode.json`, `auth.json`, `opencode.db`, `memory.json` — runtime files

## Troubleshooting

### Container won't start
```bash
./opencode-web.sh logs opencode-docker
# or
docker compose logs opencode-docker
```

### LLM API connection errors
- Verify `LLM_BASE_URL` and `LLM_API_KEY` in `.env`
- Check if the prefill proxy started: look for `✓ Prefill proxy running` in logs
- If behind a corporate proxy, ensure `CA_CERT_PATH` points to a valid PEM file

### "This model does not support assistant message prefill"
The prefill proxy should handle this automatically. If it fails to start, check logs for `✗ Prefill proxy failed to start`.

### MCP Docker servers not working
- Ensure Docker socket is mounted: look for `✓ Docker socket available` in startup logs
- Pull the required image manually: `docker pull ghcr.io/github/github-mcp-server`

### Port conflict
Change the port in `docker-compose.yml` or override:
```yaml
ports:
  - "3001:3001"
environment:
  - OPENCODE_PORT=3001
```

### Shell into a running container
```bash
./opencode-web.sh shell opencode-docker
```
