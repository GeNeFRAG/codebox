#!/bin/bash
# tui-wrapper.sh — ttyd calls this on each browser connection in TUI mode.
# Creates or attaches to a hidden-status-bar tmux session for persistence.
#
# Deployment: lib/modes.sh copies this to /tmp/tui-wrapper.sh at startup.
#             The script self-references that /tmp/ path for the tmux pane command.
#
# Environment: APP_BIN, CODEBOX_EXTRA_ARGS, CODEBOX_APP
#              are expected to be exported by the entrypoint.
TMUX_SESSION="codebox-tui"

# --run: launched inside the tmux pane to exec the actual app
if [ "${1:-}" = "--run" ]; then
    exec "${APP_BIN}" ${CODEBOX_EXTRA_ARGS}
fi

# Default: connect to or create the persistent TUI session
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    exec tmux -u attach -t "$TMUX_SESSION"
fi

# Initial canvas size comes from the first attaching browser (tput
# cols/lines). window-size=latest lets the canvas track later clients,
# so resizing the browser reflows the TUI instead of clipping it.
COLS=$(tput cols  2>/dev/null || echo 200)
ROWS=$(tput lines 2>/dev/null || echo 50)
tmux -u new-session -d -s "$TMUX_SESSION" -x "$COLS" -y "$ROWS" -c /workspace \
    /tmp/tui-wrapper.sh --run
tmux set-option -t "$TMUX_SESSION" window-size latest
tmux set-option -t "$TMUX_SESSION" status off
if [ "${CODEBOX_APP:-opencode}" = "claude-code" ]; then
    [ -f /opt/opencode/tmux/claude-bindings.sh ] \
        && source /opt/opencode/tmux/claude-bindings.sh \
        || echo "  ! claude-bindings.sh missing — mouse bindings not applied"
fi
exec tmux -u attach -t "$TMUX_SESSION"
