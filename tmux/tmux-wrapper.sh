#!/bin/bash
# tmux-wrapper.sh — ttyd calls this on each browser connection.
# In tmux mode: creates or attaches to the persistent tmux session.
#
# Deployment: lib/modes.sh copies this to /tmp/tmux-wrapper.sh at startup.
#             The script self-references that /tmp/ path for tmux pane commands
#             and the pane-died respawn hook in tmux.conf.
#
# Environment: APP_BIN, CODEBOX_EXTRA_ARGS, CODEBOX_APP, TMUX_THEME_DIR
#              are expected to be exported by the entrypoint.
TMUX_SESSION="codebox"

if [ "${1:-}" = "--loop" ]; then
    # Read theme at launch time (not just at container start) so that
    # respawns after theme toggle pick up the new COLORFGBG value.
    _theme=$(cat /tmp/.tmux-theme 2>/dev/null || echo "dark")
    if [ "$_theme" = "light" ]; then
        export COLORFGBG="0;15"
    else
        export COLORFGBG="15;0"
    fi
    # On respawn (pane-died), pass --continue to resume the last session
    # instead of starting a new one. Only applies to OpenCode (Claude Code
    # manages its own session state and does not support this flag).
    _continue_flag=""
    if [ "${CODEBOX_APP:-opencode}" = "opencode" ] && [ "${2:-}" = "--respawn" ]; then
        _continue_flag="--continue"
    fi
    exec "${APP_BIN}" ${_continue_flag} ${CODEBOX_EXTRA_ARGS}
fi

if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    exec tmux -u attach -t "$TMUX_SESSION"
else
    # Apply initial theme to the outer terminal BEFORE creating the
    # tmux session, so lipgloss detects the correct background.
    _init_theme=$(cat /tmp/.tmux-theme 2>/dev/null || echo "dark")
    if [ "$_init_theme" = "light" ]; then
        printf '\e]10;#3760bf\a'    # OSC 10: foreground
        printf '\e]11;#d5d6db\a'    # OSC 11: background
        printf '\e]12;#2e7de9\a'    # OSC 12: cursor
    fi

    COLS=$(tput cols  2>/dev/null || echo 180)
    ROWS=$(tput lines 2>/dev/null || echo 50)
    tmux -u new-session -d -s "$TMUX_SESSION" -n "$(basename "$APP_BIN")" -x "$COLS" -y "$ROWS" -c /workspace \
        "/tmp/tmux-wrapper.sh --loop"
    tmux source-file "${TMUX_THEME_DIR}/tmux-theme-${_init_theme}.conf" 2>/dev/null
    if [ "${CODEBOX_APP:-opencode}" = "claude-code" ]; then
        tmux bind -T root WheelUpPane   if-shell -F "#{pane_in_mode}" "send-keys -X -N 3 scroll-up"   "copy-mode -e"
        tmux bind -T root WheelDownPane if-shell -F "#{pane_in_mode}" "send-keys -X -N 3 scroll-down" ""
        tmux bind C-r run-shell "kill -WINCH #{pane_pid} 2>/dev/null; sleep 0.05; kill -WINCH #{pane_pid} 2>/dev/null"
        tmux set-hook -g client-resized  "run-shell -b 'kill -WINCH #{pane_pid} 2>/dev/null; sleep 0.05; kill -WINCH #{pane_pid} 2>/dev/null'"
        tmux set-hook -g client-attached "run-shell -b 'sleep 0.2; kill -WINCH #{pane_pid} 2>/dev/null'"
    fi
    exec tmux -u attach -t "$TMUX_SESSION"
fi
