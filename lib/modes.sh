# ─── lib/modes.sh ───────────────────────────────────────────────────────────
# Launch loops for each supported mode: tmux, tui, web.
# This is the final stage of the entrypoint — it does not return.

_backoff_sleep() { echo $(( 3 * (1 << (${1:-0} > 5 ? 5 : ${1:-0})) )); }

_serve_ttyd_loop() {
    local wrapper_path="$1" mode_label="$2"
    local _fail_count=0
    while true; do
        if [ ! -x "${wrapper_path}" ]; then
            echo "  ✗ ${wrapper_path} missing or not executable — cannot start ${mode_label} session"
            echo "    Container restart required to regenerate the wrapper script."
            exit 1
        fi
        ttyd \
            --port "${CODEBOX_PORT:-3000}" \
            --interface 0.0.0.0 \
            --writable \
            ${_TTYD_SSL_FLAGS:-} \
            -t titleFixed="${CODEBOX_TITLE:-${APP_TITLE_PREFIX} (${mode_label})}" \
            -t macOptionClickForcesSelection=true \
            ${CODEBOX_TUI_ARGS:-} \
            "${wrapper_path}"
        _rc=$?
        if [ "${_rc}" -eq 0 ]; then _fail_count=0; else _fail_count=$((_fail_count + 1)); fi
        _sleep=$(_backoff_sleep "$_fail_count")
        echo ""
        echo "  ⟳ ttyd exited (rc=${_rc}). Restart #${_fail_count} in ${_sleep}s..."
        echo ""
        sleep "${_sleep}"
    done
}

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

    # session-status.sh now handles both OpenCode and Claude Code
    # (checks CODEBOX_APP internally), so no theme file patching needed.
    export TMUX_THEME_DIR="/opt/opencode/tmux"

    echo "→ Starting ${APP_TITLE_PREFIX} TUI via tmux + ttyd on 0.0.0.0:${CODEBOX_PORT:-3000}..."
    echo "  Access: ${_TTYD_PROTOCOL:-http}://localhost:${CODEBOX_PORT:-3000}"
    echo "  Attach: docker exec -it <container> tmux attach -t ${TMUX_SESSION}"
    echo ""

    export CODEBOX_EXTRA_ARGS="${CODEBOX_EXTRA_ARGS:-}"
    cp /opt/opencode/tmux/tmux-wrapper.sh /tmp/tmux-wrapper.sh || {
        echo "  ✗ FATAL: could not copy tmux-wrapper.sh from /opt/opencode/tmux/"
        exit 1
    }
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
    _serve_ttyd_loop /tmp/tmux-wrapper.sh "tmux"

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

    export CODEBOX_EXTRA_ARGS="${CODEBOX_EXTRA_ARGS:-}"
    cp /opt/opencode/tmux/tui-wrapper.sh /tmp/tui-wrapper.sh || {
        echo "  ✗ FATAL: could not copy tui-wrapper.sh from /opt/opencode/tmux/"
        exit 1
    }
    chmod +x /tmp/tui-wrapper.sh

    # ttyd serves the wrapper. The tmux session persists independently
    # across ttyd restarts, so browser disconnects don't kill the app.
    _serve_ttyd_loop /tmp/tui-wrapper.sh "tui"

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
            _sleep=$(_backoff_sleep "$_fail_count")
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
        _sleep=$(_backoff_sleep "$_fail_count")
        echo ""
        echo "  ⟳ opencode web exited (rc=${_rc}). Restart #${_fail_count} in ${_sleep}s..."
        echo ""

        _restart_proxy
        sleep "${_sleep}"
    done
fi
