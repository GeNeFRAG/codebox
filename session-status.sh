#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# session-status.sh — tmux status-left: git branch + model + context
# ═══════════════════════════════════════════════════════════════════
# Called by tmux status-left every status-interval seconds.
# Outputs: " opencode │ main │ claude-opus-4-6 │ 94.7k ctx"

TZ="${AGENT_MONITOR_TZ:-${TZ:-Europe/Berlin}}"

# ─── Git branch ───────────────────────────────────────────────────
branch=$(git -C /workspace branch --show-current 2>/dev/null || echo "?")

# ─── Current session: model + context size (tokens.total from latest assistant msg)
read -r model ctx <<< "$(opencode db "
    SELECT
        COALESCE(json_extract(m.data, '\$.modelID'), '?') as model,
        COALESCE(json_extract(m.data, '\$.tokens.total'), 0) as ctx
    FROM session s
    JOIN message m ON m.session_id = s.id
        AND m.rowid = (SELECT MAX(rowid) FROM message WHERE session_id = s.id AND json_extract(data, '\$.role') = 'assistant' AND json_extract(data, '\$.tokens.total') > 0)
    WHERE s.parent_id IS NULL
    ORDER BY s.time_updated DESC
    LIMIT 1
" --format tsv 2>/dev/null | tail -n +2 | head -1)"

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
echo "#[fg=#7aa2f7,bold] opencode #[fg=#565f89]│#[fg=#9ece6a] ${branch} #[fg=#565f89]│#[fg=#bb9af7] ${model:-?} #[fg=#565f89]│#[fg=#e0af68] ${ctx_str} ctx "
