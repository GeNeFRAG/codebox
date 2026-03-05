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
# With POLL_INTERVAL=2, this means 5×2=10s of no new messages → done.
# This must be generous enough for agents that pause while "thinking"
# (e.g. oracle can pause 10-20s between messages).
STABLE_THRESHOLD=5

# Seconds of quiet that tells us a session is "definitely done" during
# the initial seed phase (matches the status-bar threshold in agent-status.sh).
SEED_ACTIVE_THRESHOLD_S=15

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
    echo -e "  ${DIM}▶ active  ■ done  ✗ cancelled  ⚠ error${RESET}"
    echo -e "${DIM}─────────────────────────────────────────${RESET}"
    echo ""
}

# ─── Query subagent sessions from the DB ──────────────────────────
# Returns TSV: session_id  agent  model  time_created  msg_count  last_msg_time
# Only considers sessions from the current container lifecycle.
# Uses a single aggregation query (no correlated subqueries) for speed.
_query_subagents() {
    local startup_ts
    startup_ts=$(cat /tmp/.opencode-startup-ts 2>/dev/null || echo "0")
    opencode db "
        SELECT
            s.id,
            COALESCE(first_msg.agent, 'unknown') as agent,
            COALESCE(first_msg.model, '?') as model,
            s.time_created,
            COALESCE(agg.msg_count, 0) as msg_count,
            COALESCE(agg.last_msg_time, s.time_created) as last_msg_time
        FROM session s
        LEFT JOIN (
            SELECT
                m.session_id,
                json_extract(m.data, '\$.agent') as agent,
                json_extract(m.data, '\$.model.modelID') as model
            FROM message m
            INNER JOIN (
                SELECT session_id, MIN(rowid) as min_rowid
                FROM message
                GROUP BY session_id
            ) fm ON m.session_id = fm.session_id AND m.rowid = fm.min_rowid
        ) first_msg ON first_msg.session_id = s.id
        LEFT JOIN (
            SELECT
                session_id,
                COUNT(*) as msg_count,
                MAX(time_created) as last_msg_time
            FROM message
            GROUP BY session_id
        ) agg ON agg.session_id = s.id
        WHERE s.parent_id IS NOT NULL
          AND s.time_created >= ${startup_ts}
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

# ─── Query finish status for a session ────────────────────────────
# Checks the last assistant message for error/cancellation signals.
# Returns: "cancelled", "error:<name>", or "ok"
_query_finish_status() {
    local sid="$1"
    local error_name
    error_name=$(opencode db "
        SELECT COALESCE(json_extract(data, '\$.error.name'), '')
        FROM message
        WHERE session_id = '${sid}'
          AND json_extract(data, '\$.role') = 'assistant'
        ORDER BY rowid DESC
        LIMIT 1
    " --format tsv 2>/dev/null | tail -n +2 | head -1)

    if [ "$error_name" = "MessageAbortedError" ]; then
        echo "cancelled"
    elif [ -n "$error_name" ]; then
        echo "error:${error_name}"
    else
        echo "ok"
    fi
}

# ─── Format token count to human-readable (e.g. 1.2k, 45.3k) ────
_fmt_tokens() {
    local n="${1:-0}"
    # Guard against non-numeric values
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if [ "$n" -ge 1000000 ]; then
        local m=$(( n / 1000 ))
        echo "$(( m / 1000 )).$(( (m % 1000) / 100 ))M"
    elif [ "$n" -ge 1000 ]; then
        echo "$(( n / 1000 )).$(( (n % 1000) / 100 ))k"
    else
        echo "${n}"
    fi
}

# ─── Print a "done" line for a session ────────────────────────────
_print_done() {
    local sid="$1" agent="$2" tcreated="$3" last_msg_time="$4"
    local color
    color=$(_agent_color "$agent")
    local duration=$(( last_msg_time - tcreated ))
    local dur_str
    dur_str=$(_fmt_duration "$duration")
    local ts
    ts=$(_fmt_time "$last_msg_time")
    # Determine finish status (cancelled / error / ok)
    local finish_status status_icon status_label
    finish_status=$(_query_finish_status "$sid")
    case "$finish_status" in
        cancelled)
            status_icon="✗"
            status_label="cancelled"
            ;;
        error:*)
            status_icon="⚠"
            status_label="error"
            ;;
        *)
            status_icon="■"
            status_label="done"
            ;;
    esac
    # Fetch token usage
    local token_line tok_in tok_out tok_cache token_str=""
    token_line=$(_query_tokens "$sid")
    if [ -n "$token_line" ]; then
        IFS=$'\t' read -r tok_in tok_out tok_cache <<< "$token_line"
        token_str="  ${DIM}in:$(_fmt_tokens "$tok_in") out:$(_fmt_tokens "$tok_out") cache:$(_fmt_tokens "$tok_cache")${RESET}"
    fi
    echo -e "  ${color}${status_icon}${RESET} ${BOLD}${agent}${RESET} ${DIM}${status_label}${RESET}  ${GRAY}${dur_str}${RESET}${token_str}  ${DIM}${ts}${RESET}"
}

# ─── Parse a tracked session record ──────────────────────────────
# Format: agent|model|time_created|status|msg_count|last_msg_time|stable_count
_parse_session() {
    local entry="$1"
    IFS='|' read -r _s_agent _s_model _s_tcreated _s_status _s_msg_count _s_last_msg _s_stable <<< "$entry"
}

# ─── Main monitor loop ────────────────────────────────────────────
main() {
    # Ensure TZ defaults to UTC if not set
    export TZ="${TZ:-UTC}"

    _print_header

    # ── Wait for DB readiness ────────────────────────────────────
    local db_ok=false
    for attempt in 1 2 3 4 5; do
        local db_test
        db_test=$(opencode db "SELECT COUNT(*) FROM session" --format tsv 2>&1 | tail -n +2 | head -1)
        if [ -n "$db_test" ] && [[ "$db_test" != *"error"* ]] && [[ "$db_test" != *"Error"* ]]; then
            db_ok=true
            break
        fi
        echo -e "  ${DIM}Waiting for DB... (attempt ${attempt}/5)${RESET}"
        sleep 2
    done
    if [ "$db_ok" = false ]; then
        echo -e "  ${RED}✗ Cannot query DB${RESET}"
        echo ""
    fi

    # Track known sessions
    # key=session_id, value="agent|model|time_created|status|msg_count|last_msg_time|stable_count"
    declare -A known_sessions

    # ── Seed: replay recent sessions, detect currently-active ones ─
    # Sessions from the last REPLAY_WINDOW are shown.
    # CRITICAL FIX: sessions with recent message activity are seeded as
    # "active" so the poll loop continues to track them. Previously all
    # seeds were marked "done", causing running agents to appear finished.
    local REPLAY_WINDOW_MS=300000  # 5 minutes
    local now_ms
    now_ms=$(date +%s%3N 2>/dev/null || echo "0")
    local replay_cutoff=$(( now_ms - REPLAY_WINDOW_MS ))
    local active_cutoff_ms=$(( SEED_ACTIVE_THRESHOLD_S * 1000 ))

    local seed_data old_count=0 replay_count=0 active_count=0
    seed_data=$(_query_subagents)
    while IFS=$'\t' read -r sid agent model tcreated msg_count last_msg_time; do
        [ -z "$sid" ] && continue

        local age_ms=$(( now_ms - last_msg_time ))

        if [ "$tcreated" -lt "$replay_cutoff" ] && [ "$age_ms" -ge "$active_cutoff_ms" ]; then
            # Old session, no recent activity — suppress silently
            known_sessions["$sid"]="${agent}|${model}|${tcreated}|done|${msg_count}|${last_msg_time}|0"
            old_count=$(( old_count + 1 ))

        elif [ "$age_ms" -lt "$active_cutoff_ms" ]; then
            # Recent message activity — this agent may still be running!
            known_sessions["$sid"]="${agent}|${model}|${tcreated}|active|${msg_count}|${last_msg_time}|0"
            active_count=$(( active_count + 1 ))
            local color
            color=$(_agent_color "$agent")
            local ts
            ts=$(_fmt_time "$tcreated")
            echo -e "  ${color}▶${RESET} ${BOLD}${agent}${RESET} ${DIM}active${RESET}  ${GRAY}${model}${RESET}  ${DIM}${ts}${RESET}"

        else
            # Recent session that's finished — replay as done
            known_sessions["$sid"]="${agent}|${model}|${tcreated}|done|${msg_count}|${last_msg_time}|0"
            replay_count=$(( replay_count + 1 ))
            _print_done "$sid" "$agent" "$tcreated" "$last_msg_time"
        fi
    done <<< "$seed_data"

    local summary_parts=()
    [ "$old_count" -gt 0 ] && summary_parts+=("${old_count} historical")
    [ "$replay_count" -gt 0 ] && summary_parts+=("${replay_count} replayed")
    [ "$active_count" -gt 0 ] && summary_parts+=("${active_count} active")
    local summary_str=""
    if [ ${#summary_parts[@]} -gt 0 ]; then
        summary_str=$(IFS=', '; echo "${summary_parts[*]}")
    fi
    echo -e "  ${DIM}Watching... (${summary_str:-no prior sessions})${RESET}"
    echo ""

    # ── Poll loop ─────────────────────────────────────────────────
    while true; do
        sleep "$POLL_INTERVAL"

        local new_data
        new_data=$(_query_subagents)

        # Build a set of current session IDs from the query
        declare -A current_ids

        while IFS=$'\t' read -r sid agent model tcreated msg_count last_msg_time; do
            [ -z "$sid" ] && continue
            current_ids["$sid"]=1

            if [ -z "${known_sessions[$sid]+x}" ]; then
                # ── New session detected — print spawn event
                local color
                color=$(_agent_color "$agent")
                local ts
                ts=$(_fmt_time "$tcreated")
                echo -e "  ${color}▶${RESET} ${BOLD}${agent}${RESET} ${DIM}started${RESET}  ${GRAY}${model}${RESET}  ${DIM}${ts}${RESET}"
                known_sessions["$sid"]="${agent}|${model}|${tcreated}|active|${msg_count}|${last_msg_time}|0"

            elif [[ "${known_sessions[$sid]}" == *"|active|"* ]]; then
                # ── Known active session — check for message activity changes
                local prev_data="${known_sessions[$sid]}"
                _parse_session "$prev_data"
                local prev_msg_count="$_s_msg_count"
                local prev_last_msg="$_s_last_msg"
                local stable_count="$_s_stable"

                if [ "$msg_count" = "$prev_msg_count" ] && [ "$last_msg_time" = "$prev_last_msg" ]; then
                    # No new messages — increment stable counter
                    stable_count=$(( stable_count + 1 ))
                else
                    # Activity detected — reset stable counter
                    stable_count=0
                fi

                if [ "$stable_count" -ge "$STABLE_THRESHOLD" ]; then
                    # Stable long enough — mark as done
                    _print_done "$sid" "$agent" "$tcreated" "$last_msg_time"
                    known_sessions["$sid"]="${agent}|${model}|${tcreated}|done|${msg_count}|${last_msg_time}|0"
                else
                    # Still active — update tracking
                    known_sessions["$sid"]="${agent}|${model}|${tcreated}|active|${msg_count}|${last_msg_time}|${stable_count}"
                fi
            fi
        done <<< "$new_data"

        # ── Check for sessions that disappeared from DB while active
        for sid in "${!known_sessions[@]}"; do
            _parse_session "${known_sessions[$sid]}"
            [ "$_s_status" != "active" ] && continue

            if [ -z "${current_ids[$sid]+x}" ]; then
                local color
                color=$(_agent_color "$_s_agent")
                echo -e "  ${color}■${RESET} ${BOLD}${_s_agent}${RESET} ${DIM}gone${RESET}"
                known_sessions["$sid"]="${_s_agent}|${_s_model}|${_s_tcreated}|done|${_s_msg_count}|${_s_last_msg}|0"
            fi
        done

        unset current_ids
    done
}

main "$@"
