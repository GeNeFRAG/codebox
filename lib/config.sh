# ─── lib/config.sh ──────────────────────────────────────────────────────────
# Config generation for all three coding agents: opencode, claude-code, flowcode.
# Also handles auth.json writing and host-auth merging for opencode.

CONFIG_DIR="/root/.config/opencode"
DATA_DIR="/root/.local/share/opencode"
TEMPLATE="/opt/opencode/templates/opencode.json.template"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"

# ─── Reusable config generation (called on startup + proxy fallback) ─
_generate_config() {
    envsubst '${LLM_EFFECTIVE_URL} ${LLM_BASE_URL} ${LLM_API_KEY} ${OPENROUTER_API_KEY} ${OPENCODE_MODEL} ${OPENCODE_TUI_THEME} ${GITHUB_ENTERPRISE_TOKEN} ${GITHUB_ENTERPRISE_URL} ${GITHUB_PERSONAL_TOKEN} ${CONFLUENCE_URL} ${CONFLUENCE_USERNAME} ${CONFLUENCE_TOKEN} ${JIRA_URL} ${JIRA_USERNAME} ${JIRA_TOKEN} ${GRAFANA_URL} ${GRAFANA_API_KEY} ${CA_CERT_PATH} ${ATLASSIAN_TOOLSETS}' \
        < "${TEMPLATE}" > "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
    if [ ! -s "${CONFIG_FILE}" ]; then
        echo "  ✗ FATAL: Config generation failed (${CONFIG_FILE} is empty)"
        exit 1
    fi
}

# ─── Claude Code config generation ──────────────────────────────────
_generate_claude_code_config() {
    local mcp_template="/opt/opencode/templates/claude-code.mcp.json.template"
    local mcp_config="/opt/opencode/templates/claude-code-mcp.json"
    local settings_dir="/root/.claude"
    local settings_file="${settings_dir}/settings.json"

    # 1. Generate MCP config from template
    if [ -f "${mcp_template}" ]; then
        envsubst '${CA_CERT_PATH} ${GITHUB_ENTERPRISE_TOKEN} ${GITHUB_ENTERPRISE_URL} ${GITHUB_PERSONAL_TOKEN} ${CONFLUENCE_URL} ${CONFLUENCE_USERNAME} ${CONFLUENCE_TOKEN} ${JIRA_URL} ${JIRA_USERNAME} ${JIRA_TOKEN} ${GRAFANA_URL} ${GRAFANA_API_KEY} ${ATLASSIAN_TOOLSETS}' \
            < "${mcp_template}" > "${mcp_config}"
        chmod 600 "${mcp_config}"
        echo "  ✓ Claude Code MCP config written to ${mcp_config}"
    else
        echo "  ⚠ MCP template not found (${mcp_template}) — Claude Code will start without MCP servers"
    fi

    # 2. Generate settings.json
    mkdir -p "${settings_dir}"
    # Validate permission mode for settings.json (narrower set than the CLI flag)
    _settings_default_mode=""
    case "${CLAUDE_CODE_PERMISSION_MODE:-}" in
        acceptEdits|bypassPermissions|default|plan) _settings_default_mode="${CLAUDE_CODE_PERMISSION_MODE}" ;;
    esac
    jq -n --arg dm "${_settings_default_mode}" '{
        permissions: (
            { allow: ["Bash(*)","Read(*)","Write(*)","Edit(*)","mcp__*"], deny: [] }
            + (if $dm != "" then { defaultMode: $dm } else {} end)
        ),
        env: { BASH_DEFAULT_TIMEOUT_MS: "300000" },
        autoUpdaterStatus: "disabled"
    }' > "${settings_file}"
    chmod 600 "${settings_file}"
    echo "  ✓ Claude Code settings written to ${settings_file}"

    # 3. Map auth: ANTHROPIC_API_KEY from env, fallback to LLM_API_KEY
    if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -n "${LLM_API_KEY:-}" ]; then
        export ANTHROPIC_API_KEY="${LLM_API_KEY}"
        echo "  ✓ Mapped LLM_API_KEY → ANTHROPIC_API_KEY"
    elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        echo "  ✓ ANTHROPIC_API_KEY configured"
    else
        echo "  ⚠ No API key set — Claude Code requires ANTHROPIC_API_KEY or LLM_API_KEY"
        echo "    Note: OAuth login does NOT work in headless Docker"
    fi

    # 4. Map custom endpoint: ANTHROPIC_BASE_URL from env, fallback to LLM_BASE_URL
    if [ -z "${ANTHROPIC_BASE_URL:-}" ] && [ -n "${LLM_BASE_URL:-}" ]; then
        export ANTHROPIC_BASE_URL="${LLM_BASE_URL}"
        echo "  ✓ Mapped LLM_BASE_URL → ANTHROPIC_BASE_URL (${ANTHROPIC_BASE_URL})"
    elif [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
        echo "  ✓ ANTHROPIC_BASE_URL configured (${ANTHROPIC_BASE_URL})"
    fi

    # 5. Map model: CLAUDE_CODE_MODEL → CLAUDE_MODEL (Claude Code's env var)
    if [ -n "${CLAUDE_CODE_MODEL:-}" ]; then
        export CLAUDE_MODEL="${CLAUDE_CODE_MODEL}"
        echo "  ✓ Default model: ${CLAUDE_MODEL}"
    fi

    # 6. Disable experimental betas unless explicitly opted in
    export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS="${CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS:-1}"

    # 7. Pre-seed .config.json to skip interactive onboarding/login and workspace trust
    # Claude Code checks:
    #   - hasCompletedOnboarding → skips the setup wizard
    #   - customApiKeyResponses.approved (last 20 chars of key) → skips API key approval prompt
    #   - projects["/workspace"].hasTrustDialogAccepted → skips workspace trust dialog
    # Without these, the TUI blocks on interactive prompts.
    local config_json="${settings_dir}/.config.json"
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        local key_tail="${ANTHROPIC_API_KEY: -20}"
        jq -n --arg kt "${key_tail}" '{
            hasCompletedOnboarding: true,
            customApiKeyResponses: {
                approved: [$kt],
                rejected: []
            },
            projects: {
                "/workspace": {
                    hasTrustDialogAccepted: true,
                    allowedTools: []
                }
            }
        }' > "${config_json}"
        chmod 600 "${config_json}"
        echo "  ✓ Claude Code onboarding pre-seeded (API key approved, /workspace trusted)"
    else
        jq -n '{
            hasCompletedOnboarding: true,
            projects: {
                "/workspace": {
                    hasTrustDialogAccepted: true,
                    allowedTools: []
                }
            }
        }' > "${config_json}"
        chmod 600 "${config_json}"
        echo "  ✓ Claude Code onboarding pre-seeded (/workspace trusted, no API key)"
    fi
}

# ─── FlowCode config generation ──────────────────────────────────────
_generate_flowcode_config() {
    local config_dir="/root/.config/flowcode"
    local config_file="${config_dir}/config.json"
    local creds_file="${config_dir}/credentials.json"
    local mcp_template="/opt/opencode/templates/flowcode.mcp.json.template"

    mkdir -p "${config_dir}"

    # 1. Generate config.json — wrap the MCP server list in {"mcpServers": ...}
    #    using the same template as Claude Code (same MCP stdio/http schema).
    if [ -f "${mcp_template}" ]; then
        envsubst '${CA_CERT_PATH} ${GITHUB_ENTERPRISE_TOKEN} ${GITHUB_ENTERPRISE_URL} ${GITHUB_PERSONAL_TOKEN} ${CONFLUENCE_URL} ${CONFLUENCE_USERNAME} ${CONFLUENCE_TOKEN} ${JIRA_URL} ${JIRA_USERNAME} ${JIRA_TOKEN} ${GRAFANA_URL} ${GRAFANA_API_KEY} ${ATLASSIAN_TOOLSETS}' \
            < "${mcp_template}" > "${config_file}"
        chmod 600 "${config_file}"
        echo "  ✓ FlowCode config (MCP servers) written to ${config_file}"
    else
        echo '{}' > "${config_file}"
        chmod 600 "${config_file}"
        echo "  ⚠ MCP template not found (${mcp_template}) — FlowCode will start without MCP servers"
    fi

    # 2. Generate credentials.json (map LLM_API_KEY/LLM_BASE_URL to FlowCode format)
    local auth_token="${ANTHROPIC_AUTH_TOKEN:-${LLM_API_KEY:-}}"
    local base_url="${ANTHROPIC_BASE_URL:-${LLM_BASE_URL:-}}"

    if [ -n "${auth_token}" ] && [ -n "${base_url}" ]; then
        jq -n --arg token "${auth_token}" --arg url "${base_url}" \
            '{"anthropicToken": $token, "anthropicBaseUrl": $url}' \
            > "${creds_file}"
        chmod 600 "${creds_file}"
        echo "  ✓ FlowCode credentials configured (gateway: ${base_url})"
    elif [ -n "${auth_token}" ]; then
        jq -n --arg token "${auth_token}" \
            '{"anthropicToken": $token}' > "${creds_file}"
        chmod 600 "${creds_file}"
        echo "  ⚠ FlowCode credentials: token set but no base URL — will use default gateway"
    else
        echo "  ⚠ No auth token set — configure credentials via FlowCode's web UI settings"
    fi

    # 3. Map GitHub token for git operations in FlowCode's terminal
    if [ -n "${GITHUB_ENTERPRISE_TOKEN:-}" ]; then
        export GH_TOKEN="${GITHUB_ENTERPRISE_TOKEN}"
        echo "  ✓ GH_TOKEN mapped from GITHUB_ENTERPRISE_TOKEN"
    elif [ -n "${GITHUB_PERSONAL_TOKEN:-}" ]; then
        export GH_TOKEN="${GITHUB_PERSONAL_TOKEN}"
        echo "  ✓ GH_TOKEN mapped from GITHUB_PERSONAL_TOKEN"
    fi
}

# ─── OpenCode config generation (default path) ───────────────────────
_configure_opencode() {
    echo "→ Generating opencode.json from template..."

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

    # Determine the effective LLM URL based on whether the prefill proxy is enabled.
    # The proxy hasn't started yet, but the URL is deterministic — we'll verify later.
    PREFILL_PROXY_ENABLED="${PREFILL_PROXY:-true}"
    if [ "${PREFILL_PROXY_ENABLED}" = "true" ]; then
        export LLM_EFFECTIVE_URL="http://127.0.0.1:18080"
    else
        export LLM_EFFECTIVE_URL="${LLM_BASE_URL}"
    fi

    # Default TUI theme if not set (OpenCode built-in themes: opencode,
    # catppuccin, dracula, tokyonight, gruvbox, monokai, flexoki, etc.)
    export OPENCODE_TUI_THEME="${OPENCODE_TUI_THEME:-opencode}"

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
    HOST_AUTH="/opt/opencode/host-auth.json"
    if ! command -v jq &>/dev/null; then
        echo "  ⚠ jq not available — skipping host auth merge"
    elif [ -f "${HOST_AUTH}" ] && [ -s "${HOST_AUTH}" ] && [ -f "${AUTH_FILE}" ]; then
        MERGED=$(jq -s '.[0] * .[1]' \
            "${HOST_AUTH}" "${AUTH_FILE}" 2>/dev/null) || true
        if [ -n "${MERGED}" ]; then
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
}
