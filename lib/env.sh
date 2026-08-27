# ─── lib/env.sh ─────────────────────────────────────────────────────────────
# Reload .env from mounted file (picks up changes on stop/start) and warn
# about settings that require a full container recreate to take effect.

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

# Snapshot the port before loading so we can detect changes
_ORIG_PORT="${CODEBOX_PORT:-}"

if [ -f /opt/opencode/.env ] && [ -s /opt/opencode/.env ]; then
    _load_env_file /opt/opencode/.env
    echo "→ Reloaded environment from /opt/opencode/.env"
elif [ -f /workspace/.env ] && [ -s /workspace/.env ]; then
    _load_env_file /workspace/.env
    echo "→ Reloaded environment from /workspace/.env"
else
    echo "→ No .env file found (using container environment)"
fi

# ─── Deprecation shim: map old OPENCODE_* shared vars to CODEBOX_* ─
_migrate_var() {
    local old="$1" new="$2"
    if [[ -n "${!old:-}" && -z "${!new:-}" ]]; then
        export "$new=${!old}"
        echo "  WARNING: $old is deprecated, use $new instead" >&2
    fi
}
_migrate_var OPENCODE_APP                       CODEBOX_APP
_migrate_var OPENCODE_MODE                      CODEBOX_MODE
_migrate_var OPENCODE_PORT                      CODEBOX_PORT
_migrate_var OPENCODE_TITLE                     CODEBOX_TITLE
_migrate_var OPENCODE_THEME                     CODEBOX_THEME
_migrate_var OPENCODE_TLS                       CODEBOX_TLS
_migrate_var OPENCODE_TLS_CERT                  CODEBOX_TLS_CERT
_migrate_var OPENCODE_TLS_KEY                   CODEBOX_TLS_KEY
_migrate_var OPENCODE_EXTRA_ARGS                CODEBOX_EXTRA_ARGS
_migrate_var OPENCODE_TUI_ARGS                  CODEBOX_TUI_ARGS
_migrate_var OPENCODE_VERSION                   CODEBOX_VERSION
_migrate_var OPENCODE_ENABLE_EXPERIMENTAL_MODELS CODEBOX_ENABLE_EXPERIMENTAL_MODELS
_migrate_var CACHEBUST_OPENCODE                 CACHEBUST_CODEBOX

# ─── Credential aliases for third-party plugins ────────────────────
# CodeBox names its Atlassian/Grafana secrets JIRA_TOKEN, CONFLUENCE_TOKEN and
# GRAFANA_API_KEY. Its own MCP servers rename them inside each server's `env`
# block (see templates/mcp-servers/), but plugin-supplied MCP servers — e.g. the
# RBI SDLC plugins' remote rbi-atlassian-mcp — interpolate *_PERSONAL_TOKEN /
# GRAFANA_TOKEN straight from the process environment. Export those names here
# so each secret stays declared once in .env.
#
# Aliasing must happen in shell, not .env: _load_env_file() parses .env
# literally, so `JIRA_PERSONAL_TOKEN=${JIRA_TOKEN}` would export the literal
# string '${JIRA_TOKEN}'. An explicitly-set target always wins.
_alias_var() {
    local src="$1" dst="$2"
    if [[ -n "${!src:-}" && -z "${!dst:-}" ]]; then
        export "$dst=${!src}"
        echo "  → Aliased $src → $dst (for plugin MCP servers)"
    fi
}
_alias_var JIRA_TOKEN        JIRA_PERSONAL_TOKEN
_alias_var CONFLUENCE_TOKEN  CONFLUENCE_PERSONAL_TOKEN
_alias_var GRAFANA_API_KEY   GRAFANA_TOKEN

# ─── Warn about non-reloadable changes ─────────────────────────────
if [ "${CODEBOX_PORT:-}" != "${_ORIG_PORT}" ]; then
    if [ -n "${_ORIG_PORT}" ]; then
        echo "  WARNING: CODEBOX_PORT changed (${_ORIG_PORT} → ${CODEBOX_PORT}) — requires 'docker compose up' or './codebox.sh rebuild' to take effect"
        export CODEBOX_PORT="${_ORIG_PORT}"
    else
        echo "  WARNING: CODEBOX_PORT set to ${CODEBOX_PORT} via .env but port mapping was not configured at container creation — requires 'docker compose up' to take effect"
        unset CODEBOX_PORT
    fi
fi
unset _ORIG_PORT
