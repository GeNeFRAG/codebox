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

# Prefix for phase-boundary log lines — makes it easy to see where time goes.
_ts() { date '+%H:%M:%S'; }

# ─── 1. Load .env and warn about non-reloadable changes ────────────
# shellcheck source=lib/env.sh
. "${LIB}/env.sh"

# ─── 2. Coding agent selection ─────────────────────────────────────
# CODEBOX_APP selects which coding agent to run:
#   opencode    (default) — OpenCode AI agent
#   claude-code           — Anthropic Claude Code agent
#   pi                    — Pi coding agent (pi.dev)
CODEBOX_APP="${CODEBOX_APP:-opencode}"
case "${CODEBOX_APP}" in
    claude-code)
        APP_TITLE_PREFIX="Claude Code"
        ;;
    pi)
        APP_TITLE_PREFIX="Pi"
        ;;
    opencode|*)
        APP_TITLE_PREFIX="OpenCode"
        ;;
esac

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

# ─── 3b. Docker self-destruct guard ────────────────────────────────
# The same socket that lets MCP servers run as sibling containers lets
# anything in here stop or remove this container. Put the guard shim on
# PATH before any user-reachable shell exists. Read-only docker calls in
# the phases below (system-checks, runtime) pass through untouched.
# shellcheck source=lib/docker-guard.sh
. "${LIB}/docker-guard.sh"
_install_docker_guard

# ─── 4. Cleanup on SIGTERM (reap background proxies) ───────────────
# shellcheck source=lib/proxy.sh
. "${LIB}/proxy.sh"
_cleanup() {
    [ -n "${GATEWAY_AUTH_PROXY_PID:-}" ] && kill "${GATEWAY_AUTH_PROXY_PID}" 2>/dev/null
    [ -n "${PROXY_PID:-}" ] && kill "${PROXY_PID}" 2>/dev/null
    exit 0
}
trap _cleanup SIGTERM SIGINT

# ─── 5. Corporate CA certificate ───────────────────────────────────
# Install before both the gateway-auth proxy and direct model discovery. Node
# reads NODE_EXTRA_CA_CERTS at process startup, so installing it later would
# leave the early proxy unable to trust an intercepted gateway certificate.
# shellcheck source=lib/ca-cert.sh
. "${LIB}/ca-cert.sh"

# ─── 6. Gateway-auth proxy (all agents, opt-in) ────────────────────
# shellcheck source=lib/config.sh
. "${LIB}/config.sh"

# Start before config generation: discovery calls /v1/models and must use the
# same rotating credential as ordinary agent traffic.
export GATEWAY_AUTH_PROXY_ENABLED="${CODEBOX_GATEWAY_AUTH_PROXY:-false}"
if [ "${GATEWAY_AUTH_PROXY_ENABLED}" = "true" ]; then
    echo "── $(_ts) gateway-auth-proxy"
    if ! _start_gateway_auth_proxy; then
        echo "✗ FATAL: Gateway-auth proxy startup failed" >&2
        echo "  Set CODEBOX_GATEWAY_AUTH_PROXY=false to connect directly" >&2
        exit 1
    fi
fi

# ─── 7. App-specific configuration ─────────────────────────────────
echo "── $(_ts) config"
# This is also needed without the proxy, and is idempotent when its live URL
# was set by _start_gateway_auth_proxy above.
if ! _compute_gateway_auth_url; then
    echo "✗ FATAL: Gateway-auth proxy configuration validation failed" >&2
    exit 1
fi

case "${CODEBOX_APP}" in
    claude-code)
        echo "→ Configuring Claude Code..."
        export PREFILL_PROXY_ENABLED=false
        if ! _generate_claude_code_config; then
            echo "✗ FATAL: Claude Code configuration failed" >&2
            exit 1
        fi
        ;;
    pi)
        echo "→ Configuring Pi..."
        export PREFILL_PROXY_ENABLED=false
        if ! _configure_pi; then
            echo "✗ FATAL: Pi configuration failed" >&2
            exit 1
        fi
        ;;
    *)
        if ! _configure_opencode; then
            echo "✗ FATAL: OpenCode configuration failed" >&2
            exit 1
        fi
        ;;
esac
_generate_atl_config

# ─── 8. TLS certificate for ttyd (tui/tmux clipboard support) ──────
# shellcheck source=lib/tls.sh
. "${LIB}/tls.sh"

# ─── 9. OpenCode plugins ────────────────────────────────────────────
echo "── $(_ts) plugins"
# shellcheck source=lib/plugins.sh
. "${LIB}/plugins.sh"

# ─── 10. System checks (Docker socket, git, workspace symlinks) ─────
echo "── $(_ts) system-checks"
# shellcheck source=lib/system-checks.sh
. "${LIB}/system-checks.sh"

# ─── 10b. Playwright browsers (opt-in, per container) ─────────────
echo "── $(_ts) playwright"
# shellcheck source=lib/playwright.sh
. "${LIB}/playwright.sh"
_install_playwright

# ─── 11. Prefill proxy (OpenCode only) ─────────────────────────────
# The gateway-auth proxy started before config generation so model discovery can use its
# rotating credentials. It remains supervised by the normal web-mode loop.

if [ "${CODEBOX_APP}" = "opencode" ] && [ "${PREFILL_PROXY_ENABLED}" = "true" ]; then
    echo "── $(_ts) prefill-proxy"
    if ! _start_proxy; then
        echo "✗ FATAL: Proxy startup and fallback failed" >&2
        exit 1
    fi
elif [ "${CODEBOX_APP}" = "opencode" ]; then
    echo "→ Prefill proxy disabled — connecting directly"
fi
echo ""

# ─── 12. Binary resolution, banner, theme, title ──────────────────
echo "── $(_ts) runtime"
# shellcheck source=lib/runtime.sh
. "${LIB}/runtime.sh"

# ─── 13. Mode launch (tmux / tui / web) — does not return ─────────
echo "── $(_ts) launching ${CODEBOX_APP:-opencode} (${CODEBOX_MODE:-web})"
# shellcheck source=lib/modes.sh
. "${LIB}/modes.sh"
