#!/bin/bash
set -e

CONFIG_DIR="/root/.config/opencode"
DATA_DIR="/root/.local/share/opencode"
TEMPLATE="/opt/opencode/opencode.json.template"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"

OPENCODE_VER=$(opencode --version 2>/dev/null || echo "unknown")
echo "╔══════════════════════════════════════════╗"
echo "║       OpenCode Web - Docker Container    ║"
echo "║       opencode-ai v${OPENCODE_VER}$(printf '%*s' $((22 - ${#OPENCODE_VER})) '')║"
echo "╚══════════════════════════════════════════╝"

# ─── Generate opencode.json from template + env vars ───────────────
echo "→ Generating opencode.json from template..."

# Resolve CA_CERT_PATH to the absolute host path for sibling Docker containers.
# docker-compose mounts $CA_CERT_PATH → /certs/ca-bundle.pem inside this container,
# but MCP servers run as sibling containers via the Docker socket, so they need the
# actual host path. We discover it by inspecting our own container's mounts.
if [ -f /certs/ca-bundle.pem ] && [ -s /certs/ca-bundle.pem ]; then
    HOST_CA_PATH=$(docker inspect "$(hostname)" 2>/dev/null \
        | node -e "const j=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); \
           const m=j[0]?.Mounts?.find(m=>m.Destination==='/certs/ca-bundle.pem'); \
           console.log(m?.Source||'')" 2>/dev/null || true)
    if [ -n "${HOST_CA_PATH}" ]; then
        export CA_CERT_PATH="${HOST_CA_PATH}"
    else
        export CA_CERT_PATH="/dev/null"
    fi
else
    export CA_CERT_PATH="/dev/null"
fi

# ─── LLM Gateway health check — fallback model if unreachable ──────
if [ -n "${LLM_BASE_URL}" ] && [ -n "${OPENCODE_MODEL_FALLBACK}" ]; then
    MODELS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -H "Authorization: Bearer ${LLM_API_KEY}" "${LLM_BASE_URL}/models" 2>/dev/null || echo "000")
    echo "  → LLM gateway check: /models=${MODELS_CODE}"
    if [[ "${MODELS_CODE}" =~ ^(2|3) ]]; then
        echo "  ✓ LLM gateway reachable (${LLM_BASE_URL}) — using ${OPENCODE_MODEL}"
    else
        echo "  ⚠ LLM gateway unhealthy (${LLM_BASE_URL}) — falling back to ${OPENCODE_MODEL_FALLBACK}"
        export OPENCODE_MODEL="${OPENCODE_MODEL_FALLBACK}"
        # Disable prefill proxy — it only applies to the LLM gateway
        export PREFILL_PROXY="false"
    fi
else
    [ -z "${LLM_BASE_URL}" ] && echo "  → LLM gateway check skipped (LLM_BASE_URL not set)"
    [ -z "${OPENCODE_MODEL_FALLBACK}" ] && echo "  → LLM gateway check skipped (OPENCODE_MODEL_FALLBACK not set)"
fi

# Only substitute our known variables (avoids clobbering $schema etc.)
# Determine the effective LLM URL based on whether the prefill proxy is enabled.
# The proxy hasn't started yet, but the URL is deterministic — we'll verify later.
PREFILL_PROXY_ENABLED="${PREFILL_PROXY:-true}"
if [ "${PREFILL_PROXY_ENABLED}" = "true" ]; then
    export LLM_EFFECTIVE_URL="http://127.0.0.1:18080"
else
    export LLM_EFFECTIVE_URL="${LLM_BASE_URL}"
fi

envsubst '${LLM_EFFECTIVE_URL} ${LLM_BASE_URL} ${LLM_API_KEY} ${OPENROUTER_API_KEY} ${OPENCODE_MODEL} ${GITHUB_ENTERPRISE_TOKEN} ${GITHUB_ENTERPRISE_URL} ${GITHUB_PERSONAL_TOKEN} ${CONFLUENCE_URL} ${CONFLUENCE_USERNAME} ${CONFLUENCE_TOKEN} ${JIRA_URL} ${JIRA_USERNAME} ${JIRA_TOKEN} ${GRAFANA_URL} ${GRAFANA_API_KEY} ${CA_CERT_PATH}' \
    < "${TEMPLATE}" > "${CONFIG_FILE}"

echo "  ✓ Config written to ${CONFIG_FILE}"

# ─── Generate auth.json if API key is set ──────────────────────────
AUTH_FILE="${DATA_DIR}/auth.json"
if [ -n "${LLM_API_KEY}" ]; then
    echo "→ Writing auth.json..."
    cat > "${AUTH_FILE}" <<EOF
{
  "anthropic": {
    "type": "api",
    "key": "${LLM_API_KEY}"
  },
  "llm": {
    "type": "api",
    "key": "${LLM_API_KEY}"
  }
}
EOF
    echo "  ✓ Auth configured"
fi

# ─── Merge host auth.json (Copilot tokens etc.) ───────────────────
# The host's ~/.local/share/opencode/auth.json is mounted read-only at
# /opt/opencode/host-auth.json. Any providers in the host file that are
# NOT already in the container's auth.json get merged in (host entries
# never overwrite container entries like "llm" or "anthropic").
HOST_AUTH="/opt/opencode/host-auth.json"
if [ -f "${HOST_AUTH}" ] && [ -s "${HOST_AUTH}" ] && [ -f "${AUTH_FILE}" ]; then
    MERGED=$(jq -s '.[0] * .[1]' \
        "${HOST_AUTH}" "${AUTH_FILE}" 2>/dev/null) || true
    if [ -n "${MERGED}" ]; then
        # Count how many keys the host added
        HOST_KEYS=$(jq -r 'keys[]' "${HOST_AUTH}" 2>/dev/null | grep -v -F -x -f <(jq -r 'keys[]' "${AUTH_FILE}" 2>/dev/null) || true)
        if [ -n "${HOST_KEYS}" ]; then
            echo "${MERGED}" > "${AUTH_FILE}"
            echo "  ✓ Merged host auth providers: $(echo "${HOST_KEYS}" | tr '\n' ', ' | sed 's/,$//')"
        fi
    fi
elif [ -f "${HOST_AUTH}" ] && [ -s "${HOST_AUTH}" ] && [ ! -f "${AUTH_FILE}" ]; then
    cp "${HOST_AUTH}" "${AUTH_FILE}"
    echo "  ✓ Using host auth.json (no local auth configured)"
fi

# ─── Handle corporate CA certificates ──────────────────────────────
# docker-compose mounts the host cert to /certs/ca-bundle.pem
CA_CERT="/certs/ca-bundle.pem"
if [ -f "${CA_CERT}" ] && [ "${CA_CERT}" != "/dev/null" ] && [ -s "${CA_CERT}" ]; then
    echo "→ Installing corporate CA certificate..."
    cp "${CA_CERT}" /usr/local/share/ca-certificates/custom-ca.crt
    update-ca-certificates 2>/dev/null
    export NODE_EXTRA_CA_CERTS="${CA_CERT}"
    export REQUESTS_CA_BUNDLE="${CA_CERT}"
    echo "  ✓ CA certificate installed"
fi

# ─── Install opencode plugins if package.json exists ───────────────
if [ -f "${CONFIG_DIR}/package.json" ]; then
    echo "→ Ensuring opencode plugins are installed..."
    cd "${CONFIG_DIR}" && npm install --prefer-offline --no-audit --no-fund 2>/dev/null
    echo "  ✓ Plugins ready"
fi

# ─── Ensure .opencode project config is available ──────────────────
if [ -d "/workspace/.opencode" ]; then
    echo "  ✓ Project .opencode directory found"
fi

# ─── Docker socket check (for MCP servers) ────────────────────────
if [ -S "/var/run/docker.sock" ]; then
    echo "  ✓ Docker socket available (MCP containers supported)"
else
    echo "  ⚠ Docker socket not mounted - Docker-based MCP servers will not work"
fi

# ─── Git configuration ────────────────────────────────────────────
# Host .gitconfig is mounted read-only; use env vars to add safe.directory
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="safe.directory"
export GIT_CONFIG_VALUE_0="/workspace"

# Validate .git-credentials mount
GIT_CRED="/root/.git-credentials"
if [ -d "${GIT_CRED}" ]; then
    echo "  ⚠ ${GIT_CRED} is a directory (host file missing?) — HTTPS push credentials unavailable"
    echo "    Set GIT_CREDENTIALS_PATH in .env to your credentials file, or leave unset to disable"
elif [ -f "${GIT_CRED}" ] && [ -s "${GIT_CRED}" ]; then
    echo "  ✓ Git credentials available (HTTPS push supported)"
fi

# ─── Expose /workspace under $HOME for "Open project" dialog ──────
# The web UI searches $HOME for project directories. Inside Docker,
# /root only has dotfiles which are filtered out, so the dialog is
# empty. Symlinking /workspace into $HOME makes it discoverable.
WORKSPACE_NAME="$(basename "$(cd /workspace && git rev-parse --show-toplevel 2>/dev/null || echo /workspace)")"
if [ ! -e "${HOME}/${WORKSPACE_NAME}" ]; then
    ln -sf /workspace "${HOME}/${WORKSPACE_NAME}"
    echo "  ✓ Symlinked /workspace → ~/${WORKSPACE_NAME}"
fi

# ─── Start prefill proxy (strips trailing assistant messages) ─────
if [ "${PREFILL_PROXY_ENABLED}" = "true" ]; then
    echo "→ Starting prefill proxy on 127.0.0.1:18080 → ${LLM_BASE_URL}..."
    UPSTREAM_URL="${LLM_BASE_URL}" PROXY_PORT=18080 \
        node /opt/opencode/prefill-proxy.mjs &
    PROXY_PID=$!
    sleep 1

    if kill -0 "${PROXY_PID}" 2>/dev/null; then
        echo "  ✓ Prefill proxy running (PID ${PROXY_PID})"
        # Warm up TLS — establish the keep-alive connection to upstream now so
        # the first real user request doesn't pay the TCP+TLS handshake cost.
        curl -s -o /dev/null -w "  ✓ TLS connection warmed up (%{time_connect}s tcp, %{time_appconnect}s tls)\n" \
            -H "Authorization: Bearer ${LLM_API_KEY}" \
            "http://127.0.0.1:18080/models" 2>/dev/null || true
    else
        echo "  ✗ Prefill proxy failed to start — falling back to direct connection"
        # Re-generate config to point directly at the upstream URL
        export LLM_EFFECTIVE_URL="${LLM_BASE_URL}"
        envsubst '${LLM_EFFECTIVE_URL} ${LLM_BASE_URL} ${LLM_API_KEY} ${OPENROUTER_API_KEY} ${OPENCODE_MODEL} ${GITHUB_ENTERPRISE_TOKEN} ${GITHUB_ENTERPRISE_URL} ${GITHUB_PERSONAL_TOKEN} ${CONFLUENCE_URL} ${CONFLUENCE_USERNAME} ${CONFLUENCE_TOKEN} ${JIRA_URL} ${JIRA_USERNAME} ${JIRA_TOKEN} ${GRAFANA_URL} ${GRAFANA_API_KEY} ${CA_CERT_PATH}' \
            < "${TEMPLATE}" > "${CONFIG_FILE}"
    fi
else
    echo "→ Prefill proxy disabled — connecting directly to ${LLM_BASE_URL}"
fi
echo ""

# ─── Mode selection ───────────────────────────────────────────────
# OPENCODE_MODE=web  (default) — opencode web UI served on OPENCODE_PORT
# OPENCODE_MODE=tui            — opencode TUI exposed via ttyd on OPENCODE_PORT
# OPENCODE_MODE=tmux           — opencode TUI inside tmux, exposed via ttyd
#                                 (persistent session survives browser disconnects)
OPENCODE_MODE="${OPENCODE_MODE:-web}"
TMUX_SESSION="opencode"

# ── Proxy liveness helper (web mode only) ─────────────────────────
_restart_proxy() {
    if [ "${PREFILL_PROXY_ENABLED}" = "true" ]; then
        if ! kill -0 "${PROXY_PID:-0}" 2>/dev/null; then
            echo "  ⟳ Prefill proxy not running — restarting..."
            UPSTREAM_URL="${LLM_BASE_URL}" PROXY_PORT=18080 \
                node /opt/opencode/prefill-proxy.mjs &
            PROXY_PID=$!
            sleep 1
            if kill -0 "${PROXY_PID}" 2>/dev/null; then
                echo "  ✓ Prefill proxy restarted (PID ${PROXY_PID})"
            else
                echo "  ✗ Prefill proxy failed to restart — continuing without proxy"
            fi
        fi
    fi
}

cd /workspace

if [ "${OPENCODE_MODE}" = "tmux" ]; then
    # ── tmux mode: run opencode inside tmux, served by ttyd ──────
    # Architecture: ttyd → wrapper script → tmux new/attach → opencode
    #
    # Key insight: ttyd negotiates terminal dimensions with the browser
    # BEFORE spawning the child process. By deferring tmux session
    # creation to the wrapper script (which ttyd spawns), the session
    # inherits the correct terminal size from the start — no hooks,
    # no polling, no race conditions.
    #
    # Browser disconnects don't kill the tmux session; reopening the
    # URL reattaches instantly.

    # Apply custom tmux config if mounted
    if [ -f "/root/.config/opencode/tmux.conf" ]; then
        cp /root/.config/opencode/tmux.conf /root/.tmux.conf
        echo "  ✓ Custom tmux.conf applied"
    fi

    echo "→ Starting opencode TUI via tmux + ttyd on 0.0.0.0:${OPENCODE_PORT:-3000}..."
    echo "  Access: http://localhost:${OPENCODE_PORT:-3000}"
    echo "  Attach: docker exec -it <container> tmux attach -t ${TMUX_SESSION}"
    echo ""

    # Write the tmux wrapper script. ttyd executes this on each browser
    # connection. Terminal dimensions are already correct at this point.
    cat > /tmp/tmux-wrapper.sh <<'WRAPPER'
#!/bin/bash
TMUX_SESSION="opencode"
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    # Session exists (reconnection or browser refresh) — just attach.
    exec tmux attach -t "$TMUX_SESSION"
else
    # First connection — create session with correct terminal dimensions.
    # ttyd has already negotiated the real browser size, so $COLUMNS/$LINES
    # (or tput) reflect the actual dimensions. Create the layout first,
    # then start opencode so it renders with the correct dimensions.
    COLS=$(tput cols  2>/dev/null || echo 180)
    ROWS=$(tput lines 2>/dev/null || echo 50)
    # Create empty session with correct dimensions
    tmux new-session -d -s "$TMUX_SESSION" -x "$COLS" -y "$ROWS" -c /workspace
    # Split window for agent monitor (25% height at bottom)
    tmux split-window -t "$TMUX_SESSION" -v -l 25% -c /workspace \
        "printf '\033]2;agent-monitor\033\\' && bash /opt/opencode/agent-monitor.sh"
    # Focus back to main pane and start opencode there
    tmux select-pane -t "$TMUX_SESSION":0.0
    tmux send-keys -t "$TMUX_SESSION":0.0 \
        "while true; do /usr/local/bin/opencode EXTRA_ARGS_PLACEHOLDER; echo ''; echo '  ⟳ opencode exited. Restarting in 3s...'; echo ''; sleep 3; done" C-m
    exec tmux attach -t "$TMUX_SESSION"
fi
WRAPPER
    sed -i "s|EXTRA_ARGS_PLACEHOLDER|${OPENCODE_EXTRA_ARGS:-}|" /tmp/tmux-wrapper.sh
    chmod +x /tmp/tmux-wrapper.sh

    # ttyd serves the wrapper. If ttyd crashes, restart it.
    # The tmux session persists independently across ttyd restarts.
    while true; do
        ttyd \
            --port "${OPENCODE_PORT:-3000}" \
            --interface 0.0.0.0 \
            --writable \
            ${OPENCODE_TUI_ARGS:-} \
            /tmp/tmux-wrapper.sh || true
        sleep 3
    done

elif [ "${OPENCODE_MODE}" = "tui" ]; then
    # ── TUI mode: opencode TUI served directly by ttyd ───────────
    echo "→ Starting opencode TUI via ttyd on 0.0.0.0:${OPENCODE_PORT:-3000}..."
    echo "  Access: http://localhost:${OPENCODE_PORT:-3000}"
    echo ""

    # Restart loop — if opencode or ttyd exits, restart after 3s.
    while true; do
        ttyd \
            --port "${OPENCODE_PORT:-3000}" \
            --interface 0.0.0.0 \
            --writable \
            --cwd /workspace \
            ${OPENCODE_TUI_ARGS:-} \
            opencode ${OPENCODE_EXTRA_ARGS:-} || true
        echo ""
        echo "  ⟳ ttyd exited ($(date)). Restarting in 3s..."
        echo ""
        sleep 3
    done

else
    # ── Web mode (default): opencode web UI ──────────────────────
    echo "→ Starting opencode web on 0.0.0.0:${OPENCODE_PORT:-3000}..."
    echo "  Access: http://localhost:${OPENCODE_PORT:-3000}"
    echo ""

    while true; do
        /usr/local/bin/opencode web \
            --hostname 0.0.0.0 \
            --port "${OPENCODE_PORT:-3000}" \
            ${OPENCODE_EXTRA_ARGS:-} || true
        echo ""
        echo "  ⟳ opencode web exited ($(date)). Restarting in 3s..."
        echo ""

        _restart_proxy
        sleep 3
    done
fi
