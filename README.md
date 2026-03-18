# OpenCode — Docker

Run [OpenCode](https://github.com/opencode-ai/opencode) or [Claude Code](https://github.com/anthropics/claude-code) — AI coding agents — entirely inside Docker, accessible from any browser. No local Node.js, no CLI install, no environment clutter. Pick a UI mode, point it at your LLM provider or API key, and open `localhost:3000`. Run multiple repos side-by-side — each gets its own container, port, and data volumes.

**Coding agent** (set `OPENCODE_APP` in `.env`):

| Agent | `OPENCODE_APP` | What you get |
|-------|---------------|--------------|
| **OpenCode** (default) | `opencode` | [OpenCode AI](https://github.com/opencode-ai/opencode) — supports `web`, `tui`, and `tmux` modes |
| **Claude Code** | `claude-code` | [Anthropic Claude Code](https://github.com/anthropics/claude-code) — supports `tui` and `tmux` modes only |

**UI mode** (set `OPENCODE_MODE` in `.env`), all served in the browser:

| Mode | Set in `.env` | What you get |
|------|--------------|--------------|
| **web** (default) | `OPENCODE_MODE=web` | OpenCode's built-in browser UI (OpenCode only) |
| **tui** | `OPENCODE_MODE=tui` | The full terminal UI rendered in the browser via [ttyd](https://github.com/tsl0922/ttyd) / xterm.js — identical to running the agent in a local terminal |
| **tmux** | `OPENCODE_MODE=tmux` | Same terminal UI, but wrapped in a persistent [tmux](https://github.com/tmux/tmux) session — survives browser disconnects, supports pane splitting, shell access alongside the agent, and a built-in agent activity monitor |

## Quick Start

### OpenCode

```bash
git clone <repo-url> && cd opencode-docker
cp .env.example .env
vim .env          # Set LLM_BASE_URL, LLM_API_KEY, OPENCODE_MODEL
./opencode-web.sh start
open http://localhost:3000
```

### Claude Code

```bash
git clone <repo-url> && cd opencode-docker
cp .env.example .env
vim .env          # Set ANTHROPIC_API_KEY, OPENCODE_APP=claude-code, OPENCODE_MODE=tmux
./opencode-web.sh start
open http://localhost:3000
```

> **Note:** Claude.ai OAuth login does **not** work in headless Docker. You must provide `ANTHROPIC_API_KEY` (or `LLM_API_KEY` as a fallback).

> **Corporate proxy?** Copy your CA bundle to `./ca-bundle.pem` and set `CA_CERT_PATH` in `.env`.

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

## Claude Code Mode

Set `OPENCODE_APP=claude-code` in `.env` to run [Anthropic Claude Code](https://github.com/anthropics/claude-code) instead of OpenCode. The same Docker image supports both — the entrypoint detects `OPENCODE_APP` at startup and configures the correct agent.

### Key differences from OpenCode

| | OpenCode | Claude Code |
|---|---------|-------------|
| **UI modes** | `web`, `tui`, `tmux` | `tui`, `tmux` only (no web mode) |
| **API key** | `LLM_API_KEY` | `ANTHROPIC_API_KEY` (falls back to `LLM_API_KEY`) |
| **Custom endpoint** | `LLM_BASE_URL` | `ANTHROPIC_BASE_URL` (falls back to `LLM_BASE_URL`) |
| **Prefill proxy** | ✅ Enabled | ✗ Not used |
| **Model fallback** | ✅ `OPENCODE_MODEL_FALLBACK` | ✗ Not applicable |
| **Agent monitor** | ✅ tmux status bar + pane | ✗ Not available |
| **Data volume** | `/root/.local/share/opencode` | `/root/.claude` |
| **MCP servers** | Configured via `opencode.json` | Configured via `claude-code-mcp.json` |

### Setup

**1.** Set in `.env`:

```bash
OPENCODE_APP=claude-code
OPENCODE_MODE=tmux        # or tui — web mode is not supported
ANTHROPIC_API_KEY=sk-ant-...
```

**2.** Add the Claude Code data volume to your service in `docker-compose.override.yml`:

```yaml
services:
  my-project:
    environment:
      !override
      - OPENCODE_APP=claude-code
      - OPENCODE_MODE=tmux
      - OPENCODE_PORT=3004
    volumes:
      !override
      - ${REPOS_PATH:-~/repos}/my-project:/workspace
      - claude-code-data-my-project:/root/.claude
      - opencode-memory-claude-my-project:/root/.config/opencode/memory
      - /var/run/docker.sock:/var/run/docker.sock
      - ./.env:/opt/opencode/.env:ro
      - ${HOME}/.ssh:/root/.ssh:ro
      - ${HOME}/.gitconfig:/root/.gitconfig:ro

volumes:
  claude-code-data-my-project:
    name: claude-code-data-my-project
  opencode-memory-claude-my-project:
    name: opencode-memory-claude-my-project
```

> **Note:** Always mount a named volume to `/root/.claude` — this persists Claude Code's session data, settings, and memory across container restarts. Without it, all session data is lost on `docker compose down`.

> **Upgrading Claude Code?** After rebuilding the image, run `docker volume rm claude-code-data-my-project` if you encounter compatibility issues with stale session data.

**3.** Start normally:

```bash
./opencode-web.sh start my-project
open http://localhost:3004
```

### Authentication

The entrypoint automatically configures authentication at startup:

- `ANTHROPIC_API_KEY` is used directly if set
- Otherwise `LLM_API_KEY` is mapped to `ANTHROPIC_API_KEY`
- `ANTHROPIC_BASE_URL` is used if set (for custom or proxy endpoints)
- Otherwise `LLM_BASE_URL` is mapped to `ANTHROPIC_BASE_URL`

The interactive onboarding wizard, API key approval prompt, and workspace trust dialog are all pre-seeded — the TUI starts directly without interactive prompts.

### MCP servers in Claude Code mode

The same MCP servers available for OpenCode are pre-configured for Claude Code via `/opt/opencode/claude-code-mcp.json.template`:

| Server | Status |
|--------|--------|
| `memory` | ✅ Enabled |
| `context7` | ✅ Enabled |
| `sequential-thinking` | ✅ Enabled |
| `time` | ✅ Enabled |
| `websearch` | ✅ Enabled (remote HTTP) |
| `playwright` | ❌ Disabled by default |
| `git` | ❌ Disabled by default |

### tmux adaptations for Claude Code

When running Claude Code in `tmux` mode, the status bar uses a simplified display (`claude-code │ branch`) — model and context-size scraping are not available since Claude Code manages its own model selection. The agent monitor pane and keybindings (`Option-m`, `Option-Shift-m`) show an informational message instead.

## CLI (`opencode-web.sh`)

```bash
./opencode-web.sh start   [service]   # Build & start (all or one)
./opencode-web.sh stop    [service]   # Stop
./opencode-web.sh restart [service]   # Restart
./opencode-web.sh logs    [service]   # Follow logs
./opencode-web.sh shell   [service]   # Bash into container
./opencode-web.sh rebuild [service]   # Force rebuild & start
./opencode-web.sh nuke    [service]   # Rebuild with latest opencode-ai
./opencode-web.sh version [service]   # Show opencode-ai version in container
./opencode-web.sh status              # Show all services
./opencode-web.sh urls                # Show running URLs/ports
./opencode-web.sh down                # Stop & remove all containers
```

## Configuration

### Required Environment Variables

**For OpenCode** — set these three in `.env`:

| Variable | Description |
|----------|-------------|
| `LLM_BASE_URL` | OpenAI-compatible API endpoint |
| `LLM_API_KEY` | API key for the LLM provider |
| `OPENCODE_MODEL` | Model identifier (e.g. `llm/claude-opus-4-6`) |

**For Claude Code** — set these in `.env`:

| Variable | Description |
|----------|-------------|
| `ANTHROPIC_API_KEY` | Anthropic API key. Falls back to `LLM_API_KEY` if not set |
| `OPENCODE_APP` | Set to `claude-code` |
| `OPENCODE_MODE` | Set to `tui` or `tmux` (web mode is not supported) |
| `ANTHROPIC_BASE_URL` | *(Optional)* Custom/proxy endpoint. Falls back to `LLM_BASE_URL` if not set |

<details>
<summary><strong>All environment variables</strong></summary>

| Variable | Description |
|----------|-------------|
| `OPENCODE_APP` | `opencode` (default) — OpenCode AI agent · `claude-code` — Anthropic Claude Code agent |
| `OPENCODE_PORT` | Web UI / TUI port (default: `3000`) |
| `OPENCODE_MODE` | `web` (default) — browser web UI · `tui` — terminal UI via ttyd · `tmux` — terminal UI via tmux + ttyd. Note: `web` is not supported for Claude Code |
| `OPENCODE_VERSION` | Pin opencode-ai version for builds (default: `latest`) |
| `OPENCODE_MODEL_FALLBACK` | Fallback model if LLM gateway is unreachable at startup (e.g. `github-copilot/gemini-2.5-pro`). OpenCode only, ignored for Claude Code |
| `OPENCODE_EXTRA_ARGS` | Extra arguments passed to the agent binary |
| `OPENCODE_TUI_ARGS` | Extra arguments passed to `ttyd` when `OPENCODE_MODE=tui` or `tmux` |
| `ANTHROPIC_API_KEY` | Anthropic API key for Claude Code. Falls back to `LLM_API_KEY` if not set |
| `ANTHROPIC_BASE_URL` | Custom/proxy endpoint for Claude Code. Falls back to `LLM_BASE_URL` if not set |
| `REPOS_PATH` | Host path to repos (default: `~/repos`) |
| `CA_CERT_PATH` | CA certificate bundle path on host |
| `PREFILL_PROXY` | Enable the prefill-stripping proxy (default: `true`). Set `false` to connect directly to `LLM_BASE_URL`. |
| `PROXY_LOG_LEVEL` | Prefill proxy verbosity: `debug` / `info` (default) / `warn` / `error` |
| `DOCKER_NETWORK_MODE` | Set to `host` on Linux to bypass Docker bridge NAT (~70-80ms savings). Not supported on Docker Desktop. |
| `GIT_CREDENTIALS_PATH` | Host path to `.git-credentials` for HTTPS push (default: disabled) |
| `HOST_AUTH_JSON` | Host path to `auth.json` for Copilot tokens etc. (default: disabled) |
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
| Claude Code: no API key error | Set `ANTHROPIC_API_KEY` in `.env`. OAuth login does not work in headless Docker |
| Claude Code: web mode fails | Set `OPENCODE_MODE=tui` or `OPENCODE_MODE=tmux` — web mode is not supported for Claude Code |
| Claude Code: session data lost after restart | Mount a named volume to `/root/.claude` — see [Claude Code Mode](#claude-code-mode) |
| Claude Code: stale session data after upgrade | Run `docker volume rm <claude-code-data-volume>` then restart |

## Updating

Packages are installed at Docker image build time only — there are no in-container auto-updates.

- **Update to latest**: `./opencode-web.sh nuke [service]` — rebuilds the image with the latest `opencode-ai`
- **Check version**: `./opencode-web.sh version [service]`
- **Pin version**: Set `OPENCODE_VERSION=1.2.15` in `.env` to lock the build to a specific release

---

<details>
<summary><strong>Internals: Container Startup Sequence</strong></summary>

When a container starts, `entrypoint.sh` runs these steps:

**Common steps (both agents):**

1. **Agent selection** — Reads `OPENCODE_APP` (default `opencode`). Determines which agent binary and config path to use.
2. **CA path resolution** — Resolves `CA_CERT_PATH` to the absolute host path for sibling Docker containers.
3. **CA certificate install** — If `/certs/ca-bundle.pem` is mounted and non-empty, installs into system store + sets `NODE_EXTRA_CA_CERTS`
4. **Docker socket check** — Verifies `/var/run/docker.sock` for MCP containers
5. **Git safe.directory** — Exports `GIT_CONFIG_*` env vars to mark `/workspace` (and sub-repos) as safe
6. **Git credentials check** — Validates `.git-credentials` mount
7. **Workspace symlink** — Symlinks `/workspace` into `$HOME` for project discovery
8. **Mode selection** — Reads `OPENCODE_MODE` (default `web`):
    - `web` — starts `opencode web` in a restart loop on `0.0.0.0:${OPENCODE_PORT:-3000}` (OpenCode only — fails for Claude Code)
    - `tui` — starts `ttyd` serving the agent TUI directly in a restart loop on the same port
    - `tmux` — creates a tmux session (`opencode`) running the TUI in a restart loop, then starts `ttyd` serving `tmux attach` on the same port. Browser opens a full xterm.js terminal with tmux; `docker exec` can also attach to the same session.

**OpenCode-specific steps:**

- **Config generation** — `envsubst` on `opencode.json.template` → `opencode.json`
- **LLM gateway health check** — If `OPENCODE_MODEL_FALLBACK` is set, probes `LLM_BASE_URL/models`. On failure, switches `OPENCODE_MODEL` to the fallback and disables the prefill proxy.
- **Auth setup** — Writes `auth.json` with `LLM_API_KEY` for anthropic/llm providers
- **Host auth merge** — If the host's `auth.json` is mounted (Copilot tokens etc.), merges new providers into the container's `auth.json` without overwriting existing entries
- **Plugin install** — `npm install` in config dir if `package.json` exists
- **Prefill proxy** — Launches `prefill-proxy.mjs` on `127.0.0.1:18080` (if `PREFILL_PROXY=true`) and warms up the upstream TLS connection
- **Model cache refresh** — Runs `opencode models --refresh` in the background to avoid stale model cache errors

**Claude Code-specific steps:**

- **MCP config** — Copies `claude-code.mcp.json.template` → `/opt/opencode/claude-code-mcp.json` and passes it via `--mcp-config`
- **Settings** — Writes `/root/.claude/settings.json` with pre-approved tool permissions (`Bash(*)`, `Read(*)`, `Write(*)`, `Edit(*)`, `mcp__*`)
- **Auth mapping** — Uses `ANTHROPIC_API_KEY` directly; falls back to `LLM_API_KEY`. Maps `LLM_BASE_URL` → `ANTHROPIC_BASE_URL` if `ANTHROPIC_BASE_URL` is not set
- **Onboarding pre-seed** — Writes `/root/.claude/.config.json` to skip the setup wizard, API key approval prompt, and workspace trust dialog

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

**Builder stage** — `node:22-bookworm-slim` with build tools. Installs `opencode-ai` (version set by `OPENCODE_VERSION` build arg, default `latest`), `@anthropic-ai/claude-code` (version set by `CLAUDE_CODE_VERSION` build arg, default `latest`), provider SDKs (`@ai-sdk/openai-compatible`, `@ai-sdk/groq`, `@openrouter/ai-sdk-provider`), and MCP servers globally.

**Runtime stage** — `node:22-bookworm-slim` (no build tools). Adds `git`, `curl`, `jq`, `ripgrep`, `openssh-client`, `unzip`, `tini` (PID 1), `tmux` (terminal multiplexer for tmux mode), Docker CLI, Bun, `python3` (required by the cartography skill), and `ttyd` (web terminal for `OPENCODE_MODE=tui` and `tmux`). Copies `node_modules` from builder and re-creates bin symlinks — both `opencode` and `claude` (Claude Code) are available at `/usr/local/bin/`. MCP servers start instantly with no registry checks.

</details>

<details>
<summary><strong>Internals: Volumes Reference</strong></summary>

| Mount | Purpose |
|-------|---------|
| `/workspace` | Project source code |
| `/root/.local/share/opencode` | OpenCode data, auth, database |
| `/root/.claude` | Claude Code session data, settings (when `OPENCODE_APP=claude-code`) |
| `/root/.config/opencode/memory` | MCP memory persistence (both agents) |
| `/root/.ssh` | SSH keys for git (ro) |
| `/root/.gitconfig` | Git config (ro) |
| `/root/.git-credentials` | Git credentials (ro) |
| `/root/.config/github-copilot` | GitHub Copilot auth reuse from host (ro) |
| `/opt/opencode/host-auth.json` | Host auth.json for provider merge at startup (OpenCode only, ro) |
| `/var/run/docker.sock` | Docker socket for MCP containers |
| `/certs/ca-bundle.pem` | CA certificate (ro) |

</details>

<details>
<summary><strong>Internals: Project Structure</strong></summary>

```
├── Dockerfile                          # Multi-stage build (installs both opencode-ai and @anthropic-ai/claude-code)
├── docker-compose.yml                  # Base service definition
├── docker-compose.override.yml.example # Template for your repos (includes Claude Code example)
├── docker-compose.override.yml         # Your repo services (gitignored)
├── .dockerignore                       # Docker build context exclusions
├── .gitignore                          # Git ignore rules
├── .env.example / .env                 # Config template / your secrets (gitignored)
├── entrypoint.sh                       # Container startup script (handles both agents)
├── opencode-web.sh                     # Host CLI wrapper
├── opencode.json.template              # OpenCode config template
├── claude-code.mcp.json.template       # Claude Code MCP server config template
├── tmux.conf                           # tmux configuration (TUI mode)
├── agent-monitor.sh                    # Agent activity monitor for tmux pane (OpenCode only)
├── agent-monitor-toggle.sh             # Toggle agent monitor pane on/off
├── agent-status.sh                     # tmux status bar subagent indicator (OpenCode only)
├── session-status.sh                   # tmux status bar: model, branch, context size (OpenCode)
├── session-status-claude.sh            # tmux status bar: simplified for Claude Code
├── prefill-proxy.mjs                   # LLM proxy (strips prefill, OpenCode only)
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
