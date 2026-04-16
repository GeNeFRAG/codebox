#!/bin/bash
# NOTE: We intentionally avoid `set -e` here. The entrypoint performs many
# best-effort operations (CA cert install, npm cache warm, Docker socket
# queries, auth merges) that may legitimately fail — especially after a
# host/VM restart when Docker socket or file-share mounts aren't ready yet.
# Non-critical failures are logged with ⚠ and execution continues.
# Critical failures (config generation, mode launch) exit explicitly.

# ─── Secrets hygiene: make files owner-only by default ─────────────
umask 077

# ─── UTF-8 locale (safety net if Dockerfile ENV is not inherited) ──
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

LIB="/opt/opencode/lib"

# ─── 1. Load .env and warn about non-reloadable changes ────────────
# shellcheck source=lib/env.sh
. "${LIB}/env.sh"

# ─── 2. Coding agent selection ─────────────────────────────────────
# OPENCODE_APP selects which coding agent to run:
#   opencode    (default) — OpenCode AI agent
#   claude-code           — Anthropic Claude Code agent
#   flowcode              — FlowCode (RBI) AI agent — web mode only
OPENCODE_APP="${OPENCODE_APP:-opencode}"
if [ "${OPENCODE_APP}" = "claude-code" ]; then
    APP_TITLE_PREFIX="Claude Code"
elif [ "${OPENCODE_APP}" = "flowcode" ]; then
    APP_TITLE_PREFIX="FlowCode"
else
    APP_TITLE_PREFIX="OpenCode"
fi

# ─── 3. Resolve CA_CERT_PATH to the real host path ─────────────────
# Compose mounts CA_CERT_PATH → /certs/ca-bundle.pem inside this container,
# but MCP servers run as sibling containers via the Docker socket, so their
# -v flags need the real host path. The user may have used ~ in .env, which
# Compose expands for volume mounts but NOT for environment variables.
if [ -f /certs/ca-bundle.pem ] && [ -s /certs/ca-bundle.pem ]; then
    HOST_CA_PATH=$(docker inspect "$(hostname)" \
        --format '{{range .Mounts}}{{if eq .Destination "/certs/ca-bundle.pem"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null || true)
    if [ -n "${HOST_CA_PATH}" ]; then
        export CA_CERT_PATH="${HOST_CA_PATH}"
    fi
else
    export CA_CERT_PATH="/dev/null"
fi

# ─── 4. Cleanup on SIGTERM (reap background proxy) ─────────────────
# shellcheck source=lib/proxy.sh
. "${LIB}/proxy.sh"
_cleanup() {
    [ -n "${PROXY_PID:-}" ] && kill "${PROXY_PID}" 2>/dev/null
    exit 0
}
trap _cleanup SIGTERM SIGINT

# ─── 5. App-specific configuration ─────────────────────────────────
# shellcheck source=lib/config.sh
. "${LIB}/config.sh"

if [ "${OPENCODE_APP}" = "claude-code" ]; then
    echo "→ Configuring Claude Code..."
    export PREFILL_PROXY_ENABLED=false
    _generate_claude_code_config

elif [ "${OPENCODE_APP}" = "flowcode" ]; then
    echo "→ Configuring FlowCode..."
    export PREFILL_PROXY_ENABLED=false
    _generate_flowcode_config

else
    _configure_opencode
fi

# ─── 6. Corporate CA certificate ───────────────────────────────────
# shellcheck source=lib/ca-cert.sh
. "${LIB}/ca-cert.sh"

# ─── 7. TLS certificate for ttyd (tui/tmux clipboard support) ──────
# shellcheck source=lib/tls.sh
. "${LIB}/tls.sh"

# ─── 8. OpenCode plugins ────────────────────────────────────────────
# shellcheck source=lib/plugins.sh
. "${LIB}/plugins.sh"

# ─── 9. System checks (Docker socket, git, workspace symlinks) ──────
# shellcheck source=lib/system-checks.sh
. "${LIB}/system-checks.sh"

# ─── 10. Prefill proxy (OpenCode only) ─────────────────────────────
if [ "${OPENCODE_APP}" = "opencode" ] && [ "${PREFILL_PROXY_ENABLED}" = "true" ]; then
    _start_proxy
elif [ "${OPENCODE_APP}" = "opencode" ]; then
    echo "→ Prefill proxy disabled — connecting directly to ${LLM_BASE_URL}"
fi
echo ""

# ─── 11. Binary resolution, banner, theme, title ──────────────────
# shellcheck source=lib/runtime.sh
. "${LIB}/runtime.sh"

# ─── 12. Mode launch (tmux / tui / web) — does not return ─────────
# shellcheck source=lib/modes.sh
. "${LIB}/modes.sh"
