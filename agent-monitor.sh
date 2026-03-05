#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# agent-monitor.sh — Subagent activity monitor for tmux pane
# ═══════════════════════════════════════════════════════════════════
# Polls the opencode SQLite database to display a real-time view
# of subagent lifecycle events (spawned, active, completed).
#
# Usage: bash /opt/opencode/agent-monitor.sh
#
# Designed to run in a tmux split pane alongside the opencode TUI.

POLL_INTERVAL=2  # seconds between DB polls
# Number of consecutive stable polls before marking done.
# With POLL_INTERVAL=2, this means 3*2=6s of no new messages → done.
STABLE_THRESHOLD=3

# ─── Colors ───────────────────────────────────────────────────────
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
BLUE="\033[38;5;111m"
GREEN="\033[38;5;114m"
YELLOW="\033[38;5;215m"
MAGENTA="\033[38;5;177m"
CYAN="\033[38;5;80m"
RED="\033[38;5;204m"
GRAY="\033[38;5;243m"

# ─── Agent color map ─────────────────────────────────────────────
_agent_color() {
    case "$1" in
        orchestrator) echo -e "${BLUE}" ;;
        explorer|explore) echo -e "${GREEN}" ;;
        fixer)        echo -e "${YELLOW}" ;;
        oracle)       echo -e "${MAGENTA}" ;;
        librarian)    echo -e "${CYAN}" ;;
        designer)     echo -e "${RED}" ;;
        *)            echo -e "${RESET}" ;;
    esac
}

# ─── Format millisecond timestamp to HH:MM:SS (local time) ───────
_fmt_time() {
    local ms="$1"
    local secs=$(( ms / 1000 ))
    TZ="${AGENT_MONITOR_TZ:-${TZ:-UTC}}" date -d "@${secs}" '+%H:%M:%S' 2>/dev/null || echo "??:??:??"
}

# ─── Format duration in ms to human-readable ─────────────────────
_fmt_duration() {
    local ms="$1"
    local secs=$(( ms / 1000 ))
    if [ "$secs" -lt 60 ]; then
        echo "${secs}s"
    else
        local mins=$(( secs / 60 ))
        local rem=$(( secs % 60 ))
        echo "${mins}m${rem}s"
    fi
}

# ─── Header ───────────────────────────────────────────────────────
_print_header() {
    clear
    echo -e "${DIM}─────────────────────────────────────────${RESET}"
    echo -e "${BOLD}  🔭 Agent Monitor${RESET}"
    echo -e "${DIM}─────────────────────────────────────────${RESET}"
    echo -e "  ${BLUE}■${RESET} orchestrator  ${GREEN}■${RESET} explorer  ${YELLOW}■${RESET} fixer"
    echo -e "  ${MAGENTA}■${RESET} oracle  ${CYAN}■${RESET} librarian  ${RED}■${RESET} designer"
    echo -e "${DIM}─────────────────────────────────────────${RESET}"
    echo ""
}

# ─── Query subagent sessions from the DB ──────────────────────────
# Returns TSV: session_id  agent  model  time_created  msg_count  last_msg_time
_query_subagents() {
    opencode db "
        SELECT
            s.id,
            COALESCE(json_extract(m.data, '\$.agent'), 'unknown') as agent,
            COALESCE(json_extract(m.data, '\$.model.modelID'), '?') as model,
            s.time_created,
            (SELECT COUNT(*) FROM message WHERE session_id = s.id) as msg_count,
            (SELECT COALESCE(MAX(time_created), s.time_created) FROM message WHERE session_id = s.id) as last_msg_time
        FROM session s
        LEFT JOIN message m ON m.session_id = s.id
            AND m.rowid = (SELECT MIN(rowid) FROM message WHERE session_id = s.id)
        WHERE s.parent_id IS NOT NULL
        ORDER BY s.time_created ASC
    " --format tsv 2>/dev/null | tail -n +2  # skip header
}

# ─── Query token usage for a completed session ───────────────────
# Returns TSV: total_input  total_output  total_cache_read
_query_tokens() {
    local sid="$1"
    opencode db "
        SELECT
            COALESCE(SUM(json_extract(data, '\$.tokens.input')), 0),
            COALESCE(SUM(json_extract(data, '\$.tokens.output')), 0),
            COALESCE(SUM(json_extract(data, '\$.tokens.cache.read')), 0)
        FROM message
        WHERE session_id = '${sid}'
          AND json_extract(data, '\$.role') = 'assistant'
    " --format tsv 2>/dev/null | tail -n +2 | head -1
}

# ─── Format token count to human-readable (e.g. 1.2k, 45.3k) ────
_fmt_tokens() {
    local n="$1"
    if [ "$n" -ge 1000000 ]; then
        local m=$(( n / 1000 ))
        echo "$(( m / 1000 )).$(( (m % 1000) / 100 ))M"
    elif [ "$n" -ge 1000 ]; then
        echo "$(( n / 1000 )).$(( (n % 1000) / 100 ))k"
    else
        echo "${n}"
    fi
}

# ─── Main monitor loop ────────────────────────────────────────────
main() {
    _print_header

    # Track known sessions
    # key=session_id, value="agent|model|time_created|status|msg_count|last_msg_time|stable_count"
    declare -A known_sessions

    # ── Seed: silently register all existing sessions as "done" ──
    # so we only display NEW events going forward
    local seed_data
    seed_data=$(_query_subagents)
    while IFS=$'\t' read -r sid agent model tcreated msg_count last_msg_time; do
        [ -z "$sid" ] && continue
        known_sessions["$sid"]="${agent}|${model}|${tcreated}|done|${msg_count}|${last_msg_time}|0"
    done <<< "$seed_data"

    local seed_count=${#known_sessions[@]}
    echo -e "  ${DIM}Watching for subagent activity... (${seed_count} historical sessions)${RESET}"
    echo ""

    # ── Poll loop ─────────────────────────────────────────────────
    while true; do
        local new_data
        new_data=$(_query_subagents)

        # Build a set of current session IDs
        declare -A current_ids

        while IFS=$'\t' read -r sid agent model tcreated msg_count last_msg_time; do
            [ -z "$sid" ] && continue
            current_ids["$sid"]=1

            if [ -z "${known_sessions[$sid]+x}" ]; then
                # New session detected — print spawn event
                local color
                color=$(_agent_color "$agent")
                local ts
                ts=$(_fmt_time "$tcreated")
                echo -e "  ${color}▶${RESET} ${BOLD}${agent}${RESET} ${DIM}started${RESET}  ${GRAY}${model}${RESET}  ${DIM}${ts}${RESET}"
                known_sessions["$sid"]="${agent}|${model}|${tcreated}|active|${msg_count}|${last_msg_time}|0"

            elif [[ "${known_sessions[$sid]}" == *"|active|"* ]]; then
                # Known active session — check if message activity changed
                local prev_data="${known_sessions[$sid]}"
                local prev_msg_count prev_last_msg stable_count
                prev_msg_count=$(echo "$prev_data" | cut -d'|' -f5)
                prev_last_msg=$(echo "$prev_data" | cut -d'|' -f6)
                stable_count=$(echo "$prev_data" | cut -d'|' -f7)

                if [ "$msg_count" = "$prev_msg_count" ] && [ "$last_msg_time" = "$prev_last_msg" ]; then
                    # No new messages — increment stable counter
                    stable_count=$(( stable_count + 1 ))
                else
                    # Activity detected — reset stable counter
                    stable_count=0
                fi

                if [ "$stable_count" -ge "$STABLE_THRESHOLD" ]; then
                    # Stable long enough — mark as done
                    local color
                    color=$(_agent_color "$agent")
                    local duration=$(( last_msg_time - tcreated ))
                    local dur_str
                    dur_str=$(_fmt_duration "$duration")
                    local ts
                    ts=$(_fmt_time "$last_msg_time")
                    # Fetch token usage
                    local token_line tok_in tok_out tok_cache token_str=""
                    token_line=$(_query_tokens "$sid")
                    if [ -n "$token_line" ]; then
                        IFS=$'\t' read -r tok_in tok_out tok_cache <<< "$token_line"
                        local total_tok=$(( tok_in + tok_out + tok_cache ))
                        token_str="  ${DIM}in:$(_fmt_tokens "$tok_in") out:$(_fmt_tokens "$tok_out") cache:$(_fmt_tokens "$tok_cache")${RESET}"
                    fi
                    echo -e "  ${color}■${RESET} ${BOLD}${agent}${RESET} ${DIM}done${RESET}  ${GRAY}${dur_str}${RESET}${token_str}  ${DIM}${ts}${RESET}"
                    known_sessions["$sid"]="${agent}|${model}|${tcreated}|done|${msg_count}|${last_msg_time}|0"
                else
                    # Still active — update tracking
                    known_sessions["$sid"]="${agent}|${model}|${tcreated}|active|${msg_count}|${last_msg_time}|${stable_count}"
                fi
            fi
        done <<< "$new_data"

        # Check for sessions that disappeared from DB while active
        for sid in "${!known_sessions[@]}"; do
            local entry="${known_sessions[$sid]}"
            local status
            status=$(echo "$entry" | cut -d'|' -f4)

            [ "$status" != "active" ] && continue

            if [ -z "${current_ids[$sid]+x}" ]; then
                local agent
                agent=$(echo "$entry" | cut -d'|' -f1)
                local color
                color=$(_agent_color "$agent")
                echo -e "  ${color}■${RESET} ${BOLD}${agent}${RESET} ${DIM}gone${RESET}"
                known_sessions["$sid"]="${entry%|*|*|*|*}|done|0|0|0"
            fi
        done

        unset current_ids
        sleep "$POLL_INTERVAL"
    done
}

main "$@"
