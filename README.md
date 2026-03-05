# OpenCode Web — Docker

Run [OpenCode](https://github.com/opencode-ai/opencode) — an AI coding agent — entirely inside Docker, accessible from any browser. No local Node.js, no CLI install, no environment clutter. Point it at your LLM provider, pick a UI mode, and open `localhost:3000`.

Three modes, all served in the browser:

| Mode | Set in `.env` | What you get |
|------|--------------|--------------|
| **web** (default) | `OPENCODE_MODE=web` | OpenCode's built-in browser UI |
| **tui** | `OPENCODE_MODE=tui` | The full terminal UI rendered in the browser via [ttyd](https://github.com/tsl0922/ttyd) / xterm.js — identical to running `opencode` in a local terminal |
| **tmux** | `OPENCODE_MODE=tmux` | Same terminal UI, but wrapped in a persistent [tmux](https://github.com/tmux/tmux) session — survives browser disconnects, supports pane splitting, shell access alongside opencode, and a built-in agent activity monitor |

Each repo gets its own isolated container with dedicated volumes, MCP servers, and port.

## Quick Start

```bash
git clone <repo-url> && cd opencode-docker
cp .env.example .env
vim .env          # Set LLM_BASE_URL, LLM_API_KEY, OPENCODE_MODEL
./opencode-web.sh start
open http://localhost:3000
```

> **Corporate proxy?** Copy your CA bundle to `./ca-bundle.pem` and set `CA_CERT_PATH` in `.env`.

## UI Modes

### web (default)

Nothing to configure — `./opencode-web.sh start` launches OpenCode's browser UI on port 3000. This is the standard graphical interface with file trees, conversation panels, and tool output.

### tui — terminal UI in the browser

Set `OPENCODE_MODE=tui` in `.env` to run OpenCode's terminal interface instead. It's served in the browser via [ttyd](https://github.com/tsl0922/ttyd) — you see a full xterm.js terminal running `opencode`, exactly as it would look in a local terminal. Useful if you prefer the keyboard-driven TUI or want a lighter-weight experience.

```bash
# .env
OPENCODE_MODE=tui
```

Start normally — the same URL now opens a terminal:

```bash
./opencode-web.sh start
open http://localhost:3000
```

Switch back at any time by removing the variable or setting `OPENCODE_MODE=web`.

> **Per-service:** You can mix modes across repos — set `OPENCODE_MODE` in the `environment:` block of any service in `docker-compose.override.yml`.

### tmux — persistent terminal UI

`OPENCODE_MODE=tmux` wraps the TUI in a persistent tmux session. This is the same terminal UI as `tui` mode, but with important differences:

| | tui | tmux |
|---|-----|------|
| **Session persistence** | Closing the browser tab kills opencode | Session survives — reopening the URL reattaches instantly |
| **Pane splitting** | Single pane only | Split panes to run shells alongside opencode |
| **Shell access from host** | Not possible | `docker exec -it <container> tmux attach -t opencode` |
| **Scrollback** | Browser-managed | 50,000 lines, vi keys, mouse scroll |
| **Agent monitor** | Not available | Built-in status bar + live monitor pane showing subagent activity |

```bash
# .env
OPENCODE_MODE=tmux
```

The default tmux prefix is **Ctrl-Space** (not the default Ctrl-b). Key bindings:

| Key | Action |
|-----|--------|
| `Ctrl-Space \|` | Split pane vertically |
| `Ctrl-Space -` | Split pane horizontally |
| `Ctrl-Space h/j/k/l` | Navigate panes (vim-style) |
| `Ctrl-Space H/J/K/L` | Resize panes (5 cells, repeatable) |
| `Ctrl-Space Ctrl-Space` | Cycle to next pane |
| `Ctrl-Space c` | New window |
| `Ctrl-Space Enter` | Enter copy/scroll mode (vi keys) |
| `Ctrl-Space r` | Reload tmux config |
| `Option-m` | Toggle agent monitor pane (25% height, bottom) |
| `Option-Shift-m` | Agent monitor fullscreen window |
| `Option-s` | Toggle status bar |

> **Note:** The `Ctrl-Space` prefix is intercepted by most browsers and ttyd, so the `m`/`M`/`s` monitor bindings use `Option-` root keys instead (no prefix needed). The pane/window bindings above work because `Ctrl-Space` + a letter typically passes through.

#### Agent monitor

The **status bar** shows session info on the left (`opencode │ branch │ model │ context-size`) and active subagent activity on the right (e.g. `2 ⚡explorer·fixer`) plus the local time. Press `Option-m` (or `Ctrl-Space m`) to open a live monitor pane at the bottom of the screen — it polls the SQLite DB and shows a color-coded feed of subagent lifecycle events: `▶ agent started` (with model name and timestamp) and `■ agent done` (with duration and token usage: in/out/cache). Press `Option-Shift-m` (or `Ctrl-Space M`) to open the same feed in a dedicated tmux window instead.

#### Custom tmux config

Mount your own `tmux.conf` to override the defaults:

```yaml
# docker-compose.override.yml
services:
  my-project:
    volumes:
      - ./my-tmux.conf:/root/.config/opencode/tmux.conf:ro
```

If `/root/.config/opencode/tmux.conf` exists, it replaces the built-in config at startup. The built-in config uses `xterm-256color` as the terminal type and enables true-color and RGB passthrough so the opencode TUI renders identically in tmux mode and plain tui mode.

## CLI (`opencode-web.sh`)

```bash
./opencode-web.sh start   [service]   # Build & start (all or one)
./opencode-web.sh stop    [service]   # Stop
./opencode-web.sh restart [service]   # Restart
./opencode-web.sh logs    [service]   # Follow logs
./opencode-web.sh shell   [service]   # Bash into container
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
| `OPENCODE_MODE` | `web` (default) — browser web UI · `tui` — terminal UI via ttyd · `tmux` — terminal UI via tmux + ttyd |
| `OPENCODE_VERSION` | Pin opencode-ai version for builds (default: `latest`) |
| `OPENCODE_MODEL_FALLBACK` | Fallback model if LLM gateway is unreachable at startup (e.g. `github-copilot/gemini-2.5-pro`) |
| `OPENCODE_EXTRA_ARGS` | Extra arguments passed to `opencode web` or `opencode` (TUI/tmux mode) |
| `OPENCODE_TUI_ARGS` | Extra arguments passed to `ttyd` when `OPENCODE_MODE=tui` or `tmux` |
| `REPOS_PATH` | Host path to repos (default: `~/repos`) |
| `CA_CERT_PATH` | CA certificate bundle path on host |
| `PREFILL_PROXY` | Enable the prefill-stripping proxy (default: `true`). Set `false` to connect directly to `LLM_BASE_URL`. |
| `PROXY_LOG_LEVEL` | Prefill proxy verbosity: `debug` / `info` (default) / `warn` / `error` |
| `DOCKER_NETWORK_MODE` | Set to `host` on Linux to bypass Docker bridge NAT (~70-80ms savings). Not supported on Docker Desktop. |
| `GIT_CREDENTIALS_PATH` | Host path to `.git-credentials` for HTTPS push (default: `/dev/null` = disabled) |
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

The plugin npm package and its default config (`oh-my-opencode-slim.json.example`) are both baked into the Docker image at build time — no host-side installation or mount is needed.

To override the defaults, mount your own config file:

```yaml
# docker-compose.override.yml
volumes:
  - ./my-slim-config.json:/root/.config/opencode/oh-my-opencode-slim.json:ro
```

### Presets

Switch by setting `"preset"` in the JSON file:

| Preset | Description |
|--------|-------------|
| `default` | Full quality — Opus orchestrator, Sonnet oracle/explorer/fixer, Gemini 2.5 Pro designer/librarian |

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
    "orchestrator": ["llm/claude-opus-4-5", "github-copilot/gemini-2.5-pro"],
    "oracle":       ["llm/claude-sonnet-4-5", "github-copilot/gemini-2.5-pro"],
    "designer":     ["llm/claude-sonnet-4-5", "github-copilot/gemini-2.5-pro"],
    "explorer":     ["llm/claude-sonnet-4-5", "github-copilot/gemini-2.5-pro"],
    "librarian":    ["llm/claude-sonnet-4-5", "github-copilot/gemini-2.5-pro"],
    "fixer":        ["llm/claude-sonnet-4-5", "github-copilot/gemini-2.5-pro"]
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
| TUI: attach to tmux from host | `docker exec -it <container> tmux attach -t opencode` |
| TUI: tmux key bindings not working | Use `Option-m` / `Option-s` root bindings (Mac); or try `Ctrl-Space` prefix (may be intercepted by browser/ttyd) |
| TUI: custom tmux config | Mount to `/root/.config/opencode/tmux.conf:ro` — applied at startup |

## Updating

Packages are installed at Docker image build time only — there are no in-container auto-updates.

- **Update to latest**: `./opencode-web.sh update [service]` — rebuilds the image with the latest `opencode-ai`
- **Check version**: `./opencode-web.sh version [service]`
- **Pin version**: Set `OPENCODE_VERSION=1.2.15` in `.env` to lock the build to a specific release

---

<details>
<summary><strong>Internals: Container Startup Sequence</strong></summary>

When a container starts, `entrypoint.sh` runs these steps:

1. **Config generation** — `envsubst` on `opencode.json.template` → `opencode.json`. Resolves `CA_CERT_PATH` to the host-side absolute path (for sibling Docker containers) by inspecting the container's own mounts.
2. **LLM gateway health check** — If `OPENCODE_MODEL_FALLBACK` is set, probes `LLM_BASE_URL/models`. On failure, switches `OPENCODE_MODEL` to the fallback and disables the prefill proxy.
3. **Auth setup** — Writes `auth.json` with `LLM_API_KEY` for anthropic/llm providers
4. **Host auth merge** — If the host's `auth.json` is mounted (Copilot tokens etc.), merges new providers into the container's `auth.json` without overwriting existing entries
5. **CA certificate install** — If `/certs/ca-bundle.pem` is mounted and non-empty, installs into system store + sets `NODE_EXTRA_CA_CERTS`
6. **Plugin install** — `npm install` in config dir if `package.json` exists
7. **Project config check** — Detects `/workspace/.opencode` project-level config
8. **Docker socket check** — Verifies `/var/run/docker.sock` for MCP containers
9. **Git safe.directory** — Exports `GIT_CONFIG_*` env vars to mark `/workspace` as safe
10. **Git credentials check** — Validates `.git-credentials` mount (warns if it's a directory instead of a file)
11. **Workspace symlink** — Symlinks `/workspace` into `$HOME` so the web UI "Open project" dialog can discover it
12. **Prefill proxy** — Launches `prefill-proxy.mjs` on `127.0.0.1:18080` (if `PREFILL_PROXY=true`, the default) and warms up the upstream TLS connection. Used in all modes — opencode reads `opencode.json` which routes LLM traffic through the proxy regardless of mode
13. **Mode selection** — Reads `OPENCODE_MODE` (default `web`):
    - `web` — starts `opencode web` in a restart loop on `0.0.0.0:${OPENCODE_PORT:-3000}`
    - `tui` — starts `ttyd` serving the opencode TUI directly in a restart loop on the same port.
    - `tmux` — creates a tmux session (`opencode`) running the TUI in a restart loop, then starts `ttyd` serving `tmux attach` on the same port. Browser opens a full xterm.js terminal with tmux; `docker exec` can also attach to the same session.

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

**Runtime stage** — `node:22-bookworm-slim` (no build tools). Adds `git`, `curl`, `jq`, `ripgrep`, `openssh-client`, `unzip`, `tini` (PID 1), `tmux` (terminal multiplexer for tmux mode), Docker CLI, Bun, `python3` (required by the cartography skill), and `ttyd` (web terminal for `OPENCODE_MODE=tui` and `tmux`). Copies `node_modules` from builder and re-creates bin symlinks — MCP servers start instantly with no registry checks.

</details>

<details>
<summary><strong>Internals: Volumes Reference</strong></summary>

| Mount | Purpose |
|-------|---------|
| `/workspace` | Project source code |
| `/root/.local/share/opencode` | OpenCode data, auth, database |
| `/root/.config/opencode/memory` | MCP memory persistence |
| `/root/.ssh` | SSH keys for git (ro) |
| `/root/.gitconfig` | Git config (ro) |
| `/root/.git-credentials` | Git credentials (ro) |
| `/root/.config/github-copilot` | GitHub Copilot auth reuse from host (ro) |
| `/opt/opencode/host-auth.json` | Host auth.json for provider merge at startup (ro) |
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
├── .dockerignore                       # Docker build context exclusions
├── .gitignore                          # Git ignore rules
├── .env.example / .env                 # Config template / your secrets (gitignored)
├── entrypoint.sh                       # Container startup script
├── opencode-web.sh                     # Host CLI wrapper
├── opencode.json.template              # OpenCode config template
├── tmux.conf                           # tmux configuration (TUI mode)
├── agent-monitor.sh                    # Agent activity monitor for tmux pane
├── agent-monitor-toggle.sh             # Toggle agent monitor pane on/off
├── agent-status.sh                     # tmux status bar subagent indicator
├── session-status.sh                   # tmux status bar: model, branch, context size
├── prefill-proxy.mjs                   # LLM proxy (strips prefill)
├── oh-my-opencode-slim.json.example    # Plugin preset config (baked into image at build)
├── AGENTS.md                           # Agent architecture documentation
├── LICENSE                             # Project license
└── ca-bundle.pem                       # CA certificate (gitignored)
```

</details>

<details>
<summary><strong>Internals: Resource Limits & Healthcheck</strong></summary>

- **Memory**: 4 GB limit / 1 GB reservation
- **Healthcheck**: `curl -f http://localhost:${OPENCODE_PORT:-3000}/` every 30s (timeout 10s, start period 15s, 3 retries)
- **Gitignored**: `.env`, `docker-compose.override.yml`, `*.pem`, `opencode.json`, `auth.json`, `opencode.db`, `memory.json`

</details>
