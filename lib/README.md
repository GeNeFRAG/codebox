# lib/

Bash modules sourced by `entrypoint.sh` at container startup. Every file here is sourced (not executed), so they define functions and set variables — they do not run code at `source` time except where noted.

See **Boot Flow** in `AGENTS.md` for the order in which these are sourced and what each phase does.

| File | Purpose |
|------|---------|
| `env.sh` | Loads `.env`; deprecation shim maps old `OPENCODE_*` shared vars to `CODEBOX_*` with a warning |
| `config.sh` | Config generation for all three agents; writes `opencode.json`, Claude Code `settings.json`, FlowCode `config.json`; handles auth and env-var mappings |
| `ca-cert.sh` | Installs the corporate CA bundle (`CA_CERT_PATH`) into the system trust store |
| `tls.sh` | Generates a self-signed TLS cert for ttyd (used in `tui` and `tmux` modes) |
| `plugins.sh` | Installs `oh-my-opencode-slim` from the npm cache baked into the image (OpenCode only) |
| `system-checks.sh` | Docker socket check, `git safe.directory`, workspace symlink, git credential/work config validation |
| `proxy.sh` | Defines `_start_proxy` and `_cleanup`; `_start_proxy` launches `proxy/prefill-proxy.mjs` (OpenCode only) |
| `runtime.sh` | Resolves `APP_BIN`, prints startup banner, refreshes model cache, guards FlowCode to web mode, initializes theme and browser tab title |
| `modes.sh` | Enters the `web`/`tui`/`tmux` restart loop — the last thing sourced; **does not return** |

These files are bind-mounted in `docker-compose.yml` (`./lib:/opt/opencode/lib:ro`), so edits on the host take effect after `./codebox.sh restart codebox` without a rebuild.
