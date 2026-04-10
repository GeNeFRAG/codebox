#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# agent-status.sh — tmux status bar: active subagent count + names
# ═══════════════════════════════════════════════════════════════════
# Called by tmux status-right every status-interval seconds.
# Queries the opencode SQLite database for active subagent sessions.
# Outputs a short tmux-formatted string like "2 ⚡explorer·fixer"
# or empty string when idle.
#
# Usage: bash /opt/opencode/agent-status.sh

DB="/root/.local/share/opencode/opencode.db"

# ─── Theme colors (dark/light) ────────────────────────────────────
_theme=$(cat /tmp/.tmux-theme 2>/dev/null || echo "dark")
if [ "$_theme" = "light" ]; then
    _count="#8c6c3e"; _sep="#8990b3"; _name="#3760bf"
else
    _count="#e0af68"; _sep="#565f89"; _name="#a9b1d6"
fi

# A session is active if its last assistant message has NOT completed:
# either $.finish is NULL/tool-calls, or $.finish="stop" but
# $.time.completed is not yet set (LLM still streaming).
# The safety timeout evicts sessions stuck without ever completing.
SAFETY_TIMEOUT_MS=120000

now_ms=$(date +%s%3N 2>/dev/null || echo "0")
[[ "$now_ms" =~ ^[0-9]+$ ]] || now_ms=0
STARTUP_TS=$(cat /tmp/.opencode-startup-ts 2>/dev/null || echo "0")
[[ "$STARTUP_TS" =~ ^[0-9]+$ ]] || STARTUP_TS=0

# Query active subagent sessions (only from current container lifecycle).
# Uses a pre-aggregated subquery instead of correlated subqueries for speed.
result=$(sqlite3 -separator $'\t' "$DB" "
    SELECT
        COALESCE(first_msg.agent, 'unknown') as agent
    FROM session s
    LEFT JOIN (
        SELECT
            m.session_id,
            json_extract(m.data, '$.agent') as agent
        FROM message m
        INNER JOIN (
            SELECT session_id, MIN(rowid) as min_rowid
            FROM message
            GROUP BY session_id
        ) fm ON m.session_id = fm.session_id AND m.rowid = fm.min_rowid
    ) first_msg ON first_msg.session_id = s.id
    LEFT JOIN (
        SELECT session_id, MAX(time_created) as last_msg_time
        FROM message
        GROUP BY session_id
    ) agg ON agg.session_id = s.id
    LEFT JOIN (
        SELECT
            m.session_id,
            json_extract(m.data, '$.finish') as finish,
            json_extract(m.data, '$.time.completed') as completed
        FROM message m
        INNER JOIN (
            SELECT session_id, MAX(rowid) as max_rowid
            FROM message
            WHERE json_extract(data, '$.role') = 'assistant'
            GROUP BY session_id
        ) lm ON m.session_id = lm.session_id AND m.rowid = lm.max_rowid
        WHERE json_extract(m.data, '$.role') = 'assistant'
    ) last_asst ON last_asst.session_id = s.id
    WHERE s.parent_id IS NOT NULL
      AND s.time_created >= ${STARTUP_TS}
      AND NOT (last_asst.finish = 'stop' AND last_asst.completed IS NOT NULL)
      AND (${now_ms} - COALESCE(agg.last_msg_time, s.time_created)) < ${SAFETY_TIMEOUT_MS}
    ORDER BY s.time_created ASC
" 2>/dev/null)

if [ -z "$result" ]; then
    echo ""
    exit 0
fi

# Deduplicate agent names and count
declare -A names
count=0
while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    names["$agent"]=1
    count=$((count + 1))
done <<< "$result"

if [ "$count" -eq 0 ]; then
    output=""
else
    name_list=$(echo "${!names[@]}" | tr ' ' '·')
    output="#[fg=${_count},bold]${count}#[fg=${_sep}] ⚡#[fg=${_name}]${name_list}"
fi

echo "$output"
