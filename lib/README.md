# lib/

Bash modules sourced by `entrypoint.sh` at container startup. Every file here is sourced (not executed), so they define functions and set variables — they do not run code at `source` time except where noted.

See **Boot Flow** in `AGENTS.md` for the order in which these are sourced and what each phase does.

| File | Purpose |
|------|---------|
| `env.sh` | Loads `.env`; deprecation shim maps old `OPENCODE_*` shared vars to `CODEBOX_*` with a warning |
| `config.sh` | Config generation for all three agents; writes `opencode.json`, Claude Code `settings.json` + MCP config, and Pi `models.json`/`settings.json`/`mcp-servers.json`; handles auth and env-var mappings |
| `ca-cert.sh` | Installs the corporate CA bundle (`CA_CERT_PATH`) into the system trust store |
| `tls.sh` | Generates a self-signed TLS cert for ttyd (used in `tui` and `tmux` modes) |
| `plugins.sh` | Installs `oh-my-opencode-slim` from the npm cache baked into the image (OpenCode only) |
| `system-checks.sh` | Docker socket check, `git safe.directory`, workspace symlink, git credential/work config validation |
| `proxy.sh` | Defines `_start_proxy` and `_cleanup`; `_start_proxy` launches `proxy/prefill-proxy.mjs` (OpenCode only) |
| `runtime.sh` | Resolves `APP_BIN`, prints startup banner, initializes theme and browser tab title |
| `modes.sh` | Enters the `web`/`tui`/`tmux` restart loop — the last thing sourced; **does not return** |

Two subdirectories here are **not** sourced — they hold code that other
programmes execute, and they live under `lib/` to inherit its bind mount:

| Path | Purpose |
|------|---------|
| `guard-bin/docker` | `PATH` shim in front of the real Docker CLI; refuses commands that would stop, remove, or recreate this container or a Compose sibling. Installed by `docker-guard.sh` at boot phase 3b |
| `pi-ext/*.ts` | Pi extensions, loaded by `pi` itself via `settings.json`'s `extensions` array (written by `config.sh:_pi_extensions`). `codebox-guard.ts` protects credential paths and blocks self-destructive `docker`; `codebox-mcp.ts` is an MCP stdio client, since Pi ships none. Test with `scripts/verify-pi-extensions.sh` |

These files are bind-mounted in `docker-compose.yml` (`./lib:/opt/opencode/lib:ro`), so edits on the host take effect after `./codebox.sh restart codebox` without a rebuild. That mount is also why `guard-bin/` and `pi-ext/` live here rather than in top-level directories of their own: `docker-compose.override.yml` services use `volumes: !override`, so anything not already re-listed per service would silently run the image-baked copy.
