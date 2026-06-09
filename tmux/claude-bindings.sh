#!/bin/bash
# Claude Code tmux bindings — sourced by both tmux-wrapper and tui-wrapper.
# Intercepts wheel events at root level so they enter tmux copy mode
# (scrollback) instead of being forwarded to Claude Code's mouse handler.
tmux bind -T root WheelUpPane   if-shell -F "#{pane_in_mode}" "send-keys -X -N 3 scroll-up"   "copy-mode -e"
tmux bind -T root WheelDownPane if-shell -F "#{pane_in_mode}" "send-keys -X -N 3 scroll-down" ""
tmux bind C-r run-shell "kill -WINCH #{pane_pid} 2>/dev/null; sleep 0.05; kill -WINCH #{pane_pid} 2>/dev/null"
tmux set-hook -g client-resized  "run-shell -b 'kill -WINCH #{pane_pid} 2>/dev/null; sleep 0.05; kill -WINCH #{pane_pid} 2>/dev/null'"
tmux set-hook -g client-attached "run-shell -b 'sleep 0.2; kill -WINCH #{pane_pid} 2>/dev/null'"
