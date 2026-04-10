#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# agent-monitor-toggle.sh — Toggle agent monitor pane in tmux
# ═══════════════════════════════════════════════════════════════════
# Bound to Ctrl-Space m and Option-m in tmux.conf.
# Toggles a 25%-height pane at the bottom running agent-monitor.sh.
# If the pane already exists, kills it; otherwise creates it.

MONITOR_TITLE="agent-monitor"

# Find an existing monitor pane by title
pane_id=$(tmux list-panes -a -F '#{pane_id} #{pane_title}' 2>/dev/null \
    | grep "${MONITOR_TITLE}" \
    | head -1 \
    | awk '{print $1}')

if [ -n "$pane_id" ]; then
    # Monitor pane exists — kill it
    tmux kill-pane -t "$pane_id" 2>/dev/null
else
    # No monitor pane — create one at the bottom (25% height)
    tmux split-window -v -l '25%' -d \
        "printf '\\033]2;${MONITOR_TITLE}\\033\\\\'; bash /opt/opencode/monitor/agent-monitor.sh"
fi
