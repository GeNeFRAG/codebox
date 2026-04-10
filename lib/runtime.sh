# ─── lib/runtime.sh ─────────────────────────────────────────────────────────
# Resolves the app binary (APP_BIN), prints the startup banner, refreshes the
# OpenCode model cache, initialises the UI theme, derives the browser tab title,
# and enforces mode constraints (e.g. FlowCode is web-only).

# ── Resolve the app binary and export APP_BIN ─────────────────────
if [ "${OPENCODE_APP}" = "claude-code" ]; then
    CLAUDE_BIN=$(which claude 2>/dev/null || echo "/usr/local/bin/claude")
    if [ -x "${CLAUDE_BIN}" ]; then
        export APP_BIN="${CLAUDE_BIN}"
        echo "  ✓ claude binary: ${CLAUDE_BIN}"
    else
        echo "  ✗ FATAL: claude binary not found"
        echo "    Expected: /usr/local/bin/claude"
        exit 1
    fi

    # Build extra args for Claude Code (--mcp-config flag)
    _claude_extra="--mcp-config /opt/opencode/templates/claude-code-mcp.json"
    export OPENCODE_EXTRA_ARGS="${OPENCODE_EXTRA_ARGS:+${OPENCODE_EXTRA_ARGS} }${_claude_extra}"

    _app_ver=$("${APP_BIN}" --version 2>/dev/null || echo "unknown")
    _app_ver="${_app_ver:0:22}"
    _ver_pad=$((22 - ${#_app_ver}))
    [ "${_ver_pad}" -lt 0 ] && _ver_pad=0
    echo "╔══════════════════════════════════════════╗"
    echo "║     Claude Code - Docker Container       ║"
    echo "║     claude-code v${_app_ver}$(printf '%*s' "${_ver_pad}" '')║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

elif [ "${OPENCODE_APP}" = "flowcode" ]; then
    FLOWCODE_BIN="/usr/local/bin/flowcode-server"
    if [ -x "${FLOWCODE_BIN}" ]; then
        export APP_BIN="${FLOWCODE_BIN}"
        echo "  ✓ flowcode-server binary: ${FLOWCODE_BIN}"
    else
        echo "  ✗ FATAL: flowcode-server binary not found at ${FLOWCODE_BIN}"
        exit 1
    fi

    # FlowCode runtime environment
    export PORT="${OPENCODE_PORT:-3000}"
    export FLOWCODE_STATIC_DIR="/opt/flowcode/public"
    export FLOWCODE_FILE_ROOT="/workspace"
    export FLOWCODE_LOCAL=1
    export NODE_ENV=production
    export SHELL=/bin/bash
    # Map auth env vars to FlowCode's expected format
    [ -n "${LLM_API_KEY:-}" ] && export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-${LLM_API_KEY}}"
    [ -n "${LLM_BASE_URL:-}" ] && export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-${LLM_BASE_URL}}"

    echo "╔══════════════════════════════════════════╗"
    echo "║       FlowCode - Docker Container        ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

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

    OPENCODE_VER=$("${OPENCODE_BIN_PATH}" --version 2>/dev/null || echo "unknown")
    OPENCODE_VER="${OPENCODE_VER:0:22}"  # clamp to fit banner width
    _ver_pad=$((22 - ${#OPENCODE_VER}))
    [ "${_ver_pad}" -lt 0 ] && _ver_pad=0
    echo "╔══════════════════════════════════════════╗"
    echo "║       OpenCode Web - Docker Container    ║"
    echo "║       opencode-ai v${OPENCODE_VER}$(printf '%*s' "${_ver_pad}" '')║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
fi

# ─── Refresh model cache in the background (OpenCode only, best-effort) ─
# opencode caches provider model lists locally. After a container rebuild
# the cache may be stale, causing ProviderModelNotFoundError for newly
# available models. Refresh asynchronously so it doesn't delay startup.
if [ "${OPENCODE_APP}" = "opencode" ] && [ -x "${OPENCODE_BIN_PATH:-}" ]; then
    (
        "${OPENCODE_BIN_PATH}" models --refresh >/dev/null 2>&1 \
            && echo "  ✓ Model cache refreshed" \
            || echo "  ⚠ Model cache refresh failed (non-fatal)"
    ) &
    echo "→ Refreshing model cache in background..."
fi

# ─── FlowCode mode guard (web-only) ──────────────────────────────
if [ "${OPENCODE_APP}" = "flowcode" ] && [ "${OPENCODE_MODE}" != "web" ]; then
    echo "  ⚠ FlowCode only supports web mode — overriding OPENCODE_MODE=${OPENCODE_MODE} → web"
    OPENCODE_MODE="web"
fi

# ─── Record startup timestamp (ms) for status bar freshness ───────
# Status scripts use this to ignore sessions from previous container
# lifecycles — avoids showing stale model/token data after a rebuild.
date +%s%3N > /tmp/.opencode-startup-ts

# ─── Initialize theme flag (dark by default, persists across reconnects) ─
# OPENCODE_THEME env var allows setting initial theme via .env.
# The flag file is read by status bar scripts and agent-monitor.sh.
# COLORFGBG tells lipgloss (opencode's TUI library) whether the
# terminal has a light or dark background, so it picks matching colors.
_init_theme="${OPENCODE_THEME:-dark}"
echo "$_init_theme" > /tmp/.tmux-theme
if [ "$_init_theme" = "light" ]; then
    export COLORFGBG="0;15"
else
    export COLORFGBG="15;0"
fi

# ─── Auto-detect browser tab title from Docker Compose service name ─
# If OPENCODE_TITLE is not set, derive it from the Compose service label
# (e.g. "my-project" → "OpenCode — my-project" or "Claude Code — my-project").
if [ -z "${OPENCODE_TITLE}" ]; then
    _compose_svc=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$(hostname)" 2>/dev/null || true)
    if [ -n "${_compose_svc}" ] && [ "${_compose_svc}" != "<no value>" ]; then
        export OPENCODE_TITLE="${APP_TITLE_PREFIX} — ${_compose_svc}"
        echo "  ✓ Browser tab title: ${OPENCODE_TITLE}"
    fi
fi
