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

# A session is "active" if it was updated in the last 30 seconds
# and is a subagent (has parent_id)
ACTIVE_THRESHOLD_MS=30000

now_ms=$(date +%s%3N 2>/dev/null || echo "0")

# Query active subagent sessions
result=$(opencode db "
    SELECT
        COALESCE(json_extract(m.data, '\$.agent'), 'unknown') as agent
    FROM session s
    LEFT JOIN message m ON m.session_id = s.id
        AND m.rowid = (SELECT MIN(rowid) FROM message WHERE session_id = s.id)
    WHERE s.parent_id IS NOT NULL
      AND (${now_ms} - s.time_updated) < ${ACTIVE_THRESHOLD_MS}
    ORDER BY s.time_created ASC
" --format tsv 2>/dev/null | tail -n +2)  # skip header

[ -z "$result" ] && { echo ""; exit 0; }

# Deduplicate agent names and count
declare -A names
count=0
while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    names["$agent"]=1
    count=$((count + 1))
done <<< "$result"

if [ "$count" -eq 0 ]; then
    echo ""
else
    name_list=$(echo "${!names[@]}" | tr ' ' '·')
    echo "#[fg=#e0af68,bold]${count}#[fg=#565f89] ⚡#[fg=#a9b1d6]${name_list}"
fi
