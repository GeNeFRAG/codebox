# tmux/

Config files and runtime scripts for `CODEBOX_MODE=tmux`. Not used in `web` or `tui` modes.

## Config files

| File | Purpose |
|------|---------|
| `tmux.conf` | Main tmux config — keybindings, status bar layout, mouse support, clipboard passthrough via ttyd/OSC52 |
| `tmux-theme-dark.conf` | Dark theme overrides for the status bar |
| `tmux-theme-light.conf` | Light theme overrides for the status bar |

## Runtime scripts

| File | Purpose |
|------|---------|
| `tmux-theme-toggle.sh` | Toggles between dark and light themes at runtime; bound to `Ctrl-Space t` |
| `agent-monitor.sh` | Renders the monitor pane — polls OpenCode's SQLite DB for subagent activity (**OpenCode only**) |
| `agent-monitor-toggle.sh` | Shows/hides the monitor pane |
| `agent-status.sh` | One-line subagent status for the tmux status bar (**OpenCode only**) |
| `session-status.sh` | Full session status (model, context, cost) for the tmux status bar (**OpenCode only**) |
| `session-status-claude.sh` | Simplified status bar for Claude Code (no model/context data, OpenCode DB not available) |

All scripts are bind-mounted from the host (`docker-compose.yml`), so edits apply after `./codebox.sh restart codebox`.

The `agent-monitor.sh`, `agent-status.sh`, and `session-status.sh` scripts query OpenCode's SQLite database at `/root/.local/share/opencode/opencode.db`. They will produce no output (or errors) when `CODEBOX_APP=claude-code` or `CODEBOX_APP=flowcode`.
