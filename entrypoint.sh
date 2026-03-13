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

# ─── Reload .env from mounted file (picks up changes on stop/start) ─
_load_env_file() {
    local env_file="$1"
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip blank lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Strip optional 'export' prefix and any surrounding whitespace
        if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+(.*) ]]; then
            line="${BASH_REMATCH[1]}"
        fi
        # Extract KEY and VALUE on first '='
        local key="${line%%=*}"
        local value="${line#*=}"
        # Validate key is a legal variable name
        [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue
        # Strip surrounding quotes from value (matching pairs only)
        if [[ "$value" =~ ^\"(.*)\"$ ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        export "$key=$value"
    done < "$env_file"
}

_ORIG_PORT="${OPENCODE_PORT:-}"

if [ -f /opt/opencode/.env ] && [ -s /opt/opencode/.env ]; then
    _load_env_file /opt/opencode/.env
    echo "→ Reloaded environment from /opt/opencode/.env"
elif [ -f /workspace/.env ] && [ -s /workspace/.env ]; then
    _load_env_file /workspace/.env
    echo "→ Reloaded environment from /workspace/.env"
else
    echo "→ No .env file found (using container environment)"
fi

# ─── Warn about non-reloadable changes ─────────────────────────────
if [ "${OPENCODE_PORT:-}" != "${_ORIG_PORT}" ]; then
    if [ -n "${_ORIG_PORT}" ]; then
        echo "  ⚠ OPENCODE_PORT changed (${_ORIG_PORT} → ${OPENCODE_PORT}) — requires 'docker compose up' or './opencode-web.sh rebuild' to take effect"
        export OPENCODE_PORT="${_ORIG_PORT}"
    else
        echo "  ⚠ OPENCODE_PORT set to ${OPENCODE_PORT} via .env but port mapping was not configured at container creation — requires 'docker compose up' to take effect"
        unset OPENCODE_PORT
    fi
fi
unset _ORIG_PORT

CONFIG_DIR="/root/.config/opencode"
DATA_DIR="/root/.local/share/opencode"
TEMPLATE="/opt/opencode/opencode.json.template"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"

# ─── Reusable config generation (called on startup + proxy fallback) ─
_generate_config() {
    envsubst '${LLM_EFFECTIVE_URL} ${LLM_BASE_URL} ${LLM_API_KEY} ${OPENROUTER_API_KEY} ${OPENCODE_MODEL} ${GITHUB_ENTERPRISE_TOKEN} ${GITHUB_ENTERPRISE_URL} ${GITHUB_PERSONAL_TOKEN} ${CONFLUENCE_URL} ${CONFLUENCE_USERNAME} ${CONFLUENCE_TOKEN} ${JIRA_URL} ${JIRA_USERNAME} ${JIRA_TOKEN} ${GRAFANA_URL} ${GRAFANA_API_KEY} ${CA_CERT_PATH}' \
        < "${TEMPLATE}" > "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
    if [ ! -s "${CONFIG_FILE}" ]; then
        echo "  ✗ FATAL: Config generation failed (${CONFIG_FILE} is empty)"
        exit 1
    fi
}

# ─── Cleanup on SIGTERM (reap background proxy) ───────────────────
_cleanup() {
    [ -n "${PROXY_PID:-}" ] && kill "${PROXY_PID}" 2>/dev/null
    exit 0
}
trap _cleanup SIGTERM SIGINT

# ─── Generate opencode.json from template + env vars ───────────────
echo "→ Generating opencode.json from template..."

# Resolve CA_CERT_PATH to the absolute host path for sibling Docker containers.
# Compose mounts CA_CERT_PATH → /certs/ca-bundle.pem inside this container,
# but MCP servers run as sibling containers via the Docker socket, so their
# -v flags need the real host path. The user may have used ~ in .env, which
# Compose expands for volume mounts but NOT for environment variables.
# We resolve the actual host path from our own container's mount metadata.
if [ -f /certs/ca-bundle.pem ] && [ -s /certs/ca-bundle.pem ]; then
    HOST_CA_PATH=$(docker inspect "$(hostname)" \
        --format '{{range .Mounts}}{{if eq .Destination "/certs/ca-bundle.pem"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null || true)
    if [ -n "${HOST_CA_PATH}" ]; then
        export CA_CERT_PATH="${HOST_CA_PATH}"
    fi
    # If docker inspect failed (no socket?), fall through with the .env value as-is
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

_generate_config
echo "  ✓ Config written to ${CONFIG_FILE}"

# ─── Generate auth.json if API key is set ──────────────────────────
AUTH_FILE="${DATA_DIR}/auth.json"
if [ -n "${LLM_API_KEY}" ]; then
    echo "→ Writing auth.json..."
    jq -n --arg key "${LLM_API_KEY}" \
        '{"anthropic":{"type":"api","key":$key},"llm":{"type":"api","key":$key}}' \
        > "${AUTH_FILE}"
    echo "  ✓ Auth configured"
fi

# ─── Merge host auth.json (Copilot tokens etc.) ───────────────────
# The host's ~/.local/share/opencode/auth.json is mounted read-only at
# /opt/opencode/host-auth.json. Any providers in the host file that are
# NOT already in the container's auth.json get merged in (host entries
# never overwrite container entries like "llm" or "anthropic").
HOST_AUTH="/opt/opencode/host-auth.json"
if ! command -v jq &>/dev/null; then
    echo "  ⚠ jq not available — skipping host auth merge"
elif [ -f "${HOST_AUTH}" ] && [ -s "${HOST_AUTH}" ] && [ -f "${AUTH_FILE}" ]; then
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
if [ -f "${CA_CERT}" ] && [ -s "${CA_CERT}" ]; then
    echo "→ Installing corporate CA certificate..."
    cp "${CA_CERT}" /usr/local/share/ca-certificates/custom-ca.crt 2>/dev/null || true
    update-ca-certificates 2>/dev/null || true
    export NODE_EXTRA_CA_CERTS="${CA_CERT}"
    export REQUESTS_CA_BUNDLE="${CA_CERT}"
    echo "  ✓ CA certificate installed"
fi

# ─── Install opencode plugins if package.json exists ───────────────
if [ -f "${CONFIG_DIR}/package.json" ]; then
    echo "→ Ensuring opencode plugins are installed..."
    if (cd "${CONFIG_DIR}" && npm install --prefer-offline --no-audit --no-fund 2>/dev/null); then
        echo "  ✓ Plugins ready"
    else
        echo "  ⚠ Plugin install failed (non-fatal) — continuing with cached modules"
    fi
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
# Validate .gitconfig mount — Docker creates a directory if the host file
# doesn't exist, which breaks git. Redirect to an empty file in that case.
GITCONFIG="/root/.gitconfig"
if [ -d "${GITCONFIG}" ]; then
    echo "  ⚠ ${GITCONFIG} is a directory (host ~/.gitconfig missing?) — using defaults"
    echo "    Create ~/.gitconfig on the host, or ignore this if git defaults are fine"
    export GIT_CONFIG_GLOBAL="/dev/null"
elif [ -f "${GITCONFIG}" ] && [ -s "${GITCONFIG}" ]; then
    echo "  ✓ Host .gitconfig mounted"
fi

# Host .gitconfig is mounted read-only; use env vars to add safe.directory.
# Discover all git repos under /workspace (supports multi-repo workspaces).
# Capture once into an array to avoid re-globbing later (TOCTOU safety).
_gitdirs=()
[ -d /workspace/.git ] && _gitdirs+=(/workspace/.git)
for _g in /workspace/*/.git; do
    [ -d "${_g}" ] && _gitdirs+=("${_g}")
done

_git_idx=0
for _gitdir in "${_gitdirs[@]}"; do
    _repo_path="$(dirname "${_gitdir}")"
    export "GIT_CONFIG_KEY_${_git_idx}=safe.directory"
    export "GIT_CONFIG_VALUE_${_git_idx}=${_repo_path}"
    _git_idx=$((_git_idx + 1))
done
_repo_count=${#_gitdirs[@]}
export GIT_CONFIG_COUNT="${_git_idx}"

if [ "${_repo_count}" -gt 1 ]; then
    echo "  ✓ Multi-repo workspace: ${_repo_count} repos discovered"
elif [ "${_repo_count}" -eq 1 ]; then
    echo "  ✓ Git safe.directory configured"
fi

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
# empty. Symlinking repos into $HOME makes them discoverable.
if [ "${_repo_count}" -gt 1 ]; then
    # Multi-repo: symlink each sub-repo individually
    for _gitdir in "${_gitdirs[@]}"; do
        _repo_path="$(dirname "${_gitdir}")"
        _repo_name="$(basename "${_repo_path}")"
        if [ ! -e "${HOME}/${_repo_name}" ]; then
            ln -sf "${_repo_path}" "${HOME}/${_repo_name}"
        fi
    done
    echo "  ✓ Symlinked ${_repo_count} repos into ~/ for project discovery"
else
    # Single-repo: symlink /workspace itself
    WORKSPACE_NAME="$(basename "$(git -C /workspace rev-parse --show-toplevel 2>/dev/null || echo /workspace)")"
    if [ ! -e "${HOME}/${WORKSPACE_NAME}" ]; then
        ln -sf /workspace "${HOME}/${WORKSPACE_NAME}"
        echo "  ✓ Symlinked /workspace → ~/${WORKSPACE_NAME}"
    fi
fi

# ─── Start prefill proxy (strips trailing assistant messages) ─────
if [ "${PREFILL_PROXY_ENABLED}" = "true" ]; then
    echo "→ Starting prefill proxy on 127.0.0.1:18080 → ${LLM_BASE_URL}..."
    UPSTREAM_URL="${LLM_BASE_URL}" PROXY_PORT=18080 \
        node /opt/opencode/prefill-proxy.mjs &
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
else
    echo "→ Prefill proxy disabled — connecting directly to ${LLM_BASE_URL}"
fi
echo ""

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
# (e.g. "my-project" → "OpenCode — my-project"). Requires Docker socket.
if [ -z "${OPENCODE_TITLE}" ]; then
    _compose_svc=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$(hostname)" 2>/dev/null || true)
    if [ -n "${_compose_svc}" ] && [ "${_compose_svc}" != "<no value>" ]; then
        export OPENCODE_TITLE="OpenCode — ${_compose_svc}"
        echo "  ✓ Browser tab title: ${OPENCODE_TITLE}"
    fi
fi

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
        if [ -z "${PROXY_PID:-}" ] || ! kill -0 "${PROXY_PID}" 2>/dev/null; then
            echo "  ⟳ Prefill proxy not running — restarting..."
            UPSTREAM_URL="${LLM_BASE_URL}" PROXY_PORT=18080 \
                node /opt/opencode/prefill-proxy.mjs &
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

cd /workspace

# ── Resolve the Go binary and export OPENCODE_BIN_PATH ────────────
# The Dockerfile copies the Go binary to /usr/local/bin/opencode-go at
# build time — outside node_modules, immune to runtime destruction by
# oh-my-opencode-slim auto-update or `opencode upgrade`.
# The npm wrapper at /usr/local/bin/opencode is a fragile fallback only.
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

OPENCODE_VER=$("${OPENCODE_BIN_PATH}" --version 2>/dev/null || echo "unknown")
OPENCODE_VER="${OPENCODE_VER:0:22}"  # clamp to fit banner width
_ver_pad=$((22 - ${#OPENCODE_VER}))
[ "${_ver_pad}" -lt 0 ] && _ver_pad=0
echo "╔══════════════════════════════════════════╗"
echo "║       OpenCode Web - Docker Container    ║"
echo "║       opencode-ai v${OPENCODE_VER}$(printf '%*s' "${_ver_pad}" '')║"
echo "╚══════════════════════════════════════════╝"
echo ""

if [ "${OPENCODE_MODE}" = "tmux" ]; then
    # ── tmux mode: run opencode inside tmux, served by ttyd ──────
    # Architecture: ttyd → wrapper script → tmux new/attach → opencode
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

    echo "→ Starting opencode TUI via tmux + ttyd on 0.0.0.0:${OPENCODE_PORT:-3000}..."
    echo "  Access: http://localhost:${OPENCODE_PORT:-3000}"
    echo "  Attach: docker exec -it <container> tmux attach -t ${TMUX_SESSION}"
    echo ""

    # Write the tmux wrapper script. ttyd executes this on each browser
    # connection. Terminal dimensions are already correct at this point.
    # Uses 'WRAPPER' (quoted) heredoc so no variable expansion at write time —
    # OPENCODE_BIN_PATH and OPENCODE_EXTRA_ARGS are read from the environment
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
    exec "${OPENCODE_BIN_PATH}" ${OPENCODE_EXTRA_ARGS}
fi

if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    exec tmux -u attach -t "$TMUX_SESSION"
else
    # Apply initial theme to the outer terminal BEFORE creating the
    # tmux session, so lipgloss detects the correct background.
    _init_theme=$(cat /tmp/.tmux-theme 2>/dev/null || echo "dark")
    if [ "$_init_theme" = "light" ]; then
        printf '\e]10;#3760bf\a'    # OSC 10: foreground
        printf '\e]11;#e1e2e7\a'    # OSC 11: background
        printf '\e]12;#2e7de9\a'    # OSC 12: cursor
    fi

    COLS=$(tput cols  2>/dev/null || echo 180)
    ROWS=$(tput lines 2>/dev/null || echo 50)
    tmux -u new-session -d -s "$TMUX_SESSION" -x "$COLS" -y "$ROWS" -c /workspace \
        "/tmp/tmux-wrapper.sh --loop"
    tmux source-file "/opt/opencode/tmux-theme-${_init_theme}.conf" 2>/dev/null
    exec tmux -u attach -t "$TMUX_SESSION"
fi
WRAPPER
    chmod +x /tmp/tmux-wrapper.sh

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
            -t titleFixed="${OPENCODE_TITLE:-OpenCode (tmux)}" \
            -t allowProposedApi=true \
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
    # ── TUI mode: opencode TUI served directly by ttyd ───────────
    echo "→ Starting opencode TUI via ttyd on 0.0.0.0:${OPENCODE_PORT:-3000}..."
    echo "  Access: http://localhost:${OPENCODE_PORT:-3000}"
    echo ""

    # Restart loop with exponential backoff on consecutive failures.
    _fail_count=0
    while true; do
        ttyd \
            --port "${OPENCODE_PORT:-3000}" \
            --interface 0.0.0.0 \
            --writable \
            --cwd /workspace \
            -t titleFixed="${OPENCODE_TITLE:-OpenCode (tui)}" \
            -t allowProposedApi=true \
            ${OPENCODE_TUI_ARGS:-} \
            "${OPENCODE_BIN_PATH}" ${OPENCODE_EXTRA_ARGS:-}
        _rc=$?
        if [ "${_rc}" -eq 0 ]; then _fail_count=0; else _fail_count=$((_fail_count + 1)); fi
        _sleep=$(( 3 * (1 << (_fail_count > 5 ? 5 : _fail_count)) ))
        echo ""
        echo "  ⟳ ttyd exited (rc=${_rc}). Restart #${_fail_count} in ${_sleep}s..."
        echo ""
        sleep "${_sleep}"
    done

else
    # ── Web mode (default): opencode web UI ──────────────────────
    echo "→ Starting opencode web on 0.0.0.0:${OPENCODE_PORT:-3000}..."
    echo "  Access: http://localhost:${OPENCODE_PORT:-3000}"
    echo ""

    _fail_count=0
    while true; do
        "${OPENCODE_BIN_PATH}" web \
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
