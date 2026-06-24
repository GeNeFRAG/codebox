# ─── lib/runtime.sh ─────────────────────────────────────────────────────────
# Resolves the app binary (APP_BIN), prints the startup banner, refreshes the
# OpenCode model cache, initialises the UI theme, and derives the browser tab title.

# ── Banner helper ────────────────────────────────────────────────
_print_banner() {
    local label="$1" ver_line="$2"
    ver_line="${ver_line:0:22}"
    local pad=$((22 - ${#ver_line}))
    [ "$pad" -lt 0 ] && pad=0
    echo "╔══════════════════════════════════════════╗"
    echo "║     CodeBox — ${label}       ║"
    echo "║     ${ver_line}$(printf '%*s' "$pad" '')║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
}

# ── Resolve the app binary and export APP_BIN ─────────────────────
if [ "${CODEBOX_APP}" = "claude-code" ]; then
    CLAUDE_BIN=$(which claude 2>/dev/null || echo "/usr/local/bin/claude")
    if [ -x "${CLAUDE_BIN}" ]; then
        export APP_BIN="${CLAUDE_BIN}"
        echo "  ✓ claude binary: ${CLAUDE_BIN}"
    else
        echo "  ✗ FATAL: claude binary not found"
        echo "    Expected: /usr/local/bin/claude"
        exit 1
    fi

    # Build extra args for Claude Code (--mcp-config flag, --model if set)
    _claude_extra="--mcp-config /opt/opencode/templates/claude-code-mcp.json"
    if [ -n "${CLAUDE_MODEL:-}" ]; then
        _claude_extra="${_claude_extra} --model ${CLAUDE_MODEL}"
    fi
    if [ -n "${CLAUDE_CODE_PERMISSION_MODE:-}" ]; then
        case "${CLAUDE_CODE_PERMISSION_MODE}" in
            acceptEdits|auto|bypassPermissions|default|dontAsk|plan)
                _claude_extra="${_claude_extra} --permission-mode ${CLAUDE_CODE_PERMISSION_MODE}"
                echo "  ✓ Permission mode: ${CLAUDE_CODE_PERMISSION_MODE}"
                ;;
            *)
                echo "  ⚠ Ignoring invalid CLAUDE_CODE_PERMISSION_MODE='${CLAUDE_CODE_PERMISSION_MODE}'"
                echo "    Valid: acceptEdits, auto, bypassPermissions, default, dontAsk, plan"
                ;;
        esac
    fi
    export CODEBOX_EXTRA_ARGS="${CODEBOX_EXTRA_ARGS:+${CODEBOX_EXTRA_ARGS} }${_claude_extra}"

    _app_ver=$("${APP_BIN}" --version 2>/dev/null || echo "unknown")
    _print_banner "Claude Code" "claude-code v${_app_ver}"

else
    # OpenCode binary (default)
    OPENCODE_STABLE_BIN="/usr/local/bin/opencode-go"
    OPENCODE_NPM_WRAPPER="/usr/local/bin/opencode"

    if [ -x "${OPENCODE_STABLE_BIN}" ]; then
        export OPENCODE_BIN_PATH="${OPENCODE_STABLE_BIN}"
        echo "  ✓ opencode binary: ${OPENCODE_STABLE_BIN}"
    elif [ -x "${OPENCODE_NPM_WRAPPER}" ]; then
        export OPENCODE_BIN_PATH="${OPENCODE_NPM_WRAPPER}"
        echo "  ⚠ Stable binary missing — falling back to npm wrapper (fragile)"
    else
        echo "  ✗ FATAL: opencode binary not found"
        echo "    Expected: ${OPENCODE_STABLE_BIN}"
        echo "    Fallback: ${OPENCODE_NPM_WRAPPER}"
        exit 1
    fi
    export APP_BIN="${OPENCODE_BIN_PATH}"

    _app_ver=$("${OPENCODE_BIN_PATH}" --version 2>/dev/null || echo "unknown")
    _print_banner "OpenCode" "opencode-ai v${_app_ver}"
fi

# ─── Refresh model cache in the background (OpenCode only, best-effort) ─
# opencode caches provider model lists locally. After a container rebuild
# the cache may be stale, causing ProviderModelNotFoundError for newly
# available models. Refresh asynchronously so it doesn't delay startup.
if [ "${CODEBOX_APP}" = "opencode" ] && [ -x "${OPENCODE_BIN_PATH:-}" ]; then
    (
        "${OPENCODE_BIN_PATH}" models --refresh >/dev/null 2>&1 \
            && echo "  ✓ Model cache refreshed" \
            || echo "  ⚠ Model cache refresh failed (non-fatal)"
    ) &
    echo "→ Refreshing model cache in background..."
fi

# ─── Record startup timestamp (ms) for status bar freshness ───────
# Status scripts use this to ignore sessions from previous container
# lifecycles — avoids showing stale model/token data after a rebuild.
date +%s%3N > /tmp/.opencode-startup-ts

# ─── Initialize theme flag (dark by default, persists across reconnects) ─
# CODEBOX_THEME env var allows setting initial theme via .env.
# The flag file is read by status bar scripts and agent-monitor.sh.
# COLORFGBG tells lipgloss (opencode's TUI library) whether the
# terminal has a light or dark background, so it picks matching colors.
_init_theme="${CODEBOX_THEME:-dark}"
echo "$_init_theme" > /tmp/.tmux-theme
if [ "$_init_theme" = "light" ]; then
    export COLORFGBG="0;15"
else
    export COLORFGBG="15;0"
fi

# ─── Auto-detect browser tab title from Docker Compose service name ─
# If CODEBOX_TITLE is not set, derive it from the Compose service label
# (e.g. "my-project" → "OpenCode — my-project" or "Claude Code — my-project").
if [ -z "${CODEBOX_TITLE}" ]; then
    _compose_svc=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$(hostname)" 2>/dev/null || true)
    if [ -n "${_compose_svc}" ] && [ "${_compose_svc}" != "<no value>" ]; then
        export CODEBOX_TITLE="${APP_TITLE_PREFIX} — ${_compose_svc}"
        echo "  ✓ Browser tab title: ${CODEBOX_TITLE}"
    fi
fi
