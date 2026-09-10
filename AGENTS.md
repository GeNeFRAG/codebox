# Project Context

This repo is **CodeBox** — a Docker wrapper for [OpenCode](https://github.com/opencode-ai/opencode), [Claude Code](https://github.com/anthropics/claude-code), [Pi](https://pi.dev). It does not contain the agent applications themselves — it packages them into a container with MCP servers, a prefill proxy, and browser-accessible UI modes (web, tui, tmux).

## Key Files

| File | What it configures |
|------|--------------------|
| `entrypoint.sh` | Container startup orchestrator — sources all `lib/` scripts in order |
| `lib/env.sh` | Loads `.env` file; warns about non-reloadable variables; deprecation shim for old `OPENCODE_*` shared vars; aliases credential names for plugin-supplied MCP servers (`JIRA_TOKEN` → `JIRA_PERSONAL_TOKEN`, `CONFLUENCE_TOKEN` → `CONFLUENCE_PERSONAL_TOKEN`, `GRAFANA_API_KEY` → `GRAFANA_TOKEN`) |
| `lib/config.sh` | Config generation for all three agents (opencode, claude-code, pi), auth.json writing, host-auth merging; also merges the TUI theme into `tui.json` (opencode.json's own `theme` key is migrated away and ignored after first boot) and applies the `OPENCODE_ENABLED_PROVIDERS` allowlist to opencode.json |
| `lib/ca-cert.sh` | Corporate CA certificate installation into system store |
| `lib/plugins.sh` | OpenCode npm plugin installation (oh-my-opencode-slim) |
| `lib/system-checks.sh` | Docker socket check, git safe.directory, workspace symlink, git credentials/work config validation |
| `lib/proxy.sh` | Prefill proxy start/stop helpers (OpenCode only) |
| `lib/runtime.sh` | Binary resolution (`APP_BIN`), startup banner, theme initialization, browser tab title derivation |
| `lib/modes.sh` | Mode launch: `web` / `tui` / `tmux` restart loops |
| `templates/opencode.json.template` | OpenCode config — MCP servers, permissions, provider endpoints. Its `provider.llm.models` block is only a readable **snapshot**: `lib/config.sh` overwrites it from `templates/model-catalog.json` on every boot |
| `templates/model-catalog.json` | **Single source of truth** for gateway model limits/pricing/protocol. Limits/pricing are injected into *both* opencode (`.provider.llm.models`) and Pi (`~/.pi/agent/models.json`); the routing fields (`api`, `thinkingLevelMap`, `compat`) are **Pi-only** — opencode has no equivalent. Pins Claude models to `anthropic-messages` and marks `max` thinking unsupported on Azure GPT-5.x. Verify with `scripts/verify-model-catalog.sh` |
| `templates/claude-code.mcp.json.template` | Nothing at runtime — reference manifest that `scripts/verify-mcp-sync.sh` diffs against `templates/mcp-servers/` and `opencode.json.template` |
| `scripts/verify-model-catalog.sh` | Validates `model-catalog.json`, diffs it against the `opencode.json.template` snapshot, asserts the Claude→`anthropic-messages` invariant, and (when `LLM_BASE_URL`/`LLM_API_KEY` are set) cross-checks every model ID and limit against the live gateway |
| `templates/mcp-servers/*.json` | Individual MCP server definitions, assembled at runtime by `_generate_mcp_server_config` into `/root/.claude/claude-code-mcp.json` (Claude Code) and `/root/.pi/agent/mcp-servers.json` (Pi, consumed by `lib/pi-ext/codebox-mcp.ts`); gated by `CODEBOX_MCP_*` env vars |
| `lib/playwright.sh` | On-demand Playwright browser download at startup, gated by `CODEBOX_PLAYWRIGHT` (not baked into the image) |
| `skills/*/SKILL.md` | Agent skills baked to `/root/.agents/skills/` — currently `atl` (Jira/Confluence/Zephyr). Cheaper than the equivalent MCP server (prompt text, not 20+ tool schemas), so prefer a skill where one exists. Mounted **one line per skill** in the dev block, never as a whole directory: `/root/.agents/skills/` also holds `agent-browser` and `simplify` from `npx skills add`, which a directory mount would shadow away |
| `lib/pi-ext/codebox-guard.ts` | Pi extension: refuses `write`/`edit` and file-clobbering `bash` against `.env` and other credential/generated-config paths, and blocks self-destructive `docker` by shelling out to `lib/guard-bin/docker` in dry-run mode (one set of rules, not a second copy). Pi has no permission popups of its own |
| `lib/pi-ext/codebox-mcp.ts` | Pi extension: MCP stdio client, Pi's only route to the MCP fleet (it ships no MCP client by design). Reads the assembled `mcp-servers.json` that `lib/config.sh` writes, registers `mcp__<server>__<tool>` tools from a disk cache, discovers uncached servers in the background, spawns a server on first use |
| `lib/pi-ext/subagent/` | Vendored Pi public subagent extension: runs named, model-pinned Pi subprocesses with isolated contexts. `templates/pi-subagents/` supplies first-boot `scout` (Haiku), `planner`/`reviewer`/`worker` (Sonnet), and workflow prompt defaults; child processes cannot recursively dispatch subagents |
| `scripts/verify-pi-extensions.sh` | Loads all CodeBox Pi extensions through pi's own jiti loader; asserts subagent child recursion is blocked and defaults reference catalog models, ~45 guard block/allow verdicts, and a live MCP discover-call-cache round trip. Run in-container after touching `lib/pi-ext/` or `lib/guard-bin/docker`; `SKIP_MCP=1` skips the spawning half |
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

- Environment variables use the `CODEBOX_` prefix for shared settings (app, mode, port, theme, etc.). OpenCode-specific vars (`OPENCODE_MODEL`, `OPENCODE_MODEL_FALLBACK`, `OPENCODE_TUI_THEME`) keep the `OPENCODE_` prefix; Pi-specific vars (`PI_MODEL`, `PI_THINKING`, `PI_API`, `PI_PROJECT_TRUST`, `PI_OFFLINE`) keep the `PI_` prefix. A deprecation shim in `lib/env.sh` maps old `OPENCODE_*` shared vars to `CODEBOX_*` with a warning.
- The split is by **owner, not by agent**: `PI_*`/`OPENCODE_*` are settings the agent itself defines and reads, so inventing new names there risks colliding with a future upstream variable. A CodeBox feature that happens to apply to one agent only keeps the `CODEBOX_` prefix and names the agent in the middle — `CODEBOX_PI_GUARD`, `CODEBOX_PI_SUBAGENTS`, `CODEBOX_PI_MCP`, `CODEBOX_PI_MCP_SERVERS` (see `lib/pi-ext/`).
- Environment variables are documented in `.env.example` and substituted into configs by `lib/config.sh` via `envsubst`.
- Most `CODEBOX_*` vars are read at **runtime** by `entrypoint.sh`/`lib/`, so a `restart` picks them up. `CODEBOX_VERSION` is a Docker **build arg** declared as `ARG` in the `Dockerfile` and passed through `build.args` in `docker-compose.yml`; it requires `./codebox.sh rebuild`. Keep the two groups distinguishable in `.env.example`.
- Prefer a **runtime** var over a build arg for anything optional. A build arg forks the image (one variant per value), which defeats per-service configuration since all services share one `build:` block. `CODEBOX_PLAYWRIGHT` is the reference case: the image bakes only the cheap, universal part (Chrome's system libraries via `playwright install-deps`) and `lib/playwright.sh` fetches the expensive per-service part (browser binaries) at startup into a per-service named volume.
- The `Dockerfile` is ordered cheap-and-stable → expensive-and-stable → churny, with an explicit **churn zone** marker near the bottom. Layers below the marker re-run on most builds and must stay trivial. In particular `COPY --from=atl-builder` must stay there: `codebox.sh:_clone_atl()` re-clones into a fresh temp dir every invocation, so the `atl` build context digest changes on every build and invalidates everything beneath that `COPY`.
- Shell scripts target `bash` and run inside the container at `/opt/opencode/`. The `entrypoint.sh` is the only script executed directly; everything else is sourced.
- The `oh-my-opencode-slim` plugin is an npm package baked into the image. Its config template lives at `templates/oh-my-opencode-slim.json.template`; the active config lives at `/root/.config/opencode/oh-my-opencode-slim.json`.
- The three agent binaries are available in the container at `/usr/local/bin/`: `opencode`, `claude` (Claude Code), and `pi` (Pi). `CODEBOX_APP` selects which one runs.
- **The container can reach the host daemon, so it can kill itself.** `/var/run/docker.sock` is mounted for MCP sibling containers, which also means a `stop`/`rm`/`down` issued in here takes down the container running the command. Three layers guard it, all **allowlists** — a blocklist already failed open once by omitting `stop` and `prune`:
  - `codebox.sh` permits only `logs`/`shell`/`status`/`urls`/`version` when `/run/codebox-container`, `/.dockerenv`, or `/run/.containerenv` is present.
  - `lib/guard-bin/docker` shims the CLI and refuses container-destroying verbs aimed at this container or a Compose-managed sibling, `docker compose` mutations, and host-wide prunes. This is the **enforcement** layer: it sits on `PATH` in front of the real CLI for every shell any agent spawns.
  - `lib/pi-ext/codebox-guard.ts` (Pi only) intercepts the `bash` tool call *before* it runs and asks the shim for its verdict in dry-run mode. It adds no rules of its own — it catches `/usr/local/bin/docker …` (the shim's own bypass, which a blocked model reaches for next) and turns the refusal into a tool error the model reads, rather than stderr it has to notice.

  All honour `CODEBOX_ALLOW_IN_CONTAINER=true`. Use `CODEBOX_GUARD_DRYRUN=1 docker …` to print the shim's verdict without running anything — dry-run is checked **before** the bypass, so the probe can never execute the command it is asking about.
- **Pi ships no built-in MCP client, permission popups, or subagent workflow**, by design (pi's `docs/usage.md`: "you can build or install those workflows as extensions"). CodeBox supplies all three from `lib/pi-ext/`, wired in through `settings.json`'s `extensions` array by `_pi_extensions()`. `CODEBOX_PI_SUBAGENTS` defaults on and seeds editable definitions/prompts from `templates/pi-subagents/` only if absent; delegates inherit guard/MCP but not the dispatcher itself. The extensions live under `lib/` rather than a directory of their own so they inherit the existing `./lib:/opt/opencode/lib:ro` dev mount — every service already carries it, including the `docker-compose.override.yml` ones that use `volumes: !override` and would otherwise silently run image-baked copies. Verify with `scripts/verify-pi-extensions.sh`.
- When testing whether a container is one of ours, match `com.docker.compose.container-number`, **not** `com.docker.compose.project` alone. `docker compose build` bakes the project/service/version labels into the *image*, so any sibling started with plain `docker run` from a CodeBox image inherits them — `container-number` is applied by Compose at create time and is never inherited. `bin/mcp-run` containers additionally carry `codebox.role=mcp` and are always exempt so mcp-run can reap them.

## Boot Flow

`entrypoint.sh` sources `lib/` scripts in this order. Each phase is numbered to match the comments in `entrypoint.sh`:

1. **Load env** — `lib/env.sh`: reads `.env`, applies deprecation shims (`OPENCODE_*` → `CODEBOX_*`).
2. **Agent selection** — inlined: `CODEBOX_APP` (default: `opencode`; also `claude-code`, `pi`) sets `APP_TITLE_PREFIX` and drives all downstream branches.
3. **CA cert path** — inlined: runs `docker inspect` to resolve `CA_CERT_PATH` to the real host path so MCP sibling containers can mount it.
3b. **Docker guard** — `lib/docker-guard.sh:_install_docker_guard`: prepends `lib/guard-bin/` to `PATH` so `docker` resolves to the guard shim, exports `CODEBOX_COMPOSE_PROJECT`, and writes `/run/codebox-container`. Runs before any user-reachable shell exists; read-only docker calls in later phases pass through untouched.
4. **Cleanup trap** — `lib/proxy.sh` sourced here for `_cleanup`; SIGTERM/SIGINT kill the background proxy process.
5. **Config generation** — `lib/config.sh`: dispatches to `_configure_opencode`, `_generate_claude_code_config`, or `_configure_pi` based on `CODEBOX_APP`. All three gate MCP servers on `CODEBOX_MCP_<NAME>` from one shared server list (`_MCP_ALL_SERVERS`); claude-code and pi share the assembler `_generate_mcp_server_config`. `_configure_pi` additionally seeds default subagent definitions/prompts and resolves `lib/pi-ext/*.ts` into settings.json's `extensions` array (`_pi_extensions`) — Pi's equivalent of the other two agents' MCP, safety, and delegation configuration.
6. **Corporate CA cert** — `lib/ca-cert.sh`: installs CA bundle into the system trust store (no-op if `CA_CERT_PATH` is unset).
7. **TLS cert for ttyd** — `lib/tls.sh`: generates a self-signed cert for the ttyd web terminal (tui/tmux modes only).
8. **OpenCode plugins** — `lib/plugins.sh`: skips `npm install` when the baked `.deps-fingerprint` still matches `package.json`; re-runs only if the fingerprint is stale or `node_modules` was wiped (OpenCode only).
9. **System checks** — `lib/system-checks.sh`: Docker socket check, `git safe.directory`, workspace symlink, git credential validation.
9b. **Playwright browsers** — `lib/playwright.sh:_install_playwright`: if `CODEBOX_PLAYWRIGHT` is `true` or `shell`, runs `playwright install` into the per-service volume at `/root/.cache/ms-playwright`. No-ops in ~0.4s once populated; backgrounds the first-run download so the healthcheck's 15s `start_period` isn't at risk.
10. **Prefill proxy** — `lib/proxy.sh:_start_proxy`: starts the Node.js proxy on `127.0.0.1:18080` (OpenCode + `PREFILL_PROXY=true` only; **default off** since the gateway now accepts assistant prefill — see `proxy/README.md`).
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
| Edit a Pi extension (`lib/pi-ext/*.ts`) | `./scripts/verify-pi-extensions.sh` in-container, then `/reload` in Pi (no restart needed — pi hot-reloads extensions) |
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
2. **Claude Code + Pi** — add a `<server-name>.json` file to `templates/mcp-servers/` containing the server's config object (e.g. `{"my_server": {"type": "stdio", ...}}`). Add the server name to `_MCP_ALL_SERVERS` in `lib/config.sh`. Both agents assemble that fragment through `_generate_mcp_server_config`, so one fragment covers both, gated by `CODEBOX_MCP_<NAME>` (default: enabled). Pi reaches it through `lib/pi-ext/codebox-mcp.ts`, which needs no change — it discovers whatever tools the server reports.
3. If the server needs env vars (API keys, URLs), add them to `.env.example` with a descriptive comment.
4. If you added a new `$VAR` to a template, add it to the `envsubst` call in `lib/config.sh` for the relevant config function (`_generate_config` or `_ENVSUBST_VARS_MCP`).
5. Apply: `./codebox.sh restart codebox` (templates are bind-mounted; no rebuild needed). Pi caches each server's tool list in `/root/.pi/agent/mcp-tools-cache.json`, keyed by a hash of that server's config, so a changed fragment re-discovers itself on the next start.

> To add a server for **only one agent**, edit only that agent's template. `templates/mcp-servers/` is now shared by two of the three.

> **Every enabled server's tool schemas ship on every request.** Ten servers is 100+ tools; `mcp-atlassian` and the GitHub servers dominate. Pi's footer shows the live count. Trim with `CODEBOX_MCP_<NAME>=false` (all agents) or `CODEBOX_PI_MCP_SERVERS` (Pi only), and prefer a skill where one exists — `skills/atl` does the Jira/Confluence job for a fraction of the `mcp-atlassian` context.

## Recipe: Add or Change a Model

Model limits, pricing and wire protocol live in **one** file: `templates/model-catalog.json`. Never hardcode them in `lib/config.sh` or edit `provider.llm.models` in `opencode.json.template` by hand — the latter is a snapshot that `_generate_config()` overwrites from the catalog on every boot.

1. Add or edit the entry in `templates/model-catalog.json` (`id`, `name`, `context`, `output`, `reasoning`, `vision`, `cost`, optional `api` / `thinkingLevelMap`).
2. Validate: `./scripts/verify-model-catalog.sh`. With `LLM_BASE_URL`/`LLM_API_KEY` exported it also cross-checks every ID and limit against the live gateway — this is how the phantom `gpt-5.1` entry was caught.
3. Re-sync the `opencode.json.template` snapshot if the verify script reports drift.
4. Apply: `./codebox.sh restart <svc>`.

### Gateway quirks the catalog exists to encode

The gateway is LiteLLM fronting Bedrock (Claude) and Azure (GPT). All four apply to **Pi only** (opencode consumes just limits/pricing from the catalog). The middle two **fail open** — HTTP 200 or no message at all, silently degraded output — which is why they are pinned in data and asserted by the verify script:

| Quirk | Consequence if unpinned | Fix in catalog |
|---|---|---|
| Claude on `openai-completions` gets `reasoning_effort` translated into `thinking.budget_tokens` | Thinking *does* stream back, but with the placeholder signature `"reasoning_content"` instead of a replayable one, and `usage.reasoning: 0` so thinking tokens are never accounted; and any request whose `max_tokens` ≤ the derived budget is rejected (HTTP 400, `max_tokens must be greater than thinking.budget_tokens`) — a trap that grows with `PI_THINKING_BUDGETS` | `"api": "anthropic-messages"` per Claude model |
| Pi only auto-enables Anthropic `cache_control` for `openrouter.ai` URLs | Prompt caching completely off; full prefix re-billed at input rate (10× `cache_read` on Opus) | `api: anthropic-messages` handles it natively; otherwise `compat.cacheControlFormat: "anthropic"` |
| Pi's `models.json` schema requires `cost.cacheWrite` | File rejected and the **whole provider silently dropped** — no models listed | `_pi_models_from_catalog()` defaults it to `0` |
| Azure GPT-5.x rejects `reasoning_effort: max` with HTTP 400 | Hard request failure at `--thinking max` | `thinkingLevelMap.max: null` → pi clamps to `xhigh` |

Measured on this gateway (`claude-haiku-4-5`, `gpt-5-nano`): `xhigh` is accepted by Azure and `max` is not; the `/v1/messages` route returns real signatures plus `usage.reasoning`, and prompt caching over it works once the cached prefix clears Bedrock's minimum (`cacheWrite` on the first call, `cacheRead` on the next). Below that minimum both stay `0` — that is the prefix being too small, not caching being off.

## Recipe: Add an Agent Role (OpenCode only)

Agent roles live in `templates/oh-my-opencode-slim.json.template` under `presets.default`. Each role defines its model, skills, and MCP servers. Claude Code does not use this system.

1. Open `templates/oh-my-opencode-slim.json.template`.
2. Copy an existing role (e.g. `orchestrator`) as a starting point.
3. Add your role key under `presets.default` with `model`, `skills`, and `mcps` fields. `model` accepts either a single ID or an array: the first entry is the primary, the rest are tried in order if it's unavailable. Retry behaviour is controlled by `fallback.enabled` and `fallback.maxRetries` at the top of the file.
4. Apply: `./codebox.sh restart codebox` (`lib/config.sh` re-copies the template into place on every start).
