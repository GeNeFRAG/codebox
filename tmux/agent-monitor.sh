#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# agent-monitor.sh — Subagent activity monitor for tmux pane
# ═══════════════════════════════════════════════════════════════════
# Polls the opencode SQLite database to display a real-time view
# of subagent lifecycle events (spawned, active, completed).
#
# Completion is detected via the $.finish field AND $.time.completed
# on the last assistant message.  $.finish="stop" is written when the
# message row is first created, but the LLM may still be streaming.
# $.time.completed is set only after generation finishes.  A session
# is truly done when finish="stop" AND completed is non-empty.
# A safety timeout handles edge cases where finish never arrives.
#
# Usage: bash /opt/opencode/agent-monitor.sh
#
# Designed to run in a tmux split pane alongside the opencode TUI.

POLL_INTERVAL=3        # seconds between DB polls
SAFETY_TIMEOUT_MS=120000  # fallback: mark done if no messages for 2 min
REPLAY_WINDOW_MS=300000   # 5 minutes — how far back to replay on startup

DB="/root/.local/share/opencode/opencode.db"

# ─── Colors (theme-aware) ─────────────────────────────────────────
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

_theme=$(cat /tmp/.tmux-theme 2>/dev/null || echo "dark")
if [ "$_theme" = "light" ]; then
    # Tokyo Night Day — saturated colors that read well on light bg
    BLUE="\033[38;5;33m"
    GREEN="\033[38;5;28m"
    YELLOW="\033[38;5;130m"
    MAGENTA="\033[38;5;127m"
    CYAN="\033[38;5;30m"
    RED="\033[38;5;160m"
    GRAY="\033[38;5;102m"
else
    # Tokyo Night — pastel colors for dark backgrounds
    BLUE="\033[38;5;111m"
    GREEN="\033[38;5;114m"
    YELLOW="\033[38;5;215m"
    MAGENTA="\033[38;5;177m"
    CYAN="\033[38;5;80m"
    RED="\033[38;5;204m"
    GRAY="\033[38;5;243m"
fi
# NOTE: Theme is read at startup.  Toggle theme → restart monitor (prefix m m).

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
    [[ "$1" =~ ^[0-9]+$ ]] || { echo "??:??:??"; return; }
    local ms="$1"
    local secs=$(( ms / 1000 ))
    date -d "@${secs}" '+%H:%M:%S' 2>/dev/null || echo "??:??:??"
}

# ─── Format duration in ms to human-readable ─────────────────────
_fmt_duration() {
    [[ "$1" =~ ^[0-9]+$ ]] || { echo "?"; return; }
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
# Returns TSV: session_id  agent  model  time_created  msg_count  last_msg_time  finish  error_name  completed
# Only considers sessions from the current container lifecycle.
# Uses a single aggregation query (no correlated subqueries) for speed.
#
# Completion logic:  finish="stop" is written to the DB when the message
# row is first created, but the LLM may still be streaming.  The field
# $.time.completed is set only after generation finishes.  Therefore a
# session is truly done when  finish="stop" AND completed!="".
_query_subagents() {
    local startup_ts
    startup_ts=$(cat /tmp/.opencode-startup-ts 2>/dev/null || echo "0")
    [[ "$startup_ts" =~ ^[0-9]+$ ]] || startup_ts=0
    sqlite3 -separator $'\t' "$DB" "
        SELECT
            s.id,
            COALESCE(first_msg.agent, 'unknown') as agent,
            COALESCE(first_msg.model, '?') as model,
            s.time_created,
            COALESCE(agg.msg_count, 0) as msg_count,
            COALESCE(agg.last_msg_time, s.time_created) as last_msg_time,
            COALESCE(last_asst.finish, '') as finish,
            COALESCE(last_asst.error_name, '') as error_name,
            COALESCE(last_asst.completed, '') as completed
        FROM session s
        LEFT JOIN (
            SELECT
                m.session_id,
                json_extract(m.data, '$.agent') as agent,
                json_extract(m.data, '$.modelID') as model
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
        LEFT JOIN (
            SELECT
                m.session_id,
                json_extract(m.data, '$.finish') as finish,
                json_extract(m.data, '$.error.name') as error_name,
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
          AND s.time_created >= ${startup_ts}
        ORDER BY s.time_created ASC
    " 2>/dev/null
}

# ─── Query token usage for a completed session ───────────────────
# Returns TSV: total_input  total_output  total_cache_read
_query_tokens() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]] || return
    local sid="$1"
    sqlite3 -separator $'\t' "$DB" "
        SELECT
            COALESCE(SUM(json_extract(data, '$.tokens.input')), 0),
            COALESCE(SUM(json_extract(data, '$.tokens.output')), 0),
            COALESCE(SUM(json_extract(data, '$.tokens.cache.read')), 0)
        FROM message
        WHERE session_id = '${sid}'
          AND json_extract(data, '$.role') = 'assistant'
    " 2>/dev/null
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
# Args: sid  agent  tcreated  last_msg_time  error_name
_print_done() {
    local sid="$1" agent="$2" tcreated="$3" last_msg_time="$4" error_name="$5"
    local color
    color=$(_agent_color "$agent")
    [[ "$tcreated" =~ ^[0-9]+$ ]] || tcreated=0
    [[ "$last_msg_time" =~ ^[0-9]+$ ]] || last_msg_time="$tcreated"
    local duration=$(( last_msg_time - tcreated ))
    local dur_str
    dur_str=$(_fmt_duration "$duration")
    local ts
    ts=$(_fmt_time "$last_msg_time")
    # Determine finish status from error_name
    local status_icon status_label
    if [ "$error_name" = "MessageAbortedError" ]; then
        status_icon="✗"
        status_label="cancelled"
    elif [ "$error_name" = "(timeout)" ]; then
        status_icon="■"
        status_label="timeout"
    elif [ "$error_name" = "ProviderModelNotFoundError" ]; then
        status_icon="⚠"
        status_label="model not found"
    elif [ -n "$error_name" ]; then
        status_icon="⚠"
        status_label="error"
    else
        status_icon="■"
        status_label="done"
    fi
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
# Format: agent|model|time_created|status|msg_count|last_msg_time|finish|error_name|completed
# Note: sets global _s_* variables — must be called in main shell, not subshells.
_parse_session() {
    local entry="$1"
    _s_agent="" _s_model="" _s_tcreated="" _s_status="" _s_msg_count="" _s_last_msg="" _s_finish="" _s_error_name="" _s_completed=""
    IFS='|' read -r _s_agent _s_model _s_tcreated _s_status _s_msg_count _s_last_msg _s_finish _s_error_name _s_completed <<< "$entry"
}

# ─── Main monitor loop ────────────────────────────────────────────
main() {
    # Ensure TZ defaults to UTC if not set
    export TZ="${TZ:-UTC}"

    _print_header

    # ── Wait for DB readiness ────────────────────────────────────
    local db_ok=false
    for attempt in 1 2 3 4 5; do
        if sqlite3 "$DB" "SELECT COUNT(*) FROM session" >/dev/null 2>&1; then
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
    # key=session_id, value="agent|model|time_created|status|msg_count|last_msg_time|finish|error_name|completed"
    declare -A known_sessions

    # ── Seed: replay recent sessions, detect currently-active ones ─
    # Sessions from the last REPLAY_WINDOW_MS are shown.
    # A session is truly done when finish="stop" AND completed is non-empty
    # (meaning the LLM has finished generating), or when error_name is set.
    # Sessions with finish="stop" but completed="" are still streaming.
    local now_ms
    now_ms=$(date +%s%3N 2>/dev/null || echo "0")
    local replay_cutoff=$(( now_ms - REPLAY_WINDOW_MS ))

    local seed_data old_count=0 replay_count=0 active_count=0
    seed_data=$(_query_subagents)
    while IFS=$'\t' read -r sid agent model tcreated msg_count last_msg_time finish error_name completed; do
        [ -z "$sid" ] && continue

        # A session is done when: (finish="stop" AND completed is set) OR error_name is set
        local is_done=false
        if { [ "$finish" = "stop" ] && [ -n "$completed" ]; } || [ -n "$error_name" ]; then
            is_done=true
        fi

        if [ "$is_done" = true ] && [ "$tcreated" -lt "$replay_cutoff" ]; then
            # Old finished session — suppress silently
            known_sessions["$sid"]="${agent}|${model}|${tcreated}|done|${msg_count}|${last_msg_time}|${finish}|${error_name}|${completed}"
            old_count=$(( old_count + 1 ))

        elif [ "$is_done" = true ]; then
            # Recent finished session — replay as done
            known_sessions["$sid"]="${agent}|${model}|${tcreated}|done|${msg_count}|${last_msg_time}|${finish}|${error_name}|${completed}"
            replay_count=$(( replay_count + 1 ))
            _print_done "$sid" "$agent" "$tcreated" "$last_msg_time" "$error_name"

        else
            # Agent is still active: finish is empty, "tool-calls", or "stop" without completed
            known_sessions["$sid"]="${agent}|${model}|${tcreated}|active|${msg_count}|${last_msg_time}|${finish}|${error_name}|${completed}"
            active_count=$(( active_count + 1 ))
            local color
            color=$(_agent_color "$agent")
            local ts
            ts=$(_fmt_time "$tcreated")
            echo -e "  ${color}▶${RESET} ${BOLD}${agent}${RESET} ${DIM}active${RESET}  ${GRAY}${model}${RESET}  ${DIM}${ts}${RESET}"
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
    declare -A current_ids
    while true; do
        sleep "$POLL_INTERVAL"

        local new_data
        new_data=$(_query_subagents)

        # Build a set of current session IDs from the query
        current_ids=()

        now_ms=$(date +%s%3N 2>/dev/null || echo "0")

        while IFS=$'\t' read -r sid agent model tcreated msg_count last_msg_time finish error_name completed; do
            [ -z "$sid" ] && continue
            current_ids["$sid"]=1

            if [ -z "${known_sessions[$sid]+x}" ]; then
                # ── New session detected — print spawn event
                local color
                color=$(_agent_color "$agent")
                local ts
                ts=$(_fmt_time "$tcreated")
                echo -e "  ${color}▶${RESET} ${BOLD}${agent}${RESET} ${DIM}started${RESET}  ${GRAY}${model}${RESET}  ${DIM}${ts}${RESET}"
                known_sessions["$sid"]="${agent}|${model}|${tcreated}|active|${msg_count}|${last_msg_time}|${finish}|${error_name}|${completed}"

            elif [[ "${known_sessions[$sid]}" == *"|active|"* ]]; then
                # ── Known active session — check finish + completed fields
                if { [ "$finish" = "stop" ] && [ -n "$completed" ]; } || [ -n "$error_name" ]; then
                    # Truly done: finish="stop" with completed timestamp, or error
                    _print_done "$sid" "$agent" "$tcreated" "$last_msg_time" "$error_name"
                    known_sessions["$sid"]="${agent}|${model}|${tcreated}|done|${msg_count}|${last_msg_time}|${finish}|${error_name}|${completed}"
                else
                    # Safety net: no completion signal but idle too long
                    [[ "$last_msg_time" =~ ^[0-9]+$ ]] || last_msg_time=0
                    local idle_ms=$(( now_ms - last_msg_time ))
                    if [ "$idle_ms" -gt "$SAFETY_TIMEOUT_MS" ]; then
                        _print_done "$sid" "$agent" "$tcreated" "$last_msg_time" "(timeout)"
                        known_sessions["$sid"]="${agent}|${model}|${tcreated}|done|${msg_count}|${last_msg_time}|${finish}|${error_name}|${completed}"
                    else
                        # Still active — update tracking
                        known_sessions["$sid"]="${agent}|${model}|${tcreated}|active|${msg_count}|${last_msg_time}|${finish}|${error_name}|${completed}"
                    fi
                fi
            fi
        done <<< "$new_data"

        # ── Check for sessions that disappeared from DB while active
        for sid in "${!known_sessions[@]}"; do
            _parse_session "${known_sessions[$sid]}"
            [ "$_s_status" != "active" ] && continue

            if [ -z "${current_ids[$sid]+x}" ]; then
                _print_done "$sid" "$_s_agent" "$_s_tcreated" "$_s_last_msg" "$_s_error_name"
                known_sessions["$sid"]="${_s_agent}|${_s_model}|${_s_tcreated}|done|${_s_msg_count}|${_s_last_msg}|${_s_finish}|${_s_error_name}|${_s_completed}"
            fi
        done
    done
}

main "$@"
