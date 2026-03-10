#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# session-status.sh — tmux status-left: git branch + model + context
# ═══════════════════════════════════════════════════════════════════
# Called by tmux status-left every status-interval seconds.
# Outputs: " opencode │ main │ claude-opus-4-6 │ 94.7k ctx"

# TZ is inherited from the environment (set in entrypoint.sh or .env).
# Defaults to UTC if not set.
export TZ="${TZ:-UTC}"

# ─── File-based cache (avoid spawning opencode db on every tmux refresh) ─
# Session info (model, context size) changes only when the user sends a
# message, so a 30s TTL is fine for idle periods.  When agent-status
# detects active agents, it invalidates this cache so we pick up context
# growth sooner (see agent-status.sh).
CACHE_FILE="/tmp/.session-status-cache"
CACHE_TTL=30  # seconds — model/branch rarely change mid-conversation

if [ -f "$CACHE_FILE" ]; then
    cache_age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
    if [ "$cache_age" -lt "$CACHE_TTL" ]; then
        cat "$CACHE_FILE"
        exit 0
    fi
fi

# ─── Git branch ───────────────────────────────────────────────────
branch=$(git -C /workspace branch --show-current 2>/dev/null || echo "?")

# ─── Current session: model + context size (tokens.total from latest assistant msg)
# Uses LEFT JOIN so a fresh session (after /new) with no messages
# still appears — showing 0 context instead of stale data from the
# previous session.
# Only considers sessions created/updated after container startup to
# avoid showing stale data from a previous container lifecycle.
STARTUP_TS=$(cat /tmp/.opencode-startup-ts 2>/dev/null || echo "0")
OPENCODE="${OPENCODE_BIN_PATH:-opencode}"
read -r model ctx <<< "$($OPENCODE db "
    SELECT
        COALESCE(json_extract(m.data, '\$.modelID'), '?') as model,
        COALESCE(json_extract(m.data, '\$.tokens.total'), 0) as ctx
    FROM session s
    LEFT JOIN message m ON m.session_id = s.id
        AND m.rowid = (SELECT MAX(rowid) FROM message WHERE session_id = s.id AND json_extract(data, '\$.role') = 'assistant' AND json_extract(data, '\$.tokens.total') > 0)
    WHERE s.parent_id IS NULL
      AND s.time_updated >= ${STARTUP_TS}
    ORDER BY s.time_updated DESC
    LIMIT 1
" --format tsv 2>/dev/null | tail -n +2 | head -1)"

# Fall back to the configured model name when the session has no messages yet
model="${model:-${OPENCODE_MODEL:-?}}"
# Strip 'llm/' or provider prefixes for cleaner display
model="${model#llm/}"
model="${model#github-copilot/}"
model="${model#openrouter/}"

# ─── Format context tokens ───────────────────────────────────────
ctx=${ctx:-0}
if [ "$ctx" -ge 1000000 ]; then
    ctx_str="$(( ctx / 1000000 )).$(( (ctx % 1000000) / 100000 ))M"
elif [ "$ctx" -ge 1000 ]; then
    ctx_str="$(( ctx / 1000 )).$(( (ctx % 1000) / 100 ))k"
else
    ctx_str="${ctx}"
fi

# ─── Output ───────────────────────────────────────────────────────
output="#[fg=#7aa2f7,bold] opencode #[fg=#565f89]│#[fg=#9ece6a] ${branch} #[fg=#565f89]│#[fg=#bb9af7] ${model:-?} #[fg=#565f89]│#[fg=#e0af68] ${ctx_str} ctx "
echo "$output" > "$CACHE_FILE"
echo "$output"
