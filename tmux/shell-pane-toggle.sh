#!/bin/bash
# shell-pane-toggle.sh — Toggle a shell pane at the bottom of the current window.
# Bound to Option-m in tmux.conf.
# Uses @shell_pane user option for identification (immune to zsh title overrides).

PANE_ID=$(tmux list-panes -F '#{pane_id} #{@shell_pane}' | grep ' 1$' | head -1 | cut -d' ' -f1)

if [ -n "$PANE_ID" ]; then
    tmux kill-pane -t "$PANE_ID"
else
    NEW_PANE=$(tmux split-window -v -l '25%' -c /workspace -P -F '#{pane_id}' zsh)
    tmux set-option -p -t "$NEW_PANE" @shell_pane 1
    tmux select-pane -t "$NEW_PANE" -T shell
fi
