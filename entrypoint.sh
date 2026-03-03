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

# ─── Cron-based auto-update (every 12h) ───────────────────────────
AUTO_UPDATE_SCRIPT="/usr/local/bin/opencode-auto-update.sh"
cat > "${AUTO_UPDATE_SCRIPT}" <<'SCRIPT'
#!/bin/bash
# Auto-update opencode-ai if a newer version is available.
# Sessions are persisted on disk — the web UI reconnects after restart.
set -e

LOG_PREFIX="[opencode-auto-update]"
LOCKFILE="/tmp/opencode-update.lock"

# Prevent concurrent runs
exec 9>"${LOCKFILE}"
if ! flock -n 9; then
    echo "${LOG_PREFIX} Another update is already running, skipping."
    exit 0
fi

LATEST=$(npm view opencode-ai version 2>/dev/null || echo "unknown")
CURRENT=$(opencode --version 2>/dev/null || echo "unknown")

if [ "$LATEST" = "unknown" ] || [ "$CURRENT" = "unknown" ]; then
    echo "${LOG_PREFIX} Could not determine versions (current=${CURRENT}, latest=${LATEST}). Skipping."
    exit 0
fi

if [ "$LATEST" = "$CURRENT" ]; then
    echo "${LOG_PREFIX} Already on latest version (${CURRENT}). No update needed."
    exit 0
fi

echo ""
echo "${LOG_PREFIX} ╭───────────────────────────────────────────────╮"
echo "${LOG_PREFIX} │  ⬆  Updating opencode-ai: ${CURRENT} → ${LATEST}"
echo "${LOG_PREFIX} ╰───────────────────────────────────────────────╯"

# Install the new version globally (overwrites existing binary in-place)
if npm install -g "opencode-ai@${LATEST}" --prefer-online 2>&1 | sed "s/^/${LOG_PREFIX}   /"; then
    NEW_VER=$(opencode --version 2>/dev/null || echo "unknown")
    echo "${LOG_PREFIX} ✓ Installed opencode-ai ${NEW_VER}"
else
    echo "${LOG_PREFIX} ✗ npm install failed — keeping current version ${CURRENT}"
    exit 1
fi

# Re-create the symlink (in case the binary path shifted)
ln -sf /usr/local/lib/node_modules/opencode-ai/bin/opencode /usr/local/bin/opencode

# Restart opencode web — tini is PID 1 and entrypoint runs a restart loop,
# so killing the opencode process causes the loop to relaunch it automatically.
OPENCODE_PID=$(pgrep -f "opencode web" | head -1 || true)
if [ -n "${OPENCODE_PID}" ]; then
    echo "${LOG_PREFIX} Restarting opencode web (PID ${OPENCODE_PID})..."
    kill -TERM "${OPENCODE_PID}" 2>/dev/null || true
    sleep 5
    if pgrep -f "opencode web" > /dev/null; then
        echo "${LOG_PREFIX} ✓ opencode web restarted with v${LATEST}"
    else
        echo "${LOG_PREFIX} ⟳ Waiting for restart loop to relaunch..."
    fi
else
    echo "${LOG_PREFIX} opencode web not running — update will take effect on next start."
fi

echo ""
SCRIPT
chmod +x "${AUTO_UPDATE_SCRIPT}"

# Install cron job (every 12h) — output goes to container stdout (PID 1)
AUTOUPDATE_ENABLED="${OPENCODE_AUTOUPDATE:-true}"
if [ "${AUTOUPDATE_ENABLED}" = "true" ]; then
    echo "0 */12 * * * ${AUTO_UPDATE_SCRIPT} > /proc/1/fd/1 2>&1" | crontab -
    cron
    echo "  ✓ Auto-update cron installed (every 12h)"
else
    # Fall back to notification-only
    VERSION_CHECK_SCRIPT="/usr/local/bin/opencode-version-check.sh"
    cat > "${VERSION_CHECK_SCRIPT}" <<'VSCRIPT'
#!/bin/bash
LATEST=$(npm view opencode-ai version 2>/dev/null || echo "unknown")
CURRENT=$(opencode --version 2>/dev/null || echo "unknown")
if [ "$LATEST" != "unknown" ] && [ "$CURRENT" != "unknown" ] && [ "$LATEST" != "$CURRENT" ]; then
    echo ""
    echo "  ╭───────────────────────────────────────────────╮"
    echo "  │  ⬆  opencode-ai update available:             │"
    echo "  │     ${CURRENT} → ${LATEST}$(printf '%*s' $((30 - ${#CURRENT} - ${#LATEST})) '')│"
    echo "  │     Run: ./opencode-web.sh update              │"
    echo "  ╰───────────────────────────────────────────────╯"
    echo ""
fi
VSCRIPT
    chmod +x "${VERSION_CHECK_SCRIPT}"
    echo "0 */12 * * * ${VERSION_CHECK_SCRIPT} > /proc/1/fd/1 2>&1" | crontab -
    cron
    echo "  ✓ Version check cron installed (every 12h, notify only)"
fi

echo ""
echo "→ Starting opencode web on 0.0.0.0:${OPENCODE_PORT:-3000}..."
echo "  Access: http://localhost:${OPENCODE_PORT:-3000}"
echo ""

# ─── Start opencode web (restart loop for auto-updates) ──────────
# tini is PID 1; this loop lets the auto-update cron kill and restart
# the opencode process without stopping the container.
cd /workspace
while true; do
    opencode web \
        --hostname 0.0.0.0 \
        --port "${OPENCODE_PORT:-3000}" \
        ${OPENCODE_EXTRA_ARGS:-} || true
    echo ""
    echo "  ⟳ opencode web exited ($(date)). Restarting in 3s..."
    echo ""
    sleep 3
done
