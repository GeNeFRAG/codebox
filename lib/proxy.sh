# ─── lib/proxy.sh ───────────────────────────────────────────────────────────
# Manages both proxies:
#   - gateway-auth proxy: rotating token management (all agents)
#   - prefill proxy: assistant message stripping (OpenCode only)
#
# Gateway-auth proxy lifecycle:
#   - _start_gateway_auth_proxy: validates helper, launches proxy
#   - _restart_gateway_auth_proxy: keeps proxy alive in web mode
#
# Prefill proxy lifecycle:
#   - _start_proxy: launches the proxy, polls for readiness, warms TLS
#   - _restart_proxy: called from the web-mode restart loop

# ─── Gateway Auth Proxy ────────────────────────────────────────────

_validate_gateway_auth_helper() {
    local helper="${CODEBOX_GATEWAY_AUTH_HELPER:-rbi-sl-token}"
    local helper_path
    helper_path=$(command -v "${helper}" 2>/dev/null || true)

    if [ -z "${helper_path}" ]; then
        echo "  ✗ Token helper not found: ${helper}" >&2
        if [ -z "${LLM_API_KEY:-}" ]; then
            echo "  ✗ FATAL: No static LLM_API_KEY available as fallback" >&2
            return 1
        fi
        echo "  ⚠ Will fall back to static LLM_API_KEY"
    elif [ ! -x "${helper_path}" ]; then
        echo "  ✗ Token helper not executable: ${helper_path}" >&2
        if [ -z "${LLM_API_KEY:-}" ]; then
            echo "  ✗ FATAL: No static LLM_API_KEY available as fallback" >&2
            return 1
        fi
        echo "  ⚠ Will fall back to static LLM_API_KEY"
    else
        echo "  ✓ Token helper found: ${helper}"
    fi
    return 0
}

_spawn_gateway_auth_proxy() {
    UPSTREAM_URL="${LLM_BASE_URL}" \
    CODEBOX_GATEWAY_AUTH_PORT="${CODEBOX_GATEWAY_AUTH_PORT:-18081}" \
    CODEBOX_GATEWAY_AUTH_TIMEOUT="${CODEBOX_GATEWAY_AUTH_TIMEOUT:-120}" \
    CODEBOX_GATEWAY_AUTH_HELPER="${CODEBOX_GATEWAY_AUTH_HELPER:-rbi-sl-token}" \
    CODEBOX_GATEWAY_AUTH_CACHE_TTL="${CODEBOX_GATEWAY_AUTH_CACHE_TTL:-3300}" \
    CODEBOX_GATEWAY_AUTH_LOG_LEVEL="${CODEBOX_GATEWAY_AUTH_LOG_LEVEL:-info}" \
        node /opt/opencode/proxy/gateway-auth-proxy.mjs &
    GATEWAY_AUTH_PROXY_PID=$!
}

_start_gateway_auth_proxy() {
    echo "→ Starting gateway-auth proxy on 127.0.0.1:${CODEBOX_GATEWAY_AUTH_PORT:-18081} → ${LLM_BASE_URL}..."

    # Validate helper availability
    if ! _validate_gateway_auth_helper; then
        return 1
    fi

    _spawn_gateway_auth_proxy

    # Poll for readiness (TCP connect check)
    local _ready=false
    local _port="${CODEBOX_GATEWAY_AUTH_PORT:-18081}"
    for _i in $(seq 1 25); do
        if ! kill -0 "${GATEWAY_AUTH_PROXY_PID}" 2>/dev/null; then
            break  # process died
        fi
        if (exec 3<>/dev/tcp/127.0.0.1/"${_port}") 2>/dev/null; then
            _ready=true
            break
        fi
        sleep 0.2
    done

    if [ "${_ready}" = "true" ]; then
        echo "  ✓ Gateway-auth proxy running (PID ${GATEWAY_AUTH_PROXY_PID})"
        # Set effective URL for all agents and distinguish a live listener
        # from the deterministic URL precomputed during config generation.
        export LLM_GATEWAY_AUTH_URL="http://127.0.0.1:${_port}"
        export GATEWAY_AUTH_PROXY_READY=true
        return 0
    else
        echo "  ✗ Gateway-auth proxy failed to start" >&2
        unset GATEWAY_AUTH_PROXY_PID
        unset GATEWAY_AUTH_PROXY_READY
        return 1
    fi
}

_restart_gateway_auth_proxy() {
    local _port="${CODEBOX_GATEWAY_AUTH_PORT:-18081}"
    if [ -z "${GATEWAY_AUTH_PROXY_PID:-}" ] || ! kill -0 "${GATEWAY_AUTH_PROXY_PID}" 2>/dev/null; then
        echo "  ⟳ Gateway-auth proxy not running — restarting..."
        _spawn_gateway_auth_proxy
        sleep 1
        if kill -0 "${GATEWAY_AUTH_PROXY_PID}" 2>/dev/null; then
            echo "  ✓ Gateway-auth proxy restarted (PID ${GATEWAY_AUTH_PROXY_PID})"
            export LLM_GATEWAY_AUTH_URL="http://127.0.0.1:${_port}"
            export GATEWAY_AUTH_PROXY_READY=true
        else
            echo "  ✗ Gateway-auth proxy failed to restart"
            unset GATEWAY_AUTH_PROXY_PID
            unset GATEWAY_AUTH_PROXY_READY
        fi
    fi
}

# ─── Prefill Proxy (OpenCode only) ──────────────────────────────────

_spawn_proxy() {
    # When gateway-auth proxy is enabled, prefill forwards to it instead of LLM_BASE_URL
    local upstream="${LLM_BASE_URL}"
    if [ -n "${LLM_GATEWAY_AUTH_URL:-}" ]; then
        upstream="${LLM_GATEWAY_AUTH_URL}"
        echo "  → Prefill proxy will forward to gateway-auth proxy"
    fi

    UPSTREAM_URL="${upstream}" PROXY_PORT=18080 \
        node /opt/opencode/proxy/prefill-proxy.mjs &
    PROXY_PID=$!
}

_start_proxy() {
    echo "→ Starting prefill proxy on 127.0.0.1:18080 → ${LLM_BASE_URL}..."
    _spawn_proxy

    # Poll for readiness instead of a fixed sleep (up to 5s).
    #
    # A TCP connect is all that "is the listener up?" requires, and unlike an
    # HTTP GET it never leaves the container. The previous check curled
    # /models with no Authorization header, so the proxy dutifully forwarded
    # it and every single start blocked ~4s waiting for the gateway to answer
    # 401 — a request whose response was discarded either way.
    #
    # Upstream TCP+TLS still gets warmed below, with credentials, in ~50ms.
    _proxy_ready=false
    for _i in $(seq 1 25); do
        if ! kill -0 "${PROXY_PID}" 2>/dev/null; then
            break  # process died
        fi
        if (exec 3<>/dev/tcp/127.0.0.1/18080) 2>/dev/null; then
            _proxy_ready=true
            break
        fi
        sleep 0.2
    done

    if [ "${_proxy_ready}" = "true" ]; then
        echo "  ✓ Prefill proxy running (PID ${PROXY_PID})"
        # Warm up TLS — establish the keep-alive connection to upstream now so
        # the first real user request doesn't pay the TCP+TLS handshake cost.
        curl -s -o /dev/null -w "  ✓ TLS connection warmed up (%{time_connect}s tcp, %{time_appconnect}s tls)\n" \
            -H "Authorization: Bearer ${LLM_API_KEY}" \
            "http://127.0.0.1:18080/models" 2>/dev/null || true
    else
        echo "  ✗ Prefill proxy failed to start — falling back to direct connection"
        unset PROXY_PID
        # Re-generate config to point directly at the upstream URL
        export LLM_EFFECTIVE_URL="${LLM_BASE_URL}"
        if ! _generate_config; then
            echo "  ✗ FATAL: Config regeneration failed" >&2
            exit 1
        fi
    fi
}

# ── Proxy liveness helpers (web mode only) ────────────────────────
_restart_proxy() {
    if [ "${PREFILL_PROXY_ENABLED}" = "true" ]; then
        if [ -z "${PROXY_PID:-}" ] || ! kill -0 "${PROXY_PID}" 2>/dev/null; then
            echo "  ⟳ Prefill proxy not running — restarting..."
            _spawn_proxy
            sleep 1
            if kill -0 "${PROXY_PID}" 2>/dev/null; then
                echo "  ✓ Prefill proxy restarted (PID ${PROXY_PID})"
            else
                echo "  ✗ Prefill proxy failed to restart — continuing without proxy"
                unset PROXY_PID
            fi
        fi
    fi
}

# Called from modes.sh web-mode restart loop
_restart_both_proxies() {
    if [ "${GATEWAY_AUTH_PROXY_ENABLED:-false}" = "true" ]; then
        _restart_gateway_auth_proxy
    fi
    _restart_proxy
}
