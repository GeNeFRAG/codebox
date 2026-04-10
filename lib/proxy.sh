# ─── lib/proxy.sh ───────────────────────────────────────────────────────────
# Manages the prefill proxy (OpenCode only).
#   - _start_proxy: launches the proxy, polls for readiness, warms TLS
#   - _restart_proxy: called from the web-mode restart loop to ensure the
#     proxy is still alive between opencode restarts

_start_proxy() {
    echo "→ Starting prefill proxy on 127.0.0.1:18080 → ${LLM_BASE_URL}..."
    UPSTREAM_URL="${LLM_BASE_URL}" PROXY_PORT=18080 \
        node /opt/opencode/proxy/prefill-proxy.mjs &
    PROXY_PID=$!

    # Poll for readiness instead of a fixed sleep (up to 5s)
    _proxy_ready=false
    for _i in $(seq 1 10); do
        if ! kill -0 "${PROXY_PID}" 2>/dev/null; then
            break  # process died
        fi
        if curl -s -o /dev/null "http://127.0.0.1:18080/models" 2>/dev/null; then
            _proxy_ready=true
            break
        fi
        sleep 0.5
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
        _generate_config
    fi
}

# ── Proxy liveness helper (web mode only) ─────────────────────────
_restart_proxy() {
    if [ "${PREFILL_PROXY_ENABLED}" = "true" ]; then
        if [ -z "${PROXY_PID:-}" ] || ! kill -0 "${PROXY_PID}" 2>/dev/null; then
            echo "  ⟳ Prefill proxy not running — restarting..."
            UPSTREAM_URL="${LLM_BASE_URL}" PROXY_PORT=18080 \
                node /opt/opencode/proxy/prefill-proxy.mjs &
            PROXY_PID=$!
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
