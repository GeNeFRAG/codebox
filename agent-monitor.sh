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
        explorer)     echo -e "${GREEN}" ;;
        fixer)        echo -e "${YELLOW}" ;;
        oracle)       echo -e "${MAGENTA}" ;;
        librarian)    echo -e "${CYAN}" ;;
        designer)     echo -e "${RED}" ;;
        *)            echo -e "${RESET}" ;;
    esac
}

# ─── Format millisecond timestamp to HH:MM:SS ────────────────────
_fmt_time() {
    local ms="$1"
    local secs=$(( ms / 1000 ))
    date -d "@${secs}" '+%H:%M:%S' 2>/dev/null || echo "??:??:??"
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
# Returns TSV: session_id  agent  model  time_created  time_updated
_query_subagents() {
    opencode db "
        SELECT
            s.id,
            COALESCE(json_extract(m.data, '\$.agent'), 'unknown') as agent,
            COALESCE(json_extract(m.data, '\$.model.modelID'), '?') as model,
            s.time_created,
            s.time_updated
        FROM session s
        LEFT JOIN message m ON m.session_id = s.id
            AND m.rowid = (SELECT MIN(rowid) FROM message WHERE session_id = s.id)
        WHERE s.parent_id IS NOT NULL
        ORDER BY s.time_created ASC
    " --format tsv 2>/dev/null | tail -n +2  # skip header
}

# ─── Main monitor loop ────────────────────────────────────────────
main() {
    _print_header

    # Track known sessions: key=session_id, value="agent|model|time_created|status[|time_updated]"
    declare -A known_sessions

    # ── Seed: silently register all existing sessions as "done" ──
    # so we only display NEW events going forward
    local seed_data
    seed_data=$(_query_subagents)
    while IFS=$'\t' read -r sid agent model tcreated tupdated; do
        [ -z "$sid" ] && continue
        known_sessions["$sid"]="${agent}|${model}|${tcreated}|done"
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

        while IFS=$'\t' read -r sid agent model tcreated tupdated; do
            [ -z "$sid" ] && continue
            current_ids["$sid"]=1

            if [ -z "${known_sessions[$sid]+x}" ]; then
                # New session detected — print spawn event
                local color
                color=$(_agent_color "$agent")
                local ts
                ts=$(_fmt_time "$tcreated")
                echo -e "  ${color}▶${RESET} ${BOLD}${agent}${RESET} ${DIM}started${RESET}  ${GRAY}${model}${RESET}  ${DIM}${ts}${RESET}"
                known_sessions["$sid"]="${agent}|${model}|${tcreated}|active|${tupdated}"

            elif [[ "${known_sessions[$sid]}" == *"|active"* ]]; then
                # Known active session — update the time_updated
                local prev_data="${known_sessions[$sid]}"
                local prev_agent="${prev_data%%|*}"
                known_sessions["$sid"]="${prev_agent}|${model}|${tcreated}|active|${tupdated}"
            fi
        done <<< "$new_data"

        # Check for completed sessions (time_updated stopped changing)
        for sid in "${!known_sessions[@]}"; do
            local entry="${known_sessions[$sid]}"
            IFS='|' read -r agent model tcreated status prev_updated <<< "$entry"

            [ "$status" != "active" ] && continue

            if [ -z "${current_ids[$sid]+x}" ]; then
                # Session disappeared from DB
                local color
                color=$(_agent_color "$agent")
                echo -e "  ${color}■${RESET} ${BOLD}${agent}${RESET} ${DIM}gone${RESET}"
                known_sessions["$sid"]="${agent}|${model}|${tcreated}|done"
                continue
            fi

            # Get current time_updated
            local cur_updated
            cur_updated=$(echo "$new_data" | grep "^${sid}" | cut -f5)

            if [ -n "$prev_updated" ] && [ -n "$cur_updated" ] && [ "$prev_updated" = "$cur_updated" ]; then
                # time_updated stable — session is done
                local color
                color=$(_agent_color "$agent")
                local duration=$(( cur_updated - tcreated ))
                local dur_str
                dur_str=$(_fmt_duration "$duration")
                local ts
                ts=$(_fmt_time "$cur_updated")
                echo -e "  ${color}■${RESET} ${BOLD}${agent}${RESET} ${DIM}done${RESET}  ${GRAY}${dur_str}${RESET}  ${DIM}${ts}${RESET}"
                known_sessions["$sid"]="${agent}|${model}|${tcreated}|done"
            fi
        done

        unset current_ids
        sleep "$POLL_INTERVAL"
    done
}

main "$@"
