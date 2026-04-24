# ─── lib/modes.sh ───────────────────────────────────────────────────────────
# Launch loops for each supported mode: tmux, tui, web.
# This is the final stage of the entrypoint — it does not return.

CODEBOX_MODE="${CODEBOX_MODE:-web}"
TMUX_SESSION="codebox"

cd /workspace

if [ "${CODEBOX_MODE}" = "tmux" ]; then
    # ── tmux mode: run app inside tmux, served by ttyd ───────────
    # Architecture: ttyd → wrapper script → tmux new/attach → app
    #
    # Restart on /exit is handled by tmux itself:
    #   remain-on-exit on  → keeps dead pane visible
    #   pane-died hook     → respawns after 2s delay
    # See tmux.conf for the hook definition.
    #
    # Browser disconnects don't kill the tmux session; reopening the
    # URL reattaches instantly.

    # Apply custom tmux config if mounted
    if [ -f "/root/.config/opencode/tmux.conf" ]; then
        cp /root/.config/opencode/tmux.conf /root/.tmux.conf
        echo "  ✓ Custom tmux.conf applied"
    fi

    # ── Claude Code tmux adaptations ──────────────────────────────
    # Create runtime copies of theme files in /tmp. For Claude Code,
    # swap session-status.sh → session-status-claude.sh. This avoids
    # mutating the baked-in /opt/opencode/ files (which would persist
    # across container restarts and break if CODEBOX_APP changes).
    # The tmux-theme-toggle.sh sources from THEME_DIR which we override
    # via an exported env var that the wrapper and toggle script read.
    if [ "${CODEBOX_APP}" = "claude-code" ]; then
        for _theme_file in /opt/opencode/tmux/tmux-theme-dark.conf /opt/opencode/tmux/tmux-theme-light.conf; do
            _basename=$(basename "${_theme_file}")
            sed 's|/session-status\.sh|/session-status-claude.sh|g' \
                "${_theme_file}" > "/tmp/${_basename}"
        done
        export TMUX_THEME_DIR="/tmp"
    else
        export TMUX_THEME_DIR="/opt/opencode/tmux"
    fi

    echo "→ Starting ${APP_TITLE_PREFIX} TUI via tmux + ttyd on 0.0.0.0:${CODEBOX_PORT:-3000}..."
    echo "  Access: ${_TTYD_PROTOCOL:-http}://localhost:${CODEBOX_PORT:-3000}"
    echo "  Attach: docker exec -it <container> tmux attach -t ${TMUX_SESSION}"
    echo ""

    # Write the tmux wrapper script. ttyd executes this on each browser
    # connection. Terminal dimensions are already correct at this point.
    # Uses 'WRAPPER' (quoted) heredoc so no variable expansion at write time —
    # APP_BIN and CODEBOX_EXTRA_ARGS are read from the environment
    # at runtime (both are already exported). No envsubst needed.
    export CODEBOX_EXTRA_ARGS="${CODEBOX_EXTRA_ARGS:-}"
    cat > /tmp/tmux-wrapper.sh <<'WRAPPER'
#!/bin/bash
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
    # For Claude Code, intercept wheel events at the root binding level so
    # they enter tmux copy mode (scrollback) instead of being forwarded to
    # the app (which would cycle prompt history via its own mouse handler).
    [ "${CODEBOX_APP:-opencode}" = "claude-code" ] && {
        tmux bind -T root WheelUpPane   if-shell "#{pane_in_mode}" "send-keys -M" "copy-mode -e"
        tmux bind -T root WheelDownPane if-shell "#{pane_in_mode}" "send-keys -M" ""
    }
    exec tmux -u attach -t "$TMUX_SESSION"
fi
WRAPPER
    chmod +x /tmp/tmux-wrapper.sh

    # ── Claude Code: suppress agent monitor keybindings after tmux session starts ──
    # These bindings are overridden after the first session is created via
    # the wrapper script. We schedule them in a background subshell that
    # waits for the tmux server to be up.
    if [ "${CODEBOX_APP}" = "claude-code" ]; then
        (
            # Wait for tmux server to be ready (up to 10s)
            for _i in $(seq 1 20); do
                tmux has-session -t "${TMUX_SESSION}" 2>/dev/null && break
                sleep 0.5
            done
            # Wait for theme source-file to complete (avoids race where theme
            # conf re-binds the keys we're about to suppress)
            sleep 1
            # Rebind monitor keys to informational no-ops
            tmux unbind m 2>/dev/null
            tmux unbind M 2>/dev/null
            tmux bind m display-message "Agent monitor not available for Claude Code"
            tmux bind M display-message "Agent monitor not available for Claude Code"
            # Suppress root-level Option-key shortcuts for monitor
            tmux unbind -T root µ 2>/dev/null
            tmux unbind -T root Ò 2>/dev/null
            tmux bind -T root µ display-message "Agent monitor not available for Claude Code"
            tmux bind -T root Ò display-message "Agent monitor not available for Claude Code"
        ) &
    fi

    # ttyd serves the wrapper. If ttyd crashes, restart it.
    # The tmux session persists independently across ttyd restarts.
    _fail_count=0
    while true; do
        # Validate wrapper script still exists (e.g., /tmp cleanup)
        if [ ! -x /tmp/tmux-wrapper.sh ]; then
            echo "  ✗ /tmp/tmux-wrapper.sh missing or not executable — cannot start tmux session"
            echo "    Container restart required to regenerate the wrapper script."
            exit 1
        fi
        ttyd \
            --port "${CODEBOX_PORT:-3000}" \
            --interface 0.0.0.0 \
            --writable \
            ${_TTYD_SSL_FLAGS:-} \
            -t titleFixed="${CODEBOX_TITLE:-${APP_TITLE_PREFIX} (tmux)}" \
            -t macOptionClickForcesSelection=true \
            ${CODEBOX_TUI_ARGS:-} \
            /tmp/tmux-wrapper.sh
        _rc=$?
        if [ "${_rc}" -eq 0 ]; then _fail_count=0; else _fail_count=$((_fail_count + 1)); fi
        _sleep=$(( 3 * (1 << (_fail_count > 5 ? 5 : _fail_count)) ))
        echo ""
        echo "  ⟳ ttyd exited (rc=${_rc}). Restart #${_fail_count} in ${_sleep}s..."
        echo ""
        sleep "${_sleep}"
    done

elif [ "${CODEBOX_MODE}" = "tui" ]; then
    # ── TUI mode: app served via ttyd + hidden tmux for session persistence ─
    # Architecture: ttyd → wrapper script → tmux new/attach → app
    #
    # Same persistence approach as tmux mode: browser disconnects only
    # detach the tmux client; the session and the app inside it keep
    # running. Reopening the URL reattaches instantly — screen lock no
    # longer resets the session.
    #
    # The status bar is hidden so the user sees only the app TUI; from
    # the browser this is visually identical to the previous TUI mode.
    echo "→ Starting ${APP_TITLE_PREFIX} TUI via ttyd on 0.0.0.0:${CODEBOX_PORT:-3000}..."
    echo "  Access: ${_TTYD_PROTOCOL:-http}://localhost:${CODEBOX_PORT:-3000}"
    echo "  Attach: docker exec -it <container> tmux attach -t codebox-tui"
    echo ""

    # Write the TUI wrapper script. Uses 'WRAPPER' (quoted) heredoc so
    # no variable expansion at write time — APP_BIN and CODEBOX_EXTRA_ARGS
    # are read from the environment at runtime (both are already exported).
    export CODEBOX_EXTRA_ARGS="${CODEBOX_EXTRA_ARGS:-}"
    cat > /tmp/tui-wrapper.sh <<'WRAPPER'
#!/bin/bash
TMUX_SESSION="codebox-tui"

# --run: launched inside the tmux pane to exec the actual app
if [ "${1:-}" = "--run" ]; then
    exec "${APP_BIN}" ${CODEBOX_EXTRA_ARGS}
fi

# Default: connect to or create the persistent TUI session
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    exec tmux -u attach -t "$TMUX_SESSION"
fi

# Canvas is sized from the first attaching browser (tput cols/lines) then
# pinned via window-size=manual so later clients (e.g. after screen lock)
# can't reshape the TUI.
COLS=$(tput cols  2>/dev/null || echo 200)
ROWS=$(tput lines 2>/dev/null || echo 50)
tmux -u new-session -d -s "$TMUX_SESSION" -x "$COLS" -y "$ROWS" -c /workspace \
    /tmp/tui-wrapper.sh --run
tmux set-option -t "$TMUX_SESSION" window-size manual
tmux set-option -t "$TMUX_SESSION" status off
[ "${CODEBOX_APP:-}" = "claude-code" ] && {
    tmux bind -T root WheelUpPane   if-shell "#{pane_in_mode}" "send-keys -M" "copy-mode -e"
    tmux bind -T root WheelDownPane if-shell "#{pane_in_mode}" "send-keys -M" ""
}
exec tmux -u attach -t "$TMUX_SESSION"
WRAPPER
    chmod +x /tmp/tui-wrapper.sh

    # ttyd serves the wrapper. The tmux session persists independently
    # across ttyd restarts, so browser disconnects don't kill the app.
    _fail_count=0
    while true; do
        if [ ! -x /tmp/tui-wrapper.sh ]; then
            echo "  ✗ /tmp/tui-wrapper.sh missing or not executable — cannot start TUI session"
            echo "    Container restart required to regenerate the wrapper script."
            exit 1
        fi
        ttyd \
            --port "${CODEBOX_PORT:-3000}" \
            --interface 0.0.0.0 \
            --writable \
            ${_TTYD_SSL_FLAGS:-} \
            -t titleFixed="${CODEBOX_TITLE:-${APP_TITLE_PREFIX} (tui)}" \
            -t macOptionClickForcesSelection=true \
            ${CODEBOX_TUI_ARGS:-} \
            /tmp/tui-wrapper.sh
        _rc=$?
        if [ "${_rc}" -eq 0 ]; then _fail_count=0; else _fail_count=$((_fail_count + 1)); fi
        _sleep=$(( 3 * (1 << (_fail_count > 5 ? 5 : _fail_count)) ))
        echo ""
        echo "  ⟳ ttyd exited (rc=${_rc}). Restart #${_fail_count} in ${_sleep}s..."
        echo ""
        sleep "${_sleep}"
    done

else
    # ── Web mode (default) ───────────────────────────────────────
    if [ "${CODEBOX_APP}" = "claude-code" ]; then
        echo "  ✗ FATAL: web mode is not supported for Claude Code — use tui or tmux"
        exit 1
    fi

    if [ "${CODEBOX_APP}" = "flowcode" ]; then
        echo "→ Starting FlowCode web on 0.0.0.0:${CODEBOX_PORT:-3000}..."
        echo "  Access: http://localhost:${CODEBOX_PORT:-3000}"
        echo ""

        _fail_count=0
        while true; do
            "${APP_BIN}"
            _rc=$?
            if [ "${_rc}" -eq 0 ]; then _fail_count=0; else _fail_count=$((_fail_count + 1)); fi
            _sleep=$(( 3 * (1 << (_fail_count > 5 ? 5 : _fail_count)) ))
            echo ""
            echo "  ⟳ FlowCode exited (rc=${_rc}). Restart #${_fail_count} in ${_sleep}s..."
            echo ""
            sleep "${_sleep}"
        done
    fi

    # OpenCode web mode
    echo "→ Starting opencode web on 0.0.0.0:${CODEBOX_PORT:-3000}..."
    echo "  Access: http://localhost:${CODEBOX_PORT:-3000}"
    echo ""

    _fail_count=0
    while true; do
        "${APP_BIN}" web \
            --hostname 0.0.0.0 \
            --port "${CODEBOX_PORT:-3000}" \
            ${CODEBOX_EXTRA_ARGS:-}
        _rc=$?
        if [ "${_rc}" -eq 0 ]; then _fail_count=0; else _fail_count=$((_fail_count + 1)); fi
        _sleep=$(( 3 * (1 << (_fail_count > 5 ? 5 : _fail_count)) ))
        echo ""
        echo "  ⟳ opencode web exited (rc=${_rc}). Restart #${_fail_count} in ${_sleep}s..."
        echo ""

        _restart_proxy
        sleep "${_sleep}"
    done
fi
