# ─── lib/modes.sh ───────────────────────────────────────────────────────────
# Launch loops for each supported mode: tmux, tui, web.
# This is the final stage of the entrypoint — it does not return.

OPENCODE_MODE="${OPENCODE_MODE:-web}"
TMUX_SESSION="opencode"

cd /workspace

if [ "${OPENCODE_MODE}" = "tmux" ]; then
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
    # across container restarts and break if OPENCODE_APP changes).
    # The tmux-theme-toggle.sh sources from THEME_DIR which we override
    # via an exported env var that the wrapper and toggle script read.
    if [ "${OPENCODE_APP}" = "claude-code" ]; then
        for _theme_file in /opt/opencode/tmux/tmux-theme-dark.conf /opt/opencode/tmux/tmux-theme-light.conf; do
            _basename=$(basename "${_theme_file}")
            sed 's|/session-status\.sh|/session-status-claude.sh|g' \
                "${_theme_file}" > "/tmp/${_basename}"
        done
        export TMUX_THEME_DIR="/tmp"
    else
        export TMUX_THEME_DIR="/opt/opencode/tmux"
    fi

    echo "→ Starting ${APP_TITLE_PREFIX} TUI via tmux + ttyd on 0.0.0.0:${OPENCODE_PORT:-3000}..."
    echo "  Access: ${_TTYD_PROTOCOL:-http}://localhost:${OPENCODE_PORT:-3000}"
    echo "  Attach: docker exec -it <container> tmux attach -t ${TMUX_SESSION}"
    echo ""

    # Write the tmux wrapper script. ttyd executes this on each browser
    # connection. Terminal dimensions are already correct at this point.
    # Uses 'WRAPPER' (quoted) heredoc so no variable expansion at write time —
    # APP_BIN and OPENCODE_EXTRA_ARGS are read from the environment
    # at runtime (both are already exported). No envsubst needed.
    export OPENCODE_EXTRA_ARGS="${OPENCODE_EXTRA_ARGS:-}"
    cat > /tmp/tmux-wrapper.sh <<'WRAPPER'
#!/bin/bash
TMUX_SESSION="opencode"

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
    if [ "${OPENCODE_APP:-opencode}" = "opencode" ] && [ "${2:-}" = "--respawn" ]; then
        _continue_flag="--continue"
    fi
    exec "${APP_BIN}" ${_continue_flag} ${OPENCODE_EXTRA_ARGS}
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
    exec tmux -u attach -t "$TMUX_SESSION"
fi
WRAPPER
    chmod +x /tmp/tmux-wrapper.sh

    # ── Claude Code: suppress agent monitor keybindings after tmux session starts ──
    # These bindings are overridden after the first session is created via
    # the wrapper script. We schedule them in a background subshell that
    # waits for the tmux server to be up.
    if [ "${OPENCODE_APP}" = "claude-code" ]; then
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
            --port "${OPENCODE_PORT:-3000}" \
            --interface 0.0.0.0 \
            --writable \
            ${_TTYD_SSL_FLAGS:-} \
            -t titleFixed="${OPENCODE_TITLE:-${APP_TITLE_PREFIX} (tmux)}" \
            ${OPENCODE_TUI_ARGS:-} \
            /tmp/tmux-wrapper.sh
        _rc=$?
        if [ "${_rc}" -eq 0 ]; then _fail_count=0; else _fail_count=$((_fail_count + 1)); fi
        _sleep=$(( 3 * (1 << (_fail_count > 5 ? 5 : _fail_count)) ))
        echo ""
        echo "  ⟳ ttyd exited (rc=${_rc}). Restart #${_fail_count} in ${_sleep}s..."
        echo ""
        sleep "${_sleep}"
    done

elif [ "${OPENCODE_MODE}" = "tui" ]; then
    # ── TUI mode: app TUI served directly by ttyd ────────────────
    echo "→ Starting ${APP_TITLE_PREFIX} TUI via ttyd on 0.0.0.0:${OPENCODE_PORT:-3000}..."
    echo "  Access: ${_TTYD_PROTOCOL:-http}://localhost:${OPENCODE_PORT:-3000}"
    echo ""

    # Restart loop with exponential backoff on consecutive failures.
    _fail_count=0
    while true; do
        ttyd \
            --port "${OPENCODE_PORT:-3000}" \
            --interface 0.0.0.0 \
            --writable \
            --cwd /workspace \
            ${_TTYD_SSL_FLAGS:-} \
            -t titleFixed="${OPENCODE_TITLE:-${APP_TITLE_PREFIX} (tui)}" \
            ${OPENCODE_TUI_ARGS:-} \
            "${APP_BIN}" ${OPENCODE_EXTRA_ARGS:-}
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
    if [ "${OPENCODE_APP}" = "claude-code" ]; then
        echo "  ✗ FATAL: web mode is not supported for Claude Code — use tui or tmux"
        exit 1
    fi

    if [ "${OPENCODE_APP}" = "flowcode" ]; then
        echo "→ Starting FlowCode web on 0.0.0.0:${OPENCODE_PORT:-3000}..."
        echo "  Access: http://localhost:${OPENCODE_PORT:-3000}"
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
    echo "→ Starting opencode web on 0.0.0.0:${OPENCODE_PORT:-3000}..."
    echo "  Access: http://localhost:${OPENCODE_PORT:-3000}"
    echo ""

    _fail_count=0
    while true; do
        "${APP_BIN}" web \
            --hostname 0.0.0.0 \
            --port "${OPENCODE_PORT:-3000}" \
            ${OPENCODE_EXTRA_ARGS:-}
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
