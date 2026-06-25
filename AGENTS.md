# Project Context

This repo is **CodeBox** — a Docker wrapper for [OpenCode](https://github.com/opencode-ai/opencode), [Claude Code](https://github.com/anthropics/claude-code). It does not contain the agent applications themselves — it packages them into a container with MCP servers, a prefill proxy, and browser-accessible UI modes (web, tui, tmux).

## Key Files

| File | What it configures |
|------|--------------------|
| `entrypoint.sh` | Container startup orchestrator — sources all `lib/` scripts in order |
| `lib/env.sh` | Loads `.env` file; warns about non-reloadable variables; deprecation shim for old `OPENCODE_*` shared vars |
| `lib/config.sh` | Config generation for both agents (opencode, claude-code), auth.json writing, host-auth merging |
| `lib/ca-cert.sh` | Corporate CA certificate installation into system store |
| `lib/plugins.sh` | OpenCode npm plugin installation (oh-my-opencode-slim) |
| `lib/system-checks.sh` | Docker socket check, git safe.directory, workspace symlink, git credentials/work config validation |
| `lib/proxy.sh` | Prefill proxy start/stop helpers (OpenCode only) |
| `lib/runtime.sh` | Binary resolution (`APP_BIN`), startup banner, model cache refresh, theme initialization, browser tab title derivation |
| `lib/modes.sh` | Mode launch: `web` / `tui` / `tmux` restart loops |
| `templates/opencode.json.template` | OpenCode config — MCP servers, permissions, provider endpoints |
| `templates/claude-code.mcp.json.template` | Claude Code MCP config output path (assembled at runtime from `templates/mcp-servers/`) |
| `templates/mcp-servers/*.json` | Individual MCP server definitions assembled at runtime into Claude Code MCP config; gated by `CODEBOX_MCP_*` env vars |
| `lib/context.sh` | Context window optimization — prunes BMad skills and GSD system from `/workspace/.claude/` at startup, restores on shutdown (Claude Code only) |
| `templates/oh-my-opencode-slim.json.template` | Agent preset — which model/skills/MCPs each agent role uses + fallback chains |
| `proxy/prefill-proxy.mjs` | Local HTTP proxy that strips assistant prefill messages before forwarding to the LLM (OpenCode only) |
| `docker-compose.yml` | Base service definition (volumes, healthcheck, resource limits) |
| `codebox.sh` | Host CLI wrapper for docker compose operations |
| `tmux/tmux.conf` | tmux keybindings and status bar config (tmux mode only) |
| `tmux/tmux-theme-dark.conf` / `tmux/tmux-theme-light.conf` | Dark/light theme overrides for tmux status bar |
| `tmux/tmux-theme-toggle.sh` | Runtime dark/light theme toggle (bound to `Option-t`) |
| `tmux/shell-pane-toggle.sh` | Toggle zsh shell pane on/off (bound to `Option-m`); uses `@shell_pane` user option for identification |
| `tmux/tmux-wrapper.sh` | Session manager for tmux mode — creates/attaches persistent session, propagates env to split panes via tmux globals, re-resolves binary if stale |

## Conventions

- Environment variables use the `CODEBOX_` prefix for shared settings (app, mode, port, theme, etc.). OpenCode-specific vars (`OPENCODE_MODEL`, `OPENCODE_MODEL_FALLBACK`, `OPENCODE_TUI_THEME`) keep the `OPENCODE_` prefix. A deprecation shim in `lib/env.sh` maps old `OPENCODE_*` shared vars to `CODEBOX_*` with a warning.
- Environment variables are documented in `.env.example` and substituted into configs by `lib/config.sh` via `envsubst`.
- Shell scripts target `bash` and run inside the container at `/opt/opencode/`. The `entrypoint.sh` is the only script executed directly; everything else is sourced.
- The `oh-my-opencode-slim` plugin is an npm package baked into the image. Its config template lives at `templates/oh-my-opencode-slim.json.template`; the active config lives at `/root/.config/opencode/oh-my-opencode-slim.json`.
- The two agent binaries are available in the container at `/usr/local/bin/`: `opencode` and `claude` (Claude Code). `CODEBOX_APP` selects which one runs.

## Boot Flow

`entrypoint.sh` sources `lib/` scripts in this order. Each phase is numbered to match the comments in `entrypoint.sh`:

1. **Load env** — `lib/env.sh`: reads `.env`, applies deprecation shims (`OPENCODE_*` → `CODEBOX_*`).
2. **Agent selection** — inlined: `CODEBOX_APP` (default: `opencode`) sets `APP_TITLE_PREFIX` and drives all downstream branches.
3. **CA cert path** — inlined: runs `docker inspect` to resolve `CA_CERT_PATH` to the real host path so MCP sibling containers can mount it.
4. **Cleanup trap** — `lib/proxy.sh` sourced here for `_cleanup`; SIGTERM/SIGINT kill the background proxy process.
5. **Config generation** — `lib/config.sh`: dispatches to `_configure_opencode` or `_generate_claude_code_config` based on `CODEBOX_APP`.
6. **Corporate CA cert** — `lib/ca-cert.sh`: installs CA bundle into the system trust store (no-op if `CA_CERT_PATH` is unset).
7. **TLS cert for ttyd** — `lib/tls.sh`: generates a self-signed cert for the ttyd web terminal (tui/tmux modes only).
8. **OpenCode plugins** — `lib/plugins.sh`: installs `oh-my-opencode-slim` from the npm cache baked into the image (OpenCode only).
9. **System checks** — `lib/system-checks.sh`: Docker socket check, `git safe.directory`, workspace symlink, git credential validation.
9b. **Context optimization** — `lib/context.sh:_optimize_claude_code_context`: if `CODEBOX_SKILLS_BMAD=false` or `CODEBOX_GSD=false`, backs up and removes unused skill/agent files from `/workspace/.claude/`. Restored by `_restore_claude_context()` on graceful shutdown (Claude Code only).
10. **Prefill proxy** — `lib/proxy.sh:_start_proxy`: starts the Node.js proxy on `127.0.0.1:18080` (OpenCode + `PREFILL_PROXY_ENABLED=true` only).
11. **Runtime** — `lib/runtime.sh`: resolves `APP_BIN`, prints the startup banner, refreshes model cache, sets theme and browser tab title.
12. **Mode launch** — `lib/modes.sh`: enters the `web`/`tui`/`tmux` restart loop for the chosen `CODEBOX_MODE`. **Does not return.**

## Dev Workflow

`lib/`, `templates/`, `proxy/`, `tmux/`, `entrypoint.sh`, and `bin/mcp-run` are bind-mounted into the running container (see `docker-compose.yml` lines 103–116). Edits on the host take effect on the **next container restart** — no image rebuild needed for most changes.

| Task | Command |
|------|---------|
| Edit a `lib/*.sh` script or template | `./codebox.sh restart codebox` |
| Reload `.env` changes | `./codebox.sh restart codebox` |
| Follow startup logs | `./codebox.sh logs codebox` |
| Open a shell in the running container | `./codebox.sh shell codebox` |
| Rebuild the image (Dockerfile change, new npm package) | `./codebox.sh rebuild codebox` |
| Pull latest upstream agent + full rebuild | `./codebox.sh nuke codebox` |
| Inspect generated configs in-container | `./codebox.sh shell codebox` then `cat /root/.config/opencode/opencode.json` or `ls /root/.claude/` |

> `restart` does `docker compose up -d --force-recreate` — fast, no build. Use `rebuild` only when the *image* must change.

## Recipe: Add an MCP Server

MCP servers come in two forms:
- **Stdio** (Node process inside the container) — add to templates with `"type": "stdio"` and a `npx`/`node` command.
- **Docker-socket** (sibling container via `bin/mcp-run`) — wrap `docker run` args in `bin/mcp-run <name>` as the command; requires `/var/run/docker.sock`.

Steps to wire a new server into all three agents:

1. **OpenCode** — edit `templates/opencode.json.template`, add an entry under `mcpServers`.
2. **Claude Code** — add a `<server-name>.json` file to `templates/mcp-servers/` containing the server's config object (e.g. `{"my_server": {"type": "stdio", ...}}`). Add the server name to the `all_servers` list in `_generate_claude_code_mcp_config()` in `lib/config.sh`. The server is automatically gated by `CODEBOX_MCP_<NAME>` (default: enabled).
4. If the server needs env vars (API keys, URLs), add them to `.env.example` with a descriptive comment.
5. If you added a new `$VAR` to a template, add it to the `envsubst` call in `lib/config.sh` for the relevant config function (`_generate_config` or `_generate_claude_code_config`).
6. Apply: `./codebox.sh restart codebox` (templates are bind-mounted; no rebuild needed).

> To add a server for **only one agent**, edit only that agent's template.

## Recipe: Add an Agent Role (OpenCode only)

Agent roles live in `templates/oh-my-opencode-slim.json.template` under `presets.default`. Each role defines its model, skills, and MCP servers. Claude Code does not use this system.

1. Open `templates/oh-my-opencode-slim.json.template`.
2. Copy an existing role (e.g. `orchestrator`) as a starting point.
3. Add your role key under `presets.default` with `model`, `skills`, and `mcps` fields.
4. Optionally add a fallback chain under `fallback.chains.<your-role>` (list of model IDs tried in order if the primary times out).
5. Apply: `./codebox.sh restart codebox` (template is bind-mounted).
