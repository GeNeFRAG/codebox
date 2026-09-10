# ─── lib/config.sh ──────────────────────────────────────────────────────────
# Config generation for coding agents: opencode, claude-code, pi.
# Also handles auth.json writing and host-auth merging for opencode.

CONFIG_DIR="/root/.config/opencode"
DATA_DIR="/root/.local/share/opencode"
TEMPLATE="/opt/opencode/templates/opencode.json.template"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
# Pi's default config dir (relocatable via PI_CODING_AGENT_DIR); matches
# the mkdir already done for it in the Dockerfile.
PI_CONFIG_DIR="/root/.pi/agent"
# Shared model catalog (context/output limits, pricing, per-model api).
# Single source of truth for BOTH agents — see _pi_models_from_catalog()
# and _opencode_models_from_catalog().
MODEL_CATALOG="/opt/opencode/templates/model-catalog.json"

_ENVSUBST_VARS_MCP='${CA_CERT_PATH} ${GITHUB_ENTERPRISE_TOKEN} ${GITHUB_ENTERPRISE_URL} ${GITHUB_PERSONAL_TOKEN} ${CONFLUENCE_URL} ${CONFLUENCE_USERNAME} ${CONFLUENCE_TOKEN} ${JIRA_URL} ${JIRA_USERNAME} ${JIRA_TOKEN} ${GRAFANA_URL} ${GRAFANA_API_KEY} ${ATLASSIAN_TOOLSETS}'
_ENVSUBST_VARS_OPENCODE="${_ENVSUBST_VARS_MCP} "'${LLM_EFFECTIVE_URL} ${LLM_BASE_URL} ${LLM_API_KEY} ${OPENROUTER_API_KEY} ${OPENCODE_MODEL} ${OPENCODE_SMALL_MODEL}'

# ─── Shared MCP server list (single source of truth) ───────────────
# Consumed by both _generate_config() (opencode .mcp[].enabled gating)
# and _generate_mcp_server_config() (fragment include/exclude).
# Keep in sync with templates/mcp-servers/*.json and the .mcp keys of
# templates/opencode.json.template — see scripts/verify-mcp-sync.sh.
_MCP_ALL_SERVERS="memory context7 time websearch github_rbi github_personal mcp-atlassian grafana docker sequential-thinking"

# Truthiness for CODEBOX_* toggles. Both "true" and "1" are accepted
# everywhere in this file; anything else (including "") is false.
_is_true() {
    [ "${1:-}" = "true" ] || [ "${1:-}" = "1" ]
}

# ─── Gateway model discovery and filtering ──────────────────────
# When LLM_BASE_URL is set, discover available models from /v1/models and
# filter the catalog to only include models the gateway actually supports.

# Returns cache file path for the current gateway
_cache_key_for_gateway() {
    local url="${LLM_BASE_URL:-}"
    [ -z "${url}" ] && return 1
    local hash
    hash=$(echo -n "${url}" | sha256sum | cut -c1-16)
    echo "/tmp/codebox-gateway-models-${hash}.json"
}

# Reads cached model discovery if valid; returns JSON array of model IDs or empty
_read_model_cache() {
    local cache_file
    cache_file=$(_cache_key_for_gateway) || return 1
    [ ! -f "${cache_file}" ] && return 1

    local ttl="${CODEBOX_MODEL_CACHE_TTL:-3600}"
    if [ "${ttl}" = "0" ]; then
        # Cache disabled
        return 1
    fi

    local cache_time
    cache_time=$(jq -r '.timestamp // 0' "${cache_file}" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    local age=$((now - cache_time))

    # Detect negative age (time went backward)
    if [ "${age}" -lt 0 ]; then
        # Invalid cache - time went backward
        return 1
    fi

    if [ "${age}" -gt "${ttl}" ]; then
        # Cache expired
        return 1
    fi

    jq -r '.models // empty' "${cache_file}" 2>/dev/null || return 1
}

# Writes model discovery to cache with timestamp
_write_model_cache() {
    local models_json="${1:-}"
    [ -z "${models_json}" ] && return 1

    local cache_file
    cache_file=$(_cache_key_for_gateway) || return 1

    local now
    now=$(date +%s)

    if jq -n --argjson models "${models_json}" --argjson ts "${now}" \
        '{timestamp: $ts, models: $models}' > "${cache_file}" 2>/dev/null; then
        chmod 600 "${cache_file}"
    fi
}

# Discovers available models from gateway /v1/models endpoint
# Returns JSON array of model IDs, or empty string on failure
_discover_gateway_models() {
    [ -z "${LLM_BASE_URL:-}" ] && return 1
    [ -z "${LLM_API_KEY:-}" ] && return 1

    # Check cache first
    local cached
    if cached=$(_read_model_cache); then
        echo "${cached}"
        return 0
    fi

    # Discover from gateway
    local timeout="${CODEBOX_MODEL_DISCOVERY_TIMEOUT:-10}"

    # Strip trailing slash from base URL to avoid double slashes
    local base_url="${LLM_BASE_URL%/}"

    local response
    local curl_err
    response=$(curl -sf --max-time "${timeout}" \
        -H "Authorization: Bearer ${LLM_API_KEY}" \
        --url "${base_url}/v1/models" 2>&1) || curl_err=$?

    if [ -z "${response}" ] || [ -n "${curl_err:-}" ]; then
        return 1
    fi

    # Extract model IDs
    local models
    local jq_err
    models=$(jq -c '[.data[]?.id // empty] | unique' <<<"${response}" 2>&1) || jq_err=$?

    if [ -n "${jq_err:-}" ]; then
        echo "  ⚠ Failed to parse gateway response: ${models}" >&2
        return 1
    fi

    if [ -z "${models}" ] || [ "${models}" = "[]" ]; then
        return 1
    fi

    # Cache the result
    _write_model_cache "${models}" || true

    echo "${models}"
}

# Filters catalog to only include models in the allowed list
# Args: $1=catalog JSON, $2=allowed model IDs JSON array
# Returns filtered catalog JSON
_filter_catalog_models() {
    local catalog_json="${1:-}"
    local allowed_ids_json="${2:-}"

    [ -z "${catalog_json}" ] && return 1
    [ -z "${allowed_ids_json}" ] && return 1

    command -v jq &>/dev/null || return 1

    jq --argjson allowed "${allowed_ids_json}" '
        .models |= map(select(.id as $id | $allowed | index($id)))
    ' <<<"${catalog_json}" 2>/dev/null
}

# Main orchestrator: returns catalog (filtered or full) based on gateway discovery
# Handles all the logic for gateway availability, caching, and fallback
_get_catalog_for_agent() {
    [ ! -s "${MODEL_CATALOG}" ] && return 1

    local full_catalog
    full_catalog=$(cat "${MODEL_CATALOG}")

    # Validate catalog is valid JSON
    if ! jq -e . >/dev/null 2>&1 <<<"${full_catalog}"; then
        echo "  ✗ MODEL_CATALOG is not valid JSON" >&2
        return 1
    fi

    # If no gateway configured, return full catalog (native behavior)
    if [ -z "${LLM_BASE_URL:-}" ]; then
        echo "${full_catalog}"
        return 0
    fi

    # Try to discover models from gateway
    local discovered
    if discovered=$(_discover_gateway_models); then
        local discovered_count
        discovered_count=$(jq 'length' <<<"${discovered}" 2>/dev/null || echo 0)

        if [ "${discovered_count}" -gt 0 ]; then
            # Success - filter catalog by discovered models
            local filtered
            if filtered=$(_filter_catalog_models "${full_catalog}" "${discovered}"); then
                local filtered_count
                filtered_count=$(jq '.models | length' <<<"${filtered}" 2>/dev/null || echo 0)

                if [ "${filtered_count}" -gt 0 ]; then
                    echo "  ✓ Gateway discovery: ${filtered_count}/${discovered_count} catalog models available" >&2
                    echo "${filtered}"
                    return 0
                else
                    # Discovery succeeded but no models matched
                    echo "  ⚠ Gateway returned ${discovered_count} models but none match catalog" >&2
                    echo "    Gateway models: $(jq -r 'join(", ")' <<<"${discovered}" 2>/dev/null)" >&2
                    if _is_true "${CODEBOX_REQUIRE_LLM_GATEWAY:-false}"; then
                        echo "  ✗ FATAL: Gateway required but no catalog models available" >&2
                        echo "    Add gateway models to templates/model-catalog.json or set CODEBOX_REQUIRE_LLM_GATEWAY=false" >&2
                        return 1
                    fi
                    # Fall through to full catalog fallback below
                fi
            else
                # Filter operation itself failed
                echo "  ⚠ Failed to filter catalog (jq error)" >&2
                if _is_true "${CODEBOX_REQUIRE_LLM_GATEWAY:-false}"; then
                    echo "  ✗ FATAL: Catalog filtering failed and gateway is required" >&2
                    return 1
                fi
            fi
        fi
    fi

    # Discovery failed or filtering yielded no results
    if _is_true "${CODEBOX_REQUIRE_LLM_GATEWAY:-false}"; then
        echo "  ✗ FATAL: Gateway discovery failed (${LLM_BASE_URL})" >&2
        echo "    Check LLM_BASE_URL, LLM_API_KEY, network connectivity, and gateway health" >&2
        echo "    Set CODEBOX_REQUIRE_LLM_GATEWAY=false to fall back to full catalog" >&2
        return 1
    fi

    # Not required - fall back to full catalog with warning
    local catalog_count
    catalog_count=$(jq '.models | length' <<<"${full_catalog}" 2>/dev/null || echo 0)
    echo "  ⚠ Gateway discovery failed or yielded no matches, using full catalog (${catalog_count} models)" >&2
    echo "    Gateway may not support configured models; runtime errors possible" >&2
    echo "    Set CODEBOX_REQUIRE_LLM_GATEWAY=true to fail instead of falling back" >&2
    echo "${full_catalog}"
}

# ─── Model validation and normalization ────────────────────────────
# Validates a model reference against a catalog and normalizes to llm/<id> format.
# Args: $1=model_ref (e.g. "model-id" or "llm/model-id"), $2=catalog_json, $3=var_name (for errors)
# Returns: normalized "llm/model-id" on stdout if valid, empty string if invalid
# Exit code: 0=valid, 1=invalid
_validate_and_normalize_model() {
    local model_ref="${1:-}"
    local catalog_json="${2:-}"
    local var_name="${3:-MODEL}"

    [ -z "${model_ref}" ] && return 1
    [ -z "${catalog_json}" ] && return 1

    # Strip llm/ prefix if present
    local base_id="${model_ref#llm/}"

    # Check if model exists in catalog
    local exists
    exists=$(jq --arg id "${base_id}" '[.models[].id] | index($id) != null' <<<"${catalog_json}" 2>/dev/null)

    if [ "${exists}" = "true" ]; then
        echo "llm/${base_id}"
        return 0
    else
        return 1
    fi
}

# ─── Model catalog → per-agent model config ─────────────────────────
# The gateway is LiteLLM in front of Bedrock/Azure. Two things matter and
# neither is auto-detectable by the agents, so they are pinned here:
#
#   1. api — Claude models must go over anthropic-messages. The
#      OpenAI-completions route does produce thinking (LiteLLM maps
#      `reasoning_effort` onto Anthropic's `thinking.budget_tokens`), but
#      it degrades in three measured ways:
#        - the thinking block comes back with the placeholder signature
#          "reasoning_content" instead of a real, replayable signature;
#        - `usage.reasoning` is 0, so thinking tokens go unaccounted and
#          cost reporting understates the turn;
#        - because effort is translated into a token budget, a request
#          whose max_tokens is <= that budget is rejected outright
#          (HTTP 400, "max_tokens must be greater than
#          thinking.budget_tokens") — a trap that scales with
#          PI_THINKING_BUDGETS.
#      The anthropic-messages route returns real signatures, accounts
#      reasoning tokens, and has no max_tokens/budget interaction. The
#      catalog pins api per model, so Claude and GPT models coexist under
#      one provider block.
#
#   2. cacheControlFormat — pi only auto-enables Anthropic-style
#      `cache_control` markers for openrouter.ai base URLs, so against
#      this gateway nothing was ever marked and every turn re-billed the
#      full prefix at input rate (10x the cache_read rate on Opus).
#      Set explicitly for any Claude model left on an OpenAI route.
#
#   3. supportsEagerToolInputStreaming — the gateway rejects Pi's default
#      tools[].eager_input_streaming field. Claude catalog entries disable
#      it and Pi uses its legacy fine-grained tool-streaming beta instead.
#
# NOTE: only pi consumes `api`/`thinkingLevelMap`/`compat`. The opencode
# renderer below emits name/cost/limit only, so the Claude routing fix is
# pi-only; opencode still talks to every model over its provider's SDK.
_pi_models_from_catalog() {
    command -v jq &>/dev/null || return 1
    local catalog_input="${1:-}"
    if [ -z "${catalog_input}" ]; then
        catalog_input=$(cat "${MODEL_CATALOG}")
    fi
    jq -e '
        [ .models[] | {
            id,
            # pi matches --model patterns against `name`, and displays
            # entries by `id`; keeping them identical means the ids in
            # PI_MODEL/--model are the only string a user ever needs.
            # (opencode gets the human-readable .name instead.)
            name: .id,
            contextWindow: .context,
            maxTokens: .output,
            reasoning: .reasoning,
            input: (if .vision then ["text","image"] else ["text"] end),
            # cacheWrite is REQUIRED by the models.json schema in pi; if it
            # is missing the file is invalid and pi silently drops the whole
            # provider. OpenAI-style caching has no write surcharge, hence 0.
            cost: (.cost + {cacheWrite: (.cost.cacheWrite // 0)})
          }
          + (if .api then {api: .api} else {} end)
          + (if .thinkingLevelMap then {thinkingLevelMap: .thinkingLevelMap} else {} end)
          + (if .compat then {compat: .compat} else {} end)
          + (if (.id | startswith("claude-")) and (.api != "anthropic-messages")
             then {compat: ((.compat // {}) + {cacheControlFormat: "anthropic"})} else {} end)
        ]' <<<"${catalog_input}" 2>/dev/null
}

# Renders the catalog into opencode's .provider.llm.models shape so the
# limits/pricing live in exactly one file for both agents.
# Accepts optional catalog JSON as first arg; defaults to MODEL_CATALOG file.
_opencode_models_from_catalog() {
    command -v jq &>/dev/null || return 1
    local catalog_input="${1:-}"
    if [ -z "${catalog_input}" ]; then
        catalog_input=$(cat "${MODEL_CATALOG}")
    fi
    jq -e '
        [ .models[] | {
            key: .id,
            value: {
                name: .name,
                cost: ({input: .cost.input, output: .cost.output, cache_read: .cost.cacheRead}
                       + (if .cost.cacheWrite then {cache_write: .cost.cacheWrite} else {} end)),
                limit: {context: .context, output: .output}
            }
          } ] | from_entries' <<<"${catalog_input}" 2>/dev/null
}

# ─── Reusable config generation (called on startup + proxy fallback) ─
_generate_config() {
    envsubst "${_ENVSUBST_VARS_OPENCODE}" < "${TEMPLATE}" > "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
    if [ ! -s "${CONFIG_FILE}" ]; then
        echo "  ✗ FATAL: Config generation failed (${CONFIG_FILE} is empty)"
        exit 1
    fi

    # ─── Inject the shared model catalog ───────────────────────────────
    # templates/opencode.json.template carries a catalog snapshot so the
    # file stays valid/readable standalone, but model-catalog.json is
    # authoritative: overwrite .provider.llm.models from it on every boot
    # so opencode and pi can never disagree about limits or pricing.
    # When LLM_BASE_URL is set, discover available models and filter the catalog.
    if [ -s "${MODEL_CATALOG}" ] && command -v jq &>/dev/null; then
        local _catalog
        # Reuse catalog if caller already fetched it (avoids double discovery)
        if [ -n "${_REUSE_CATALOG:-}" ]; then
            _catalog="${_REUSE_CATALOG}"
        elif _catalog=$(_get_catalog_for_agent); then
            : # Got fresh catalog
        else
            if [ "${CODEBOX_REQUIRE_LLM_GATEWAY:-false}" = "true" ]; then
                echo "  ✗ Failed to get catalog (gateway required but unavailable)" >&2
            else
                echo "  ⚠ Failed to get catalog (falling back to template snapshot)" >&2
            fi
            return 1
        fi

        local _oc_models
        if _oc_models=$(_opencode_models_from_catalog "${_catalog}"); then
            if jq --argjson m "${_oc_models}" '.provider.llm.models = $m' \
                   "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" 2>/dev/null \
                   && [ -s "${CONFIG_FILE}.tmp" ]; then
                mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
                chmod 600 "${CONFIG_FILE}"
                echo "  ✓ Model catalog: $(jq 'length' <<<"${_oc_models}") models injected"
            else
                rm -f "${CONFIG_FILE}.tmp"
                echo "  ⚠ Model catalog injection failed — using template snapshot" >&2
                return 1
            fi
        else
            echo "  ⚠ Model catalog transform failed" >&2
            return 1
        fi
    fi

    # ─── Gate .mcp[<server>].enabled via CODEBOX_MCP_<NAME> ────────────
    # Layering: CODEBOX_MCP_<NAME> set → authoritative (true/1 → enabled,
    # anything else → disabled). Unset → leave the template's own value
    # untouched (template = default, env = override). Mirrors the gating
    # in _generate_mcp_server_config() so both agent paths agree.
    local jq_filter="."
    local enabled_list=""
    local disabled_list=""
    for server in ${_MCP_ALL_SERVERS}; do
        local var_name
        var_name="CODEBOX_MCP_$(echo "${server}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
        if [ -n "${!var_name+x}" ]; then
            local val="${!var_name}"
            if [ "${val}" = "true" ] || [ "${val}" = "1" ]; then
                jq_filter="${jq_filter} | .mcp[\"${server}\"].enabled = true"
                enabled_list="${enabled_list} ${server}"
            else
                jq_filter="${jq_filter} | .mcp[\"${server}\"].enabled = false"
                disabled_list="${disabled_list} ${server}"
            fi
        fi
    done

    if [ -n "${enabled_list}${disabled_list}" ]; then
        local tmp_file="${CONFIG_FILE}.tmp"
        if jq "${jq_filter}" "${CONFIG_FILE}" > "${tmp_file}" 2>/dev/null && [ -s "${tmp_file}" ]; then
            mv "${tmp_file}" "${CONFIG_FILE}"
            chmod 600 "${CONFIG_FILE}"
            [ -n "${enabled_list}" ] && echo "  ✓ MCP servers enabled:[${enabled_list# }]"
            [ -n "${disabled_list}" ] && echo "  ✓ MCP servers disabled:[${disabled_list# }]"
        else
            rm -f "${tmp_file}"
            echo "  ⚠ MCP gating via jq failed — keeping template defaults for ${CONFIG_FILE}"
        fi
    fi

    # ─── Provider allowlist via OPENCODE_ENABLED_PROVIDERS ─────────────
    # Only the llm gateway is credentialed by default, yet opencode
    # auto-discovers ~450 extra models from models.dev that are selectable
    # but unusable. Space-separated list; default "llm". Set it to an empty
    # string to disable the allowlist (e.g. when host-auth.json contributes
    # github-copilot or other authenticated providers — add those IDs here).
    local _enabled_providers="${OPENCODE_ENABLED_PROVIDERS-llm}"
    if [ -n "${_enabled_providers}" ] && command -v jq &>/dev/null; then
        local _ep_json
        _ep_json=$(printf '%s\n' ${_enabled_providers} | jq -R . | jq -s -c .)
        if jq --argjson ep "${_ep_json}" '.enabled_providers = $ep' \
               "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" 2>/dev/null; then
            mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
            chmod 600 "${CONFIG_FILE}"
        else
            rm -f "${CONFIG_FILE}.tmp"
        fi
    fi
}

# ─── Generate tui.json (theme lives here as of opencode 1.18) ──────
# The opencode.json loader deletes top-level "theme"/"keybinds"/"tui" and
# only migrates them into tui.json if that file does not already exist —
# so rendering the theme into opencode.json is a silent no-op after the
# first boot. Merge into tui.json instead so OPENCODE_TUI_THEME keeps
# working on every restart, preserving any other TUI keys already set.
_generate_tui_config() {
    local tui_cfg="${CONFIG_DIR}/tui.json"
    local tui_schema="https://opencode.ai/tui.json"

    if grep -qE " ${tui_cfg}( |$)" /proc/self/mountinfo 2>/dev/null; then
        echo "  → tui.json is bind-mounted — leaving user config in place"
        return
    fi
    if ! command -v jq &>/dev/null; then
        echo "  ⚠ jq not available — skipping tui.json theme update"
        return
    fi

    if [ -s "${tui_cfg}" ]; then
        if jq --arg t "${OPENCODE_TUI_THEME}" --arg s "${tui_schema}" \
               '.["$schema"] = $s | .theme = $t' \
               "${tui_cfg}" > "${tui_cfg}.tmp" 2>/dev/null; then
            mv "${tui_cfg}.tmp" "${tui_cfg}"
        else
            rm -f "${tui_cfg}.tmp"
            echo "  ⚠ tui.json is not valid JSON — leaving it untouched"
            return
        fi
    else
        jq -n --arg t "${OPENCODE_TUI_THEME}" --arg s "${tui_schema}" \
            '{"$schema": $s, "theme": $t}' > "${tui_cfg}"
    fi
    chmod 600 "${tui_cfg}"
    echo "  ✓ TUI theme set to ${OPENCODE_TUI_THEME} (${tui_cfg})"
}

# ─── MCP server assembly (Claude Code + Pi) ────────────────────────
# Builds an {"mcpServers":{...}} file from templates/mcp-servers/*.json,
# including only servers enabled by CODEBOX_MCP_<NAME> (default: true).
# Used by both agents that can speak MCP: Claude Code natively, and Pi
# through lib/pi-ext/codebox-mcp.ts, which reads the same shape. Keeping
# one assembler means "add an MCP server" stays a one-fragment change.
#   $1 — output file   $2 — label for the boot log (default "Claude Code")
_generate_mcp_server_config() {
    local mcp_config="$1"
    local label="${2:-Claude Code}"
    local mcp_parts_dir="/opt/opencode/templates/mcp-servers"
    local result='{"mcpServers":{}}'
    local enabled_list=""
    local disabled_list=""

    for server in ${_MCP_ALL_SERVERS}; do
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
    echo "  ✓ ${label} MCP config: enabled=[${enabled_list# }]"
    if [ -n "${disabled_list}" ]; then
        echo "  ✓ MCP servers disabled:[${disabled_list# }]"
    fi
}

# ─── Claude Code config generation ──────────────────────────────────
_generate_claude_code_config() {
    local settings_dir="/root/.claude"
    local mcp_config="${settings_dir}/claude-code-mcp.json"
    local settings_file="${settings_dir}/settings.json"

    mkdir -p "${settings_dir}"

    # 1. Generate MCP config by assembling enabled servers
    _generate_mcp_server_config "${mcp_config}" "Claude Code"

    # 2. Generate settings.json
    # Validate permission mode for settings.json (narrower set than the CLI flag)
    _settings_default_mode=""
    case "${CLAUDE_CODE_PERMISSION_MODE:-}" in
        acceptEdits|bypassPermissions|default|plan) _settings_default_mode="${CLAUDE_CODE_PERMISSION_MODE}" ;;
    esac
    jq -n --arg dm "${_settings_default_mode}" '{
        permissions: (
            { allow: ["Bash(*)","Read(*)","Write(*)","Edit(*)","mcp__memory__*","mcp__websearch__*","mcp__context7__*","mcp__sequential-thinking__*","mcp__time__*","mcp__docker__*","mcp__github_rbi__*","mcp__github_personal__*","mcp__mcp-atlassian__*","mcp__grafana__*"], deny: [] }
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
# ─── oh-my-opencode-slim model reference validation ────────────────
# Validates that model references in oh-my-opencode-slim.json match
# entries in model-catalog.json. Two phases:
#   1. Static: Check template references against full catalog
#   2. Runtime: Check references against post-discovery catalog
# Both phases preserve OpenCode's ordered fallback arrays — they are not
# rewritten, only validated.

# Helper: exit with validation failure message
# Args: $1=phase ("static" or "runtime")
_fail_plugin_validation() {
    local phase="${1}"
    echo "  ✗ FATAL: oh-my-opencode-slim ${phase} validation failed" >&2
    return 1
}

# Extract all model references from oh-my-opencode-slim config
# Returns newline-separated list of model IDs (strips "llm/" prefix)
_extract_plugin_model_refs() {
    local plugin_file="${1:-}"
    [ ! -f "${plugin_file}" ] && return 1
    command -v jq &>/dev/null || return 1

    # Extract from presets.default (agent roles) and council.presets.default (council roles)
    jq -r '
        ((.presets.default // {}) | to_entries[] | .value.model),
        ((.council.presets.default // {}) | to_entries[] | .value.model)
        | if type == "array" then .[] else . end
        | select(. != null and . != "")
        | sub("^llm/"; "")' "${plugin_file}" 2>/dev/null | sort -u
}

# Validate plugin model references against a catalog
# Args: $1=plugin_file, $2=catalog_json, $3=phase ("static" or "runtime")
# Returns: 0=valid, 1=invalid refs found
# Side effect: prints warnings/errors to stderr
_validate_plugin_models() {
    local plugin_file="${1:-}"
    local catalog_json="${2:-}"
    local phase="${3:-static}"

    [ ! -f "${plugin_file}" ] && return 1
    [ -z "${catalog_json}" ] && return 1
    command -v jq &>/dev/null || return 1

    local refs invalid_refs
    refs=$(_extract_plugin_model_refs "${plugin_file}")
    [ -z "${refs}" ] && return 0

    # Get list of valid model IDs from catalog
    local valid_ids
    valid_ids=$(jq -r '.models[].id' <<<"${catalog_json}" 2>/dev/null | sort -u)
    # Continue validation even if empty - treat all refs as invalid

    # Find invalid references
    invalid_refs=$(comm -23 <(echo "${refs}") <(echo "${valid_ids}"))

    if [ -n "${invalid_refs}" ]; then
        local severity="⚠"
        local action=""
        local invalid_count
        invalid_count=$(echo "${invalid_refs}" | wc -l)

        if _is_true "${CODEBOX_STRICT_MODEL_REFS:-false}"; then
            severity="✗"
            action=" FATAL:"
        fi

        echo "  ${severity}${action} oh-my-opencode-slim: ${invalid_count} invalid model reference(s) in ${phase} catalog:" >&2
        echo "${invalid_refs}" | sed 's/^/      /' >&2

        if [ "${phase}" = "runtime" ]; then
            echo "    These models are not available from the gateway." >&2
            echo "    Agent roles may fail at runtime if no valid fallback exists." >&2
        else
            echo "    These models do not exist in templates/model-catalog.json." >&2
            echo "    Update the catalog or fix the plugin template." >&2
        fi

        if _is_true "${CODEBOX_STRICT_MODEL_REFS:-false}"; then
            return 1
        fi
    fi

    return 0
}

# Generate diagnostics report for plugin model references
# Args: $1=plugin_file, $2=catalog_json
# Side effect: prints report to stdout
_report_plugin_model_status() {
    local plugin_file="${1:-}"
    local catalog_json="${2:-}"

    [ ! -f "${plugin_file}" ] && return 1
    [ -z "${catalog_json}" ] && return 1
    command -v jq &>/dev/null || return 1

    local refs valid_ids
    refs=$(_extract_plugin_model_refs "${plugin_file}")
    valid_ids=$(jq -r '.models[].id' <<<"${catalog_json}" 2>/dev/null | sort -u)

    if [ -z "${refs}" ]; then
        echo "  → oh-my-opencode-slim: no model references found"
        return 0
    fi

    local total valid invalid
    total=$(echo "${refs}" | wc -l)
    valid=$(comm -12 <(echo "${refs}") <(echo "${valid_ids}") | wc -l)
    invalid=$(comm -23 <(echo "${refs}") <(echo "${valid_ids}") | wc -l)

    echo "  ✓ oh-my-opencode-slim: ${valid}/${total} unique model refs in catalog"

    if [ "${invalid}" -gt 0 ]; then
        local invalid_list
        invalid_list=$(comm -23 <(echo "${refs}") <(echo "${valid_ids}") | tr '\n' ',' | sed 's/,$//')
        echo "    Not in catalog: ${invalid_list}"
    fi
}

_configure_opencode() {
    echo "→ Generating opencode.json from template..."

    # Determine the effective LLM URL based on whether the prefill proxy is enabled.
    # The proxy hasn't started yet, but the URL is deterministic — we'll verify later.
    PREFILL_PROXY_ENABLED="${PREFILL_PROXY:-false}"
    if [ "${PREFILL_PROXY_ENABLED}" = "true" ]; then
        export LLM_EFFECTIVE_URL="http://127.0.0.1:18080"
    else
        export LLM_EFFECTIVE_URL="${LLM_BASE_URL}"
    fi

    # Default TUI theme if not set (OpenCode built-in themes: opencode,
    # catppuccin, dracula, tokyonight, gruvbox, monokai, flexoki, etc.)
    export OPENCODE_TUI_THEME="${OPENCODE_TUI_THEME:-opencode}"

    # Model for OpenCode's internal "small" slot — session-title generation
    # (Provider.getSmallModel). Left unset it resolves to the main model, so
    # every new session spent a full opus call just to name itself. Haiku is
    # declared in the llm provider block of the template. An unresolvable ID
    # is caught as ProviderModelNotFoundError and degrades to the main model,
    # so a non-llm main provider is not broken by this default.
    export OPENCODE_SMALL_MODEL="${OPENCODE_SMALL_MODEL:-llm/claude-haiku-4-5}"

    # ─── Get catalog once (filtered by gateway if available) ─────────────
    # This is the single source of truth for all subsequent operations in this
    # function. Avoids repeating discovery when validating models and plugins.
    local _opencode_catalog
    if ! _opencode_catalog=$(_get_catalog_for_agent); then
        # Fatal: gateway required but unavailable, or catalog invalid
        echo "  ✗ Configuration failed: unable to get model catalog" >&2
        return 1
    fi

    # ─── Validate and normalize OPENCODE_MODEL ────────────────────
    if [ -n "${OPENCODE_MODEL:-}" ]; then
        local _validated_model
        if _validated_model=$(_validate_and_normalize_model "${OPENCODE_MODEL}" "${_opencode_catalog}" "OPENCODE_MODEL"); then
            export OPENCODE_MODEL="${_validated_model}"
            echo "  ✓ Primary model: ${OPENCODE_MODEL}"
        else
            echo "  ⚠ OPENCODE_MODEL='${OPENCODE_MODEL}' not in filtered catalog" >&2
            if [ -n "${OPENCODE_MODEL_FALLBACK:-}" ]; then
                local _validated_fallback
                if _validated_fallback=$(_validate_and_normalize_model "${OPENCODE_MODEL_FALLBACK}" "${_opencode_catalog}" "OPENCODE_MODEL_FALLBACK"); then
                    echo "  ✓ Using fallback model: ${_validated_fallback}" >&2
                    export OPENCODE_MODEL="${_validated_fallback}"
                else
                    echo "  ✗ OPENCODE_MODEL_FALLBACK='${OPENCODE_MODEL_FALLBACK}' also not in catalog" >&2
                    if _is_true "${CODEBOX_REQUIRE_LLM_GATEWAY:-false}"; then
                        echo "  ✗ FATAL: No valid model configured and gateway is required" >&2
                        return 1
                    fi
                    echo "    Keeping OPENCODE_MODEL='${OPENCODE_MODEL}' (may fail at runtime)" >&2
                fi
            else
                if _is_true "${CODEBOX_REQUIRE_LLM_GATEWAY:-false}"; then
                    echo "  ✗ FATAL: Invalid model and no fallback configured" >&2
                    return 1
                fi
                echo "    Keeping OPENCODE_MODEL='${OPENCODE_MODEL}' (may fail at runtime)" >&2
            fi
        fi
    fi

    # ─── Validate and normalize OPENCODE_SMALL_MODEL ─────────────────
    if [ -n "${OPENCODE_SMALL_MODEL:-}" ]; then
        local _validated_small
        if _validated_small=$(_validate_and_normalize_model "${OPENCODE_SMALL_MODEL}" "${_opencode_catalog}" "OPENCODE_SMALL_MODEL"); then
            export OPENCODE_SMALL_MODEL="${_validated_small}"
            echo "  ✓ Small model (titles): ${OPENCODE_SMALL_MODEL}"
        else
            echo "  ⚠ OPENCODE_SMALL_MODEL='${OPENCODE_SMALL_MODEL}' not in catalog (will degrade to main model)" >&2
        fi
    fi

    # ─── Generate config with the validated catalog ────────────────────
    # Pass the catalog to _generate_config's model injection section.
    # We can't directly pass it as a parameter without changing _generate_config
    # signature (which is also called from proxy fallback path), so we'll
    # modify _generate_config to check for _REUSE_CATALOG variable.
    export _REUSE_CATALOG="${_opencode_catalog}"
    _generate_config
    unset _REUSE_CATALOG
    echo "  ✓ Config written to ${CONFIG_FILE}"
    _generate_tui_config

    # ─── Refresh oh-my-opencode-slim plugin config from template ───────
    # Baked into the image at build time by the Dockerfile, but copied
    # again here so restart picks up template edits without a rebuild.
    # Skip if the user has bind-mounted their own file at this path.
    _plugin_cfg="${CONFIG_DIR}/oh-my-opencode-slim.json"
    _plugin_tpl="/opt/opencode/templates/oh-my-opencode-slim.json.template"
    if grep -qE " ${_plugin_cfg}( |$)" /proc/self/mountinfo 2>/dev/null; then
        echo "  → oh-my-opencode-slim.json is bind-mounted — leaving user config in place"
    elif [ -f "${_plugin_tpl}" ]; then
        cp "${_plugin_tpl}" "${_plugin_cfg}"
        chmod 600 "${_plugin_cfg}"
        echo "  ✓ oh-my-opencode-slim.json refreshed from template"
    fi

    # ─── Validate oh-my-opencode-slim model references ──────────────
    # Two-phase validation:
    #   1. Static: check template against full catalog (catches typos)
    #   2. Runtime: check against the already-filtered catalog we got above
    #      (warns about unavailable models that may cause fallback failures).
    # Both phases reuse catalogs we already have — no repeated discovery.
    if [ -f "${_plugin_cfg}" ] && [ -s "${MODEL_CATALOG}" ]; then
        # Phase 1: Static validation against full catalog
        local _full_catalog
        _full_catalog=$(cat "${MODEL_CATALOG}")
        if ! _validate_plugin_models "${_plugin_cfg}" "${_full_catalog}" "static"; then
            _fail_plugin_validation "static"
        fi

        # Phase 2: Runtime validation against the filtered catalog from above
        # No need to call _get_catalog_for_agent again — we already have it.
        if ! _validate_plugin_models "${_plugin_cfg}" "${_opencode_catalog}" "runtime"; then
            _fail_plugin_validation "runtime"
        fi
        _report_plugin_model_status "${_plugin_cfg}" "${_opencode_catalog}"
    fi

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

# ─── Pi extension wiring ────────────────────────────────────────────
# Pi has no MCP client, permission gates, or subagents of its own; CodeBox
# supplies all three from lib/pi-ext/. They live under lib/ rather than in a
# directory of their own so they inherit the existing
# ./lib:/opt/opencode/lib:ro dev mount — every service already carries
# it, including the docker-compose.override.yml ones that use
# `volumes: !override` and would otherwise silently run image-baked
# copies (see the Dev Workflow warning in AGENTS.md).
#
# Pi discovers these through settings.json's "extensions" array, which
# takes absolute paths. Missing paths there are ignored *silently*, so
# every entry is checked for readability here and logged either way.
# Sets _PI_EXTENSIONS_JSON to a JSON array of paths.
PI_EXT_DIR="/opt/opencode/lib/pi-ext"
PI_SUBAGENT_TEMPLATE_DIR="/opt/opencode/templates/pi-subagents"

# The upstream Pi subagent extension discovers agents/prompts from the
# persistent Pi config directory. Seed CodeBox's useful defaults once, but
# never overwrite a user's customized files in that volume. Keeping the
# definitions in templates also lets a normal restart pick up new defaults
# for agents the user has not customized.
_pi_subagent_resources() {
    local kind source target file
    for kind in agents prompts; do
        source="${PI_SUBAGENT_TEMPLATE_DIR}/${kind}"
        target="${PI_CODING_AGENT_DIR}/${kind}"
        [ -d "${source}" ] || continue
        mkdir -p "${target}"
        chmod 700 "${target}"
        for file in "${source}"/*.md; do
            [ -f "${file}" ] || continue
            if [ ! -e "${target}/$(basename "${file}")" ]; then
                cp "${file}" "${target}/"
                chmod 600 "${target}/$(basename "${file}")"
                echo "  ✓ Pi subagent default: ${kind}/$(basename "${file}")"
            fi
        done
    done
}

_pi_extensions() {
    local -a exts=()
    local file

    # Guard: path protection + docker self-destruct interception.
    if _is_true "${CODEBOX_PI_GUARD:-true}"; then
        file="${PI_EXT_DIR}/codebox-guard.ts"
        if [ -r "${file}" ]; then
            exts+=("${file}")
            echo "  ✓ Extension: codebox-guard (protects .env/credentials, blocks self-destructive docker)"
        else
            echo "  ⚠ Extension missing, skipping: ${file}"
        fi
    else
        echo "  → codebox-guard disabled (CODEBOX_PI_GUARD=${CODEBOX_PI_GUARD})"
    fi

    # Subagents: CodeBox vendors Pi's public reference extension and its
    # model-pinned scout/planner/reviewer/worker definitions. Each delegate
    # runs as an isolated Pi process. Omit it from children so a delegate
    # cannot recursively dispatch more delegates and pay the schema cost.
    if _is_true "${CODEBOX_PI_SUBAGENTS:-true}"; then
        if [ "${CODEBOX_PI_SUBAGENT_CHILD:-}" = "1" ]; then
            echo "  → codebox-subagents omitted in delegated Pi process"
        else
            file="${PI_EXT_DIR}/subagent/index.ts"
            if [ -r "${file}" ]; then
                _pi_subagent_resources
                exts+=("${file}")
                echo "  ✓ Extension: codebox-subagents (isolated, model-pinned task delegation)"
            else
                echo "  ⚠ Extension missing, skipping: ${file}"
            fi
        fi
    else
        echo "  → codebox-subagents disabled (CODEBOX_PI_SUBAGENTS=${CODEBOX_PI_SUBAGENTS})"
    fi

    # MCP bridge: needs the assembled server list, so it is only worth
    # loading when that file has servers in it.
    local mcp_config="${PI_CODING_AGENT_DIR}/mcp-servers.json"
    # Tell the extension where both files are instead of letting it guess:
    # it can only derive them from PI_CODING_AGENT_DIR, and a user who
    # bind-mounts a different config dir would silently get no MCP tools.
    export CODEBOX_PI_MCP_CONFIG="${mcp_config}"
    export CODEBOX_PI_MCP_CACHE="${PI_CODING_AGENT_DIR}/mcp-tools-cache.json"
    if _is_true "${CODEBOX_PI_MCP:-true}"; then
        _generate_mcp_server_config "${mcp_config}" "Pi"
        chmod 600 "${mcp_config}" 2>/dev/null || true
        file="${PI_EXT_DIR}/codebox-mcp.ts"
        if [ ! -r "${file}" ]; then
            echo "  ⚠ Extension missing, skipping: ${file}"
        elif [ "$(jq -r '.mcpServers | length' "${mcp_config}" 2>/dev/null || echo 0)" = "0" ]; then
            echo "  → codebox-mcp not loaded (no MCP servers enabled)"
        else
            exts+=("${file}")
            echo "  ✓ Extension: codebox-mcp (MCP tools for Pi; tool schemas cost context — trim with CODEBOX_MCP_<NAME>=false)"
        fi
    else
        # The config lives in the pi-data volume, so a stale copy would
        # outlive the opt-out and keep feeding the extension servers.
        rm -f "${mcp_config}" "${CODEBOX_PI_MCP_CACHE}"
        echo "  → codebox-mcp disabled (CODEBOX_PI_MCP=${CODEBOX_PI_MCP})"
    fi

    if [ "${#exts[@]}" -eq 0 ]; then
        _PI_EXTENSIONS_JSON="[]"
    else
        _PI_EXTENSIONS_JSON=$(printf '%s\n' "${exts[@]}" | jq -R . | jq -s .)
    fi
}

# ─── Pi config generation ───────────────────────────────────────────
# Pi (pi.dev) reads its config from PI_CODING_AGENT_DIR (default
# ~/.pi/agent, matched by PI_CONFIG_DIR/the Dockerfile's mkdir). Pi has
# no *built-in* MCP client or subagents; CodeBox adds both as extensions,
# so the CODEBOX_MCP_<NAME> gates apply here too — see _pi_extensions().
_configure_pi() {
    echo "→ Generating Pi config..."

    # 1. Pin the config dir so every Pi invocation (including tmux
    #    respawns, which re-exec the binary) agrees on where it lives.
    export PI_CODING_AGENT_DIR="${PI_CONFIG_DIR}"
    mkdir -p "${PI_CODING_AGENT_DIR}"
    chmod 700 "${PI_CODING_AGENT_DIR}"

    # 2. Disable startup update-checks/telemetry network calls by default —
    #    containers shouldn't phone home on every boot. User-overridable.
    export PI_OFFLINE="${PI_OFFLINE:-1}"
    if [ "${PI_OFFLINE}" = "1" ] || [ "${PI_OFFLINE}" = "true" ]; then
        echo "  ✓ PI_OFFLINE enabled (no update-check/telemetry network calls)"
    else
        echo "  → PI_OFFLINE disabled (PI_OFFLINE=${PI_OFFLINE})"
    fi

    local models_file="${PI_CODING_AGENT_DIR}/models.json"
    local settings_file="${PI_CODING_AGENT_DIR}/settings.json"
    local _models_written="false"

    # 3. Generate models.json — only if we have a gateway to point at.
    #    The apiKey is written as the literal string "$LLM_API_KEY" (NOT
    #    the expanded secret) so Pi interpolates it from the environment
    #    at runtime; the secret itself never touches disk. Do NOT also
    #    write an auth.json for Pi — the docs warn against configuring a
    #    credential in both auth.json and models.json for the same
    #    provider, and this env-interpolation route already covers it.
    if [ -n "${LLM_BASE_URL:-}" ]; then
        if grep -qE " ${models_file}( |$)" /proc/self/mountinfo 2>/dev/null; then
            echo "  → models.json is bind-mounted — leaving user config in place"
        else
            # PI_API is the *provider-level* default, used for models that
            # don't pin their own "api" in the catalog (i.e. the GPT family).
            local _pi_api="${PI_API:-openai-completions}"
            case "${_pi_api}" in
                openai-completions|openai-responses|anthropic-messages|google-generative-ai) ;;
                *)
                    echo "  ⚠ Invalid PI_API='${_pi_api}' — falling back to openai-completions"
                    echo "    Valid: openai-completions openai-responses anthropic-messages google-generative-ai"
                    _pi_api="openai-completions"
                    ;;
            esac

            # Never assign straight into _models_json from a command that
            # can fail: an empty value reaches `jq --argjson` as invalid
            # JSON, jq exits 2, and the redirect below has already
            # truncated models_file — leaving a 0-byte file behind a
            # "✓ written" line. Stage in a scratch var and keep [] as the
            # floor instead.
            local _models_json="[]" _pi_catalog="" _catalog_models=""
            if [ -s "${MODEL_CATALOG}" ]; then
                if ! _pi_catalog=$(_get_catalog_for_agent); then
                    # Gateway discovery failed
                    if _is_true "${CODEBOX_REQUIRE_LLM_GATEWAY:-false}"; then
                        # Gateway required but unavailable - fail
                        echo "  ✗ Configuration failed: unable to get model catalog" >&2
                        return 1
                    fi
                    # Not required - continue with empty catalog (will use fallback below)
                elif _catalog_models=$(_pi_models_from_catalog "${_pi_catalog}") \
                   && [ -n "${_catalog_models}" ]; then
                    _models_json="${_catalog_models}"
                    echo "  ✓ Model catalog: $(jq 'length' <<<"${_models_json}") models injected"
                fi
            fi

            if [ "${_models_json}" = "[]" ]; then
                if [ -n "${PI_MODEL:-}" ]; then
                    # Catalog missing/unreadable or filtered to nothing — fall back to a
                    # single entry so Pi still boots. Limits must stay explicit: pi's own
                    # defaults are 128K context / 16K output, and the 16K output cap would
                    # silently truncate long replies.
                    echo "  ⚠ Model catalog unavailable — declaring only ${PI_MODEL} with assumed limits"
                    _models_json=$(jq -n --arg id "${PI_MODEL}" \
                        '[{id: $id, name: $id, reasoning: true, input: ["text","image"],
                           contextWindow: 200000, maxTokens: 64000}]') || _models_json="[]"
                else
                    echo "  ⚠ No models available and PI_MODEL unset — pick a model via /model"
                fi
            fi

            # Write via temp file: a failed jq must not leave a truncated
            # models.json behind, and must not claim defaultProvider=llm in
            # settings.json for a provider that never got written.
            if jq -n --arg baseUrl "${LLM_BASE_URL}" --arg api "${_pi_api}" \
                --arg apiKey '$LLM_API_KEY' --argjson models "${_models_json}" '{
                providers: {
                    llm: {
                        baseUrl: $baseUrl,
                        api: $api,
                        apiKey: $apiKey,
                        authHeader: true,
                        models: $models
                    }
                }
            }' > "${models_file}.tmp" && [ -s "${models_file}.tmp" ]; then
                mv "${models_file}.tmp" "${models_file}"
                chmod 600 "${models_file}"
                echo "  ✓ models.json written (${LLM_BASE_URL}, default api=${_pi_api})"
                _models_written="true"
            else
                rm -f "${models_file}.tmp"
                echo "  ✗ models.json generation FAILED — leaving previous file untouched"
                echo "    Pi will fall back to its built-in providers; check ${MODEL_CATALOG}"
            fi
        fi
    else
        echo "  → models.json skipped (LLM_BASE_URL not set)"
    fi

    # 4. Resolve extensions before settings.json is written — their paths
    #    go into it. Also assembles mcp-servers.json as a side effect.
    _PI_EXTENSIONS_JSON="[]"
    _pi_extensions

    # 5. Generate settings.json.
    if grep -qE " ${settings_file}( |$)" /proc/self/mountinfo 2>/dev/null; then
        echo "  → settings.json is bind-mounted — leaving user config in place"
        if [ "${_PI_EXTENSIONS_JSON}" != "[]" ]; then
            echo "    ⚠ CodeBox extensions are NOT active: add them to your own"
            echo "      settings.json \"extensions\" array: ${_PI_EXTENSIONS_JSON}"
        fi
    else
        # defaultProjectTrust: default "always" — /workspace is the user's
        # own mounted repo and CodeBox already pre-trusts it for Claude Code
        # (hasTrustDialogAccepted: true, above), so this is the consistent
        # choice, and it avoids a blocking trust prompt in the headless
        # tmux/ttyd pane.
        local _pi_trust="${PI_PROJECT_TRUST:-always}"
        case "${_pi_trust}" in
            ask|always|never) ;;
            *)
                echo "  ⚠ Invalid PI_PROJECT_TRUST='${_pi_trust}' — falling back to always"
                echo "    Valid: ask always never"
                _pi_trust="always"
                ;;
        esac

        local _pi_theme="dark"
        [ "${CODEBOX_THEME:-dark}" = "light" ] && _pi_theme="light"

        local _pi_thinking=""
        if [ -n "${PI_THINKING:-}" ]; then
            case "${PI_THINKING}" in
                off|minimal|low|medium|high|xhigh|max) _pi_thinking="${PI_THINKING}" ;;
                *)
                    echo "  ⚠ Ignoring invalid PI_THINKING='${PI_THINKING}'"
                    echo "    Valid: off minimal low medium high xhigh max"
                    ;;
            esac
        fi

        local _pi_proxy="${HTTPS_PROXY:-${HTTP_PROXY:-}}"

        # Thinking budgets. Pi's defaults stop at high=16384, sized for
        # 16K-output models; the catalog's Claude entries allow 64–128K
        # output, so raise them and give xhigh/max real headroom. Only
        # consumed by APIs with native token budgets (anthropic-messages
        # here) — the OpenAI route sends reasoning_effort and ignores these.
        local _pi_budgets='{"minimal":1024,"low":4096,"medium":16384,"high":32768,"xhigh":49152,"max":65536}'
        if [ -n "${PI_THINKING_BUDGETS:-}" ]; then
            if jq -e . <<<"${PI_THINKING_BUDGETS}" &>/dev/null; then
                _pi_budgets="${PI_THINKING_BUDGETS}"
                echo "  ✓ Using PI_THINKING_BUDGETS override"
            else
                echo "  ⚠ PI_THINKING_BUDGETS is not valid JSON — using defaults"
            fi
        fi

        # Reserve enough context for a full-length reply plus thinking.
        # Pi's 16384 default is smaller than the max output of every model
        # in the catalog, so a long answer could be cut off by compaction
        # firing too late.
        local _pi_reserve="${PI_COMPACTION_RESERVE:-32768}"

        jq -n \
            --arg trust "${_pi_trust}" \
            --arg theme "${_pi_theme}" \
            --arg provider "llm" \
            --arg model "${PI_MODEL:-}" \
            --arg thinking "${_pi_thinking}" \
            --arg proxy "${_pi_proxy}" \
            --argjson budgets "${_pi_budgets}" \
            --argjson reserve "${_pi_reserve}" \
            --argjson exts "${_PI_EXTENSIONS_JSON}" \
            --argjson models_written "${_models_written}" '
            {
                defaultProjectTrust: $trust,
                theme: $theme,
                enableInstallTelemetry: false,
                enableAnalytics: false,
                thinkingBudgets: $budgets,
                compaction: {enabled: true, reserveTokens: $reserve},
                showCacheMissNotices: true
            }
            + (if ($exts | length) > 0 then {extensions: $exts} else {} end)
            + (if $models_written then {defaultProvider: $provider} else {} end)
            + (if $model != "" then {defaultModel: $model} else {} end)
            + (if $thinking != "" then {defaultThinkingLevel: $thinking} else {} end)
            + (if $proxy != "" then {httpProxy: $proxy} else {} end)
        ' > "${settings_file}"
        chmod 600 "${settings_file}"
        echo "  ✓ settings.json written (trust=${_pi_trust}, theme=${_pi_theme}, extensions=$(jq 'length' <<<"${_PI_EXTENSIONS_JSON}"))"
    fi

    # 6. Credential presence check — Pi can also authenticate from
    #    standard provider env vars, not just models.json's apiKey field.
    if [ -z "${LLM_API_KEY:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
        echo "  ⚠ No API key set — Pi requires LLM_API_KEY, ANTHROPIC_API_KEY, or OPENAI_API_KEY"
        echo "    Note: OAuth /login does NOT work in headless Docker"
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
