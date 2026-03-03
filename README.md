# OpenCode Web — Docker

Persistent AI coding agent running in Docker with a browser-based web UI. Each repo gets its own isolated container with dedicated volumes, MCP servers, and port.

## Quick Start

```bash
git clone <repo-url> && cd opencode-docker
cp .env.example .env
vim .env          # Set LLM_BASE_URL, LLM_API_KEY, OPENCODE_MODEL
./opencode-web.sh start
open http://localhost:3000
```

> **Corporate proxy?** Copy your CA bundle to `./ca-bundle.pem` and set `CA_CERT_PATH` in `.env`.

## TUI Mode (terminal UI in the browser)

Set `OPENCODE_MODE=tui` in `.env` to run the full opencode terminal interface instead of the web UI — the same experience you get when you type `opencode` in iTerm, but served in any browser via [ttyd](https://github.com/tsl0922/ttyd).

```bash
# .env
OPENCODE_MODE=tui
```

Then start normally:

```bash
./opencode-web.sh start
open http://localhost:3000   # opens a full xterm.js terminal running opencode
```

Switch back to the web UI at any time by removing the variable or setting `OPENCODE_MODE=web`.

> **Per-service:** You can mix modes across repos — set `OPENCODE_MODE=tui` in the `environment:` block of any service in `docker-compose.override.yml`.

## CLI (`opencode-web.sh`)

```bash
./opencode-web.sh start   [service]   # Build & start (all or one)
./opencode-web.sh stop    [service]   # Stop
./opencode-web.sh restart [service]   # Restart
./opencode-web.sh logs    <service>   # Follow logs
./opencode-web.sh shell   <service>   # Bash into container
./opencode-web.sh rebuild [service]   # Force rebuild & start
./opencode-web.sh update  [service]   # Rebuild with latest opencode-ai
./opencode-web.sh version [service]   # Show opencode-ai version in container
./opencode-web.sh status              # Show all services
./opencode-web.sh urls                # Show running URLs/ports
./opencode-web.sh down                # Stop & remove all containers
```

## Configuration

### Required Environment Variables

Set these three in `.env`:

| Variable | Description |
|----------|-------------|
| `LLM_BASE_URL` | OpenAI-compatible API endpoint |
| `LLM_API_KEY` | API key for the LLM provider |
| `OPENCODE_MODEL` | Model identifier (e.g. `llm/claude-opus-4-6`) |

<details>
<summary><strong>All environment variables</strong></summary>

| Variable | Description |
|----------|-------------|
| `OPENCODE_PORT` | Web UI / TUI port (default: `3000`) |
| `OPENCODE_MODE` | `web` (default) — browser web UI · `tui` — terminal UI via ttyd |
| `OPENCODE_VERSION` | Pin opencode-ai version for builds (default: `latest`) |
| `OPENCODE_AUTOUPDATE` | Enable in-container auto-updates every 12h (default: `true`). Set `false` for notify-only. |
| `OPENCODE_EXTRA_ARGS` | Extra arguments passed to `opencode web` or `opencode` (TUI mode) |
| `OPENCODE_TUI_ARGS` | Extra arguments passed to `ttyd` when `OPENCODE_MODE=tui` |
| `REPOS_PATH` | Host path to repos (default: `~/repos`) |
| `CA_CERT_PATH` | CA certificate bundle path on host |
| `PREFILL_PROXY` | Enable the prefill-stripping proxy (default: `true`). Set `false` to connect directly to `LLM_BASE_URL`. |
| `PROXY_LOG_LEVEL` | Prefill proxy verbosity: `debug` / `info` (default) / `warn` / `error` |
| `OPENROUTER_API_KEY` | OpenRouter API key |
| `GITHUB_ENTERPRISE_TOKEN` | GitHub Enterprise PAT |
| `GITHUB_ENTERPRISE_URL` | GitHub Enterprise URL |
| `GITHUB_PERSONAL_TOKEN` | GitHub.com PAT |
| `CONFLUENCE_URL` / `_USERNAME` / `_TOKEN` | Confluence access |
| `JIRA_URL` / `_USERNAME` / `_TOKEN` | Jira access |
| `GRAFANA_URL` / `GRAFANA_API_KEY` | Grafana access |

</details>

### Config Generation

```
.env + opencode.json.template  →  entrypoint.sh (envsubst)  →  opencode.json
```

The entrypoint substitutes only the variables listed above — it won't clobber `$schema` or other JSON references.

### Supported Models

<details>
<summary><strong>Via LLM Provider (OpenAI-compatible)</strong></summary>

Claude Opus/Sonnet/Haiku 4.x · GPT-5/5-Pro/5-Mini/5-Nano/5-Codex · GPT-4.1/4.1-Mini/4.1-Nano · GPT-4o/4o-Mini · o3/o3-Mini/o3-Deep-Research · o4-Mini · Model Router · Mistral Large 3 · Llama 3.2 3B Instruct

</details>

<details>
<summary><strong>Via OpenRouter</strong></summary>

Llama 4 Scout (10M context) · Llama 4 Maverick (Vision) · DeepSeek R1 (Reasoning) · DeepSeek V3

</details>

## MCP Servers

| Server | Enabled | Notes |
|--------|---------|-------|
| `memory` | ✅ | Persistent memory (`memory.json`) |
| `context7` | ✅ | Context7 knowledge search |
| `websearch` | ✅ | Web search via Exa (remote) |
| `sequential-thinking` | ✅ | Multi-step reasoning |
| `time` | ✅ | Time/timezone utilities |
| `github` | ❌ | GitHub Enterprise — runs in Docker, requires `GITHUB_ENTERPRISE_TOKEN` |
| `github_personal` | ❌ | GitHub.com — runs in Docker, requires `GITHUB_PERSONAL_TOKEN` |
| `mcp-atlassian` | ❌ | Jira + Confluence — runs in Docker, requires Atlassian tokens |
| `grafana` | ❌ | Grafana dashboards — runs in Docker, requires `GRAFANA_API_KEY` |
| `playwright` | ❌ | Browser automation |
| `git` | ❌ | Git operations via MCP |

Enabled servers run as Node processes inside the container. Docker-based servers (github, atlassian, grafana) launch separate containers via the mounted Docker socket. To enable a disabled server, set `"enabled": true` in the template.

## Plugin: oh-my-opencode-slim

Controls which models, skills, MCP servers, and fallback chains each agent role uses.

```bash
cp oh-my-opencode-slim.json.example ~/.config/opencode/oh-my-opencode-slim.json
```

The file is mounted read-only into containers and loaded by `@opencode-ai/plugin` at startup.

### Presets

Switch by setting `"preset"` in the JSON file:

| Preset | Description |
|--------|-------------|
| `default` | Full quality — Opus for orchestrator/oracle/designer, Sonnet for librarian/fixer, Haiku for explorer |
| `copilot` | All agents via GitHub Copilot (Grok) |
| `budget` | Cost-optimised — Sonnet for orchestrator/oracle/designer, Haiku for librarian/explorer/fixer |

### Agent Roles

| Role | Purpose |
|------|---------|
| `orchestrator` | Top-level planning, delegation, tool use |
| `oracle` | Deep reasoning, architecture decisions |
| `librarian` | Docs lookup, library research |
| `explorer` | Fast codebase search, file discovery |
| `designer` | UI/UX, styling, visual polish |
| `fixer` | Targeted code fixes, implementation |

Each role accepts: `model`, `variant` (`high`/`medium`/`low`), `skills` (array), `mcps` (array of server names).

<details>
<summary><strong>Fallback chains</strong></summary>

When a primary model is unavailable or exceeds `timeoutMs` (default 15s), the next model in the chain is tried:

```jsonc
"fallback": {
  "enabled": true,
  "timeoutMs": 15000,
  "chains": {
    "orchestrator": ["llm/claude-sonnet-4-6", "llm/claude-sonnet-4-5", "llm/gpt-5"],
    "oracle":       ["llm/o3", "llm/claude-sonnet-4-6", "openrouter/deepseek/deepseek-r1"],
    "designer":     ["llm/claude-sonnet-4-6", "llm/claude-opus-4-5"],
    "explorer":     ["llm/claude-haiku-4-5", "llm/gpt-4.1-mini"],
    "librarian":    ["llm/claude-sonnet-4-5", "openrouter/meta-llama/llama-4-scout"],
    "fixer":        ["llm/claude-sonnet-4-5", "llm/gpt-5-codex"]
  }
}
```

Disable with `"fallback": { "enabled": false }`.

</details>

## Multi-Repo Setup

Each project gets its own container, port, and data volumes.

**1.** Create your override file:

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
```

**2.** Add a service per repo (see the example file for full template):

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
    environment:
      !override
      - OPENCODE_PORT=3001
    volumes:
      !override
      - ${REPOS_PATH:-~/repos}/my-project:/workspace
      - opencode-data-my-project:/root/.local/share/opencode
      # ... (see docker-compose.override.yml.example for all mounts)
```

> `!override` (Docker Compose v2.24+) replaces inherited lists instead of merging.

**3.** Start:

```bash
./opencode-web.sh start my-project
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Container won't start | `./opencode-web.sh logs <service>` — check for errors |
| LLM API errors | Verify `LLM_BASE_URL` / `LLM_API_KEY` in `.env`. Check for `✓ Prefill proxy running` in logs. Set `PROXY_LOG_LEVEL=debug` for details. |
| "Model does not support assistant prefill" | Prefill proxy handles this — look for `✗ Prefill proxy failed to start` in logs |
| MCP Docker servers not working | Check for `✓ Docker socket available` in logs. Pull image manually if needed. |
| Port conflict | Change port in override: `ports: ["3001:3001"]` + `OPENCODE_PORT=3001` |
| Need a shell | `./opencode-web.sh shell <service>` |

## Auto-Update

Containers automatically check for new `opencode-ai` releases every 12 hours.

- **Enabled by default** — set `OPENCODE_AUTOUPDATE=false` in `.env` to disable
- When enabled: installs the new version quietly (`--loglevel=error`) and restarts `opencode web` in-place (sessions persist on disk — the web UI reconnects)
- When disabled: logs a notification about the available update but doesn't install it
- **Manual update**: `./opencode-web.sh update [service]` rebuilds the image with the latest version
- **Check version**: `./opencode-web.sh version [service]`
- **Pin version**: Set `OPENCODE_VERSION=1.2.15` in `.env` to lock the build to a specific release

---

<details>
<summary><strong>Internals: Container Startup Sequence</strong></summary>

When a container starts, `entrypoint.sh` runs these steps:

1. **Config generation** — `envsubst` on `opencode.json.template` → `opencode.json`
2. **Auth setup** — Writes `auth.json` with `LLM_API_KEY` for anthropic/llm providers
3. **CA certificate install** — If `/certs/ca-bundle.pem` is mounted and non-empty, installs into system store + sets `NODE_EXTRA_CA_CERTS`
4. **Plugin install** — `npm install` in config dir if `package.json` exists
5. **Project config check** — Detects `/workspace/.opencode` project-level config
6. **Docker socket check** — Verifies `/var/run/docker.sock` for MCP containers
7. **Git safe.directory** — Exports `GIT_CONFIG_*` env vars to mark `/workspace` as safe
8. **Workspace symlink** — Symlinks `/workspace` into `$HOME` so the web UI "Open project" dialog can discover it
9. **Prefill proxy** — Launches `prefill-proxy.mjs` on `127.0.0.1:18080` (if `PREFILL_PROXY=true` and `OPENCODE_MODE=web`, the default)
10. **Auto-update cron** — Installs a 12-hourly cron job (update or notify-only, per `OPENCODE_AUTOUPDATE`)
11. **Mode selection** — Reads `OPENCODE_MODE` (default `web`):
    - `web` — starts `opencode web` in a restart loop on `0.0.0.0:${OPENCODE_PORT:-3000}`
    - `tui` — starts `ttyd opencode` in a restart loop on the same port; browser opens a full xterm.js terminal

</details>

<details>
<summary><strong>Internals: Prefill Proxy</strong></summary>

A local HTTP proxy between OpenCode and the upstream LLM API:

- **Listens**: `127.0.0.1:18080` → **Forwards to**: `$LLM_BASE_URL`
- **Purpose**: Strips trailing assistant messages from `/chat/completions` — some models don't support prefill but OpenCode sends it
- **Liveness**: The restart loop checks the proxy PID after each `opencode web` exit and relaunches it if dead, ensuring `127.0.0.1:18080` is always reachable before the next start
- **Logging**: Each request gets a correlation ID (e.g. `[a3f1c2]`). Logs include timings, message counts, stripping events, and periodic stats.
- **Log levels**: `debug` (everything + headers) · `info` (default) · `warn` (disconnects, 4xx) · `error` (failures, timeouts)

</details>

<details>
<summary><strong>Internals: Docker Build</strong></summary>

Multi-stage build for minimal image size:

**Builder stage** — `node:22-bookworm-slim` with build tools. Installs `opencode-ai` (version set by `OPENCODE_VERSION` build arg, default `latest`), provider SDKs (`@ai-sdk/openai-compatible`, `@ai-sdk/groq`, `@openrouter/ai-sdk-provider`), and MCP servers globally.

**Runtime stage** — `node:22-bookworm-slim` (no build tools). Adds `git`, `curl`, `jq`, `ripgrep`, `openssh-client`, `unzip`, `cron`, `tini` (PID 1), Docker CLI, Bun, `python3` (required by the cartography skill), and `ttyd` (web terminal for `OPENCODE_MODE=tui`). Copies `node_modules` from builder and re-creates bin symlinks — MCP servers start instantly with no registry checks.

</details>

<details>
<summary><strong>Internals: Volumes Reference</strong></summary>

| Mount | Purpose |
|-------|---------|
| `/workspace` | Project source code |
| `/root/.local/share/opencode` | OpenCode data, auth, database |
| `/root/.config/opencode/memory` | MCP memory persistence |
| `/root/.config/opencode/commands` | Custom slash commands (ro) |
| `/root/.config/opencode/skills` | Custom skills (ro) |
| `/root/.config/opencode/oh-my-opencode-slim.json` | Plugin config (ro) |
| `/root/.agents/skills` | Agent skills (ro) |
| `/root/.ssh` | SSH keys for git (ro) |
| `/root/.gitconfig` | Git config (ro) |
| `/root/.git-credentials` | Git credentials (ro) |
| `/var/run/docker.sock` | Docker socket for MCP containers |
| `/certs/ca-bundle.pem` | CA certificate (ro) |

</details>

<details>
<summary><strong>Internals: Project Structure</strong></summary>

```
├── Dockerfile                          # Multi-stage build
├── docker-compose.yml                  # Base service definition
├── docker-compose.override.yml.example # Template for your repos
├── docker-compose.override.yml         # Your repo services (gitignored)
├── .env.example / .env                 # Config template / your secrets (gitignored)
├── entrypoint.sh                       # Container startup script
├── opencode-web.sh                     # Host CLI wrapper
├── opencode.json.template              # OpenCode config template
├── prefill-proxy.mjs                   # LLM proxy (strips prefill)
├── oh-my-opencode-slim.json.example    # Plugin preset template
└── ca-bundle.pem                       # CA certificate (gitignored)
```

</details>

<details>
<summary><strong>Internals: Resource Limits & Healthcheck</strong></summary>

- **Memory**: 4 GB limit / 1 GB reservation
- **Healthcheck**: `curl -f http://localhost:${OPENCODE_PORT:-3000}/` every 30s (timeout 10s, start period 15s, 3 retries)
- **Gitignored**: `.env`, `docker-compose.override.yml`, `*.pem`, `opencode.json`, `auth.json`, `opencode.db`, `memory.json`

</details>
