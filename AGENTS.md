# Project Context

This repo is **CodeBox** — a Docker wrapper for [OpenCode](https://github.com/opencode-ai/opencode), [Claude Code](https://github.com/anthropics/claude-code). It does not contain the agent applications themselves — it packages them into a container with MCP servers, a prefill proxy, and browser-accessible UI modes (web, tui, tmux).

## Key Files

| File | What it configures |
|------|--------------------|
| `entrypoint.sh` | Container startup orchestrator — sources all `lib/` scripts in order |
| `lib/env.sh` | Loads `.env` file; warns about non-reloadable variables; deprecation shim for old `OPENCODE_*` shared vars; aliases credential names for plugin-supplied MCP servers (`JIRA_TOKEN` → `JIRA_PERSONAL_TOKEN`, `CONFLUENCE_TOKEN` → `CONFLUENCE_PERSONAL_TOKEN`, `GRAFANA_API_KEY` → `GRAFANA_TOKEN`) |
| `lib/config.sh` | Config generation for both agents (opencode, claude-code), auth.json writing, host-auth merging |
| `lib/ca-cert.sh` | Corporate CA certificate installation into system store |
| `lib/plugins.sh` | OpenCode npm plugin installation (oh-my-opencode-slim) |
| `lib/system-checks.sh` | Docker socket check, git safe.directory, workspace symlink, git credentials/work config validation |
| `lib/proxy.sh` | Prefill proxy start/stop helpers (OpenCode only) |
| `lib/runtime.sh` | Binary resolution (`APP_BIN`), startup banner, theme initialization, browser tab title derivation |
| `lib/modes.sh` | Mode launch: `web` / `tui` / `tmux` restart loops |
| `templates/opencode.json.template` | OpenCode config — MCP servers, permissions, provider endpoints |
| `templates/claude-code.mcp.json.template` | Nothing at runtime — reference manifest that `scripts/verify-mcp-sync.sh` diffs against `templates/mcp-servers/` and `opencode.json.template` |
| `templates/mcp-servers/*.json` | Individual MCP server definitions, assembled at runtime into `/root/.claude/claude-code-mcp.json`; gated by `CODEBOX_MCP_*` env vars |
| `lib/context.sh` | Context window optimization — prunes BMad skills and GSD system from `/workspace/.claude/` at startup, restores on shutdown (Claude Code only) |
| `lib/playwright.sh` | On-demand Playwright browser download at startup, gated by `CODEBOX_PLAYWRIGHT` (not baked into the image) |
| `lib/docker-guard.sh` | Installs the `docker` guard shim on `PATH` (and in `/root/.{bashrc,zshrc}`), resolves `CODEBOX_COMPOSE_PROJECT`, writes the `/run/codebox-container` marker |
| `lib/guard-bin/docker` | `PATH` shim in front of `/usr/local/bin/docker` — refuses commands that would stop/remove/recreate this container or its Compose siblings |
| `templates/oh-my-opencode-slim.json.template` | Agent preset — which model/skills/MCPs each agent role uses; each role's `model` accepts an array `[primary, ...fallbacks]`. Copied to `/root/.config/opencode/oh-my-opencode-slim.json` at container startup by `lib/config.sh` |
| `proxy/prefill-proxy.mjs` | Local HTTP proxy that strips assistant prefill messages before forwarding to the LLM (OpenCode only) |
| `docker-compose.yml` | Base service definition (volumes, healthcheck, resource limits) |
| `codebox.sh` | Host CLI wrapper for docker compose operations; refuses everything except `logs`/`shell`/`status`/`urls`/`version` when run inside a container |
| `tmux/tmux.conf` | tmux keybindings and status bar config (tmux mode only) |
| `tmux/tmux-theme-dark.conf` / `tmux/tmux-theme-light.conf` | Dark/light theme overrides for tmux status bar |
| `tmux/tmux-theme-toggle.sh` | Runtime dark/light theme toggle (bound to `Option-t`) |
| `tmux/shell-pane-toggle.sh` | Toggle zsh shell pane on/off (bound to `Option-m`); uses `@shell_pane` user option for identification |
| `tmux/tmux-wrapper.sh` | Session manager for tmux mode — creates/attaches persistent session, propagates env to split panes via tmux globals, re-resolves binary if stale |

## Conventions

- Environment variables use the `CODEBOX_` prefix for shared settings (app, mode, port, theme, etc.). OpenCode-specific vars (`OPENCODE_MODEL`, `OPENCODE_MODEL_FALLBACK`, `OPENCODE_TUI_THEME`) keep the `OPENCODE_` prefix. A deprecation shim in `lib/env.sh` maps old `OPENCODE_*` shared vars to `CODEBOX_*` with a warning.
- Environment variables are documented in `.env.example` and substituted into configs by `lib/config.sh` via `envsubst`.
- Most `CODEBOX_*` vars are read at **runtime** by `entrypoint.sh`/`lib/`, so a `restart` picks them up. `CODEBOX_VERSION` is a Docker **build arg** declared as `ARG` in the `Dockerfile` and passed through `build.args` in `docker-compose.yml`; it requires `./codebox.sh rebuild`. Keep the two groups distinguishable in `.env.example`.
- Prefer a **runtime** var over a build arg for anything optional. A build arg forks the image (one variant per value), which defeats per-service configuration since all services share one `build:` block. `CODEBOX_PLAYWRIGHT` is the reference case: the image bakes only the cheap, universal part (Chrome's system libraries via `playwright install-deps`) and `lib/playwright.sh` fetches the expensive per-service part (browser binaries) at startup into a per-service named volume.
- The `Dockerfile` is ordered cheap-and-stable → expensive-and-stable → churny, with an explicit **churn zone** marker near the bottom. Layers below the marker re-run on most builds and must stay trivial. In particular `COPY --from=atl-builder` must stay there: `codebox.sh:_clone_atl()` re-clones into a fresh temp dir every invocation, so the `atl` build context digest changes on every build and invalidates everything beneath that `COPY`.
- Shell scripts target `bash` and run inside the container at `/opt/opencode/`. The `entrypoint.sh` is the only script executed directly; everything else is sourced.
- The `oh-my-opencode-slim` plugin is an npm package baked into the image. Its config template lives at `templates/oh-my-opencode-slim.json.template`; the active config lives at `/root/.config/opencode/oh-my-opencode-slim.json`.
- The two agent binaries are available in the container at `/usr/local/bin/`: `opencode` and `claude` (Claude Code). `CODEBOX_APP` selects which one runs.
- **The container can reach the host daemon, so it can kill itself.** `/var/run/docker.sock` is mounted for MCP sibling containers, which also means a `stop`/`rm`/`down` issued in here takes down the container running the command. Two layers guard it, both **allowlists** — a blocklist already failed open once by omitting `stop` and `prune`:
  - `codebox.sh` permits only `logs`/`shell`/`status`/`urls`/`version` when `/run/codebox-container`, `/.dockerenv`, or `/run/.containerenv` is present.
  - `lib/guard-bin/docker` shims the CLI and refuses container-destroying verbs aimed at this container or a Compose-managed sibling, `docker compose` mutations, and host-wide prunes.

  Both honour `CODEBOX_ALLOW_IN_CONTAINER=true`. Use `CODEBOX_GUARD_DRYRUN=1 docker …` to print the shim's verdict without running anything.
- When testing whether a container is one of ours, match `com.docker.compose.container-number`, **not** `com.docker.compose.project` alone. `docker compose build` bakes the project/service/version labels into the *image*, so any sibling started with plain `docker run` from a CodeBox image inherits them — `container-number` is applied by Compose at create time and is never inherited. `bin/mcp-run` containers additionally carry `codebox.role=mcp` and are always exempt so mcp-run can reap them.

## Boot Flow

`entrypoint.sh` sources `lib/` scripts in this order. Each phase is numbered to match the comments in `entrypoint.sh`:

1. **Load env** — `lib/env.sh`: reads `.env`, applies deprecation shims (`OPENCODE_*` → `CODEBOX_*`).
2. **Agent selection** — inlined: `CODEBOX_APP` (default: `opencode`) sets `APP_TITLE_PREFIX` and drives all downstream branches.
3. **CA cert path** — inlined: runs `docker inspect` to resolve `CA_CERT_PATH` to the real host path so MCP sibling containers can mount it.
3b. **Docker guard** — `lib/docker-guard.sh:_install_docker_guard`: prepends `lib/guard-bin/` to `PATH` so `docker` resolves to the guard shim, exports `CODEBOX_COMPOSE_PROJECT`, and writes `/run/codebox-container`. Runs before any user-reachable shell exists; read-only docker calls in later phases pass through untouched.
4. **Cleanup trap** — `lib/proxy.sh` sourced here for `_cleanup`; SIGTERM/SIGINT kill the background proxy process.
5. **Config generation** — `lib/config.sh`: dispatches to `_configure_opencode` or `_generate_claude_code_config` based on `CODEBOX_APP`. Both paths gate MCP servers on `CODEBOX_MCP_<NAME>` from one shared server list (`_MCP_ALL_SERVERS`).
6. **Corporate CA cert** — `lib/ca-cert.sh`: installs CA bundle into the system trust store (no-op if `CA_CERT_PATH` is unset).
7. **TLS cert for ttyd** — `lib/tls.sh`: generates a self-signed cert for the ttyd web terminal (tui/tmux modes only).
8. **OpenCode plugins** — `lib/plugins.sh`: skips `npm install` when the baked `.deps-fingerprint` still matches `package.json`; re-runs only if the fingerprint is stale or `node_modules` was wiped (OpenCode only).
9. **System checks** — `lib/system-checks.sh`: Docker socket check, `git safe.directory`, workspace symlink, git credential validation.
9b. **Context optimization** — `lib/context.sh:_optimize_claude_code_context`: if `CODEBOX_SKILLS_BMAD=false` or `CODEBOX_GSD=false`, backs up and removes unused skill/agent files from `/workspace/.claude/`. Restored by `_restore_claude_context()` on graceful shutdown (Claude Code only).
9c. **Playwright browsers** — `lib/playwright.sh:_install_playwright`: if `CODEBOX_PLAYWRIGHT` is `true` or `shell`, runs `playwright install` into the per-service volume at `/root/.cache/ms-playwright`. No-ops in ~0.4s once populated; backgrounds the first-run download so the healthcheck's 15s `start_period` isn't at risk.
10. **Prefill proxy** — `lib/proxy.sh:_start_proxy`: starts the Node.js proxy on `127.0.0.1:18080` (OpenCode + `PREFILL_PROXY_ENABLED=true` only).
11. **Runtime** — `lib/runtime.sh`: resolves `APP_BIN`, prints the startup banner, sets theme and browser tab title. Does **not** prime the model cache — OpenCode refreshes that itself on boot and hourly.
12. **Mode launch** — `lib/modes.sh`: enters the `web`/`tui`/`tmux` restart loop for the chosen `CODEBOX_MODE`. **Does not return.**

## Dev Workflow

`lib/`, `templates/`, `proxy/`, `tmux/`, `entrypoint.sh`, and `bin/*` are bind-mounted into the running container (see the dev-iteration block at the end of `volumes: &codebox-volumes` in `docker-compose.yml`). Edits on the host take effect on the **next container restart** — no image rebuild needed for most changes.

> **⚠ This holds only for services that actually carry those mounts.** `docker-compose.override.yml` services use `volumes: !override`, which *replaces* the inherited list rather than merging it — so any service that does not re-list the dev mounts runs the `lib/`/`templates/` snapshot baked into the image by `COPY` (`Dockerfile`), and host edits need a full `rebuild`. This fails **silently**: `entrypoint.sh` still sources `/opt/opencode/lib/env.sh` on every restart, just an older copy. `.env` is unaffected because every override re-lists it — which is what makes the failure easy to miss.
>
> Diagnose in one command each:
> ```bash
> grep -c '^ *- \./lib:' docker-compose.override.yml   # expect 1 per service
> ./codebox.sh shell <svc>                             # then, inside:
> grep /opt/opencode/lib /proc/self/mountinfo          # no output = stale, image-baked
> ```

| Task | Command |
|------|---------|
| Edit a `lib/*.sh` script or template | `./codebox.sh restart codebox` (only if mounts present — see warning above) |
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
3. Add your role key under `presets.default` with `model`, `skills`, and `mcps` fields. `model` accepts either a single ID or an array: the first entry is the primary, the rest are tried in order if it's unavailable. Retry behaviour is controlled by `fallback.enabled` and `fallback.maxRetries` at the top of the file.
4. Apply: `./codebox.sh restart codebox` (`lib/config.sh` re-copies the template into place on every start).
