#!/bin/bash
# shell-pane-toggle.sh — Toggle a shell pane at the bottom of the current window.
# Bound to prefix m in tmux.conf.

PANE_ID=$(tmux list-panes -F '#{pane_id} #{pane_title}' | grep ' shell$' | head -1 | cut -d' ' -f1)

if [ -n "$PANE_ID" ]; then
    tmux kill-pane -t "$PANE_ID"
else
    NEW_PANE=$(tmux split-window -v -l '25%' -c /workspace -P -F '#{pane_id}' zsh)
    tmux select-pane -t "$NEW_PANE" -T shell
fi
