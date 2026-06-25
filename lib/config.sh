# ─── lib/config.sh ──────────────────────────────────────────────────────────
# Config generation for coding agents: opencode, claude-code.
# Also handles auth.json writing and host-auth merging for opencode.

CONFIG_DIR="/root/.config/opencode"
DATA_DIR="/root/.local/share/opencode"
TEMPLATE="/opt/opencode/templates/opencode.json.template"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"

_ENVSUBST_VARS_MCP='${CA_CERT_PATH} ${GITHUB_ENTERPRISE_TOKEN} ${GITHUB_ENTERPRISE_URL} ${GITHUB_PERSONAL_TOKEN} ${CONFLUENCE_URL} ${CONFLUENCE_USERNAME} ${CONFLUENCE_TOKEN} ${JIRA_URL} ${JIRA_USERNAME} ${JIRA_TOKEN} ${GRAFANA_URL} ${GRAFANA_API_KEY} ${ATLASSIAN_TOOLSETS} ${CLOUDFLARE_API_TOKEN}'
_ENVSUBST_VARS_OPENCODE="${_ENVSUBST_VARS_MCP} "'${LLM_EFFECTIVE_URL} ${LLM_BASE_URL} ${LLM_API_KEY} ${OPENROUTER_API_KEY} ${OPENCODE_MODEL} ${OPENCODE_TUI_THEME}'

# ─── Reusable config generation (called on startup + proxy fallback) ─
_generate_config() {
    envsubst "${_ENVSUBST_VARS_OPENCODE}" < "${TEMPLATE}" > "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
    if [ ! -s "${CONFIG_FILE}" ]; then
        echo "  ✗ FATAL: Config generation failed (${CONFIG_FILE} is empty)"
        exit 1
    fi
}

# ─── Claude Code MCP server assembly ───────────────────────────────
# Builds claude-code-mcp.json by including only enabled MCP servers.
# Core servers (memory, context7, time, websearch) are always included.
# Optional servers are gated by CODEBOX_MCP_<NAME> env vars (default: true).
_generate_claude_code_mcp_config() {
    local mcp_config="$1"
    local mcp_parts_dir="/opt/opencode/templates/mcp-servers"
    local result='{"mcpServers":{}}'
    local enabled_list=""
    local disabled_list=""

    # Core servers — always included
    local core_servers="memory context7 time websearch"
    # Optional servers — gated by CODEBOX_MCP_<UPPER_NAME> (default: true)
    local optional_servers="github_rbi github_personal mcp-atlassian grafana docker sequential-thinking"

    for server in ${core_servers}; do
        local part="${mcp_parts_dir}/${server}.json"
        if [ -f "${part}" ]; then
            local rendered
            rendered=$(envsubst "${_ENVSUBST_VARS_MCP}" < "${part}")
            if merged=$(echo "${result}" | jq --argjson srv "${rendered}" '.mcpServers += $srv' 2>/dev/null); then
                result="${merged}"
                enabled_list="${enabled_list} ${server}"
            else
                echo "  ✗ Failed to merge MCP server: ${server} (invalid JSON?)"
            fi
        fi
    done

    for server in ${optional_servers}; do
        # Convert server name to env var: mcp-atlassian → CODEBOX_MCP_MCP_ATLASSIAN
        local var_name
        var_name="CODEBOX_MCP_$(echo "${server}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
        local enabled="${!var_name:-true}"
        if [ "${enabled}" = "true" ] || [ "${enabled}" = "1" ]; then
            local part="${mcp_parts_dir}/${server}.json"
            if [ -f "${part}" ]; then
                local rendered
                rendered=$(envsubst "${_ENVSUBST_VARS_MCP}" < "${part}")
                if merged=$(echo "${result}" | jq --argjson srv "${rendered}" '.mcpServers += $srv' 2>/dev/null); then
                    result="${merged}"
                    enabled_list="${enabled_list} ${server}"
                else
                    echo "  ✗ Failed to merge MCP server: ${server} (invalid JSON?)"
                fi
            fi
        else
            disabled_list="${disabled_list} ${server}"
        fi
    done

    echo "${result}" | jq '.' > "${mcp_config}"
    chmod 600 "${mcp_config}"
    if [ ! -s "${mcp_config}" ]; then
        echo "  ✗ FATAL: MCP config generation failed (${mcp_config} is empty)"
        exit 1
    fi
    echo "  ✓ Claude Code MCP config: enabled=[${enabled_list# }]"
    if [ -n "${disabled_list}" ]; then
        echo "  ✓ MCP servers disabled:[${disabled_list# }]"
    fi
}

# ─── Claude Code config generation ──────────────────────────────────
_generate_claude_code_config() {
    local mcp_config="/opt/opencode/templates/claude-code-mcp.json"
    local settings_dir="/root/.claude"
    local settings_file="${settings_dir}/settings.json"

    # 1. Generate MCP config by assembling enabled servers
    _generate_claude_code_mcp_config "${mcp_config}"

    # 2. Generate settings.json
    mkdir -p "${settings_dir}"
    # Validate permission mode for settings.json (narrower set than the CLI flag)
    _settings_default_mode=""
    case "${CLAUDE_CODE_PERMISSION_MODE:-}" in
        acceptEdits|bypassPermissions|default|plan) _settings_default_mode="${CLAUDE_CODE_PERMISSION_MODE}" ;;
    esac
    jq -n --arg dm "${_settings_default_mode}" '{
        permissions: (
            { allow: ["Bash(*)","Read(*)","Write(*)","Edit(*)","mcp__websearch__*","mcp__context7__*","mcp__sequential-thinking__*","mcp__time__*","mcp__docker__*","mcp__github__*","mcp__atlassian__*","mcp__grafana__*"], deny: [] }
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
    local _key_json="null"
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        _key_json=$(jq -n --arg kt "${ANTHROPIC_API_KEY: -20}" '{approved: [$kt], rejected: []}')
    fi
    jq -n --argjson keys "${_key_json}" '{
        hasCompletedOnboarding: true,
        projects: {"/workspace": {hasTrustDialogAccepted: true, allowedTools: []}}
    } + (if $keys != null then {customApiKeyResponses: $keys} else {} end)' > "${config_json}"
    chmod 600 "${config_json}"
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        echo "  ✓ Claude Code onboarding pre-seeded (API key approved, /workspace trusted)"
    else
        echo "  ✓ Claude Code onboarding pre-seeded (/workspace trusted, no API key)"
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

# ─── Generate atl config from env vars if the Docker mount didn't land ─────
_generate_atl_config() {
    local cfg="/root/.config/atl/config.yaml"
    [[ -s "$cfg" ]] && return
    [[ -z "$JIRA_URL" && -z "$CONFLUENCE_URL" ]] && return
    mkdir -p "$(dirname "$cfg")"
    {
        [[ -n "$JIRA_URL" && -n "$JIRA_TOKEN" ]] && \
            printf 'jira:\n  url: "%s"\n  token: "%s"\n' "$JIRA_URL" "$JIRA_TOKEN"
        [[ -n "$CONFLUENCE_URL" && -n "$CONFLUENCE_TOKEN" ]] && \
            printf 'confluence:\n  url: "%s"\n  token: "%s"\n' "$CONFLUENCE_URL" "$CONFLUENCE_TOKEN"
    } > "$cfg"
    echo "  ✓ atl config generated from environment"
}
