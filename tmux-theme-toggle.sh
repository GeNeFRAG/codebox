#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# tmux-theme-toggle.sh — Toggle between dark and light tmux themes
# ═══════════════════════════════════════════════════════════════════
# Bound to Ctrl-Space t and Option-t in tmux.conf.
#
# What happens when you press the key:
#   1. Outer terminal (xterm.js) bg/fg changes via OSC 10/11/12
#   2. tmux chrome updates instantly (status bar, borders, pane bg)
#   3. COLORFGBG env var + theme flag file updated
#   4. opencode TUI pane is respawned so lipgloss re-detects background
#   5. Status bar script caches are cleared for immediate color update

THEME_DIR="/opt/opencode"

# Read current theme from tmux (defaults to "dark" if not set)
current=$(tmux show-option -gqv @theme 2>/dev/null)
current="${current:-dark}"

if [ "$current" = "dark" ]; then
    next="light"
    osc_bg="#e1e2e7"
    osc_fg="#3760bf"
    osc_cursor="#2e7de9"
else
    next="dark"
    osc_bg="#1a1b26"
    osc_fg="#c0caf5"
    osc_cursor="#c0caf5"
fi

# ─── 1. Update outer terminal (xterm.js) colors ──────────────────
tmux list-clients -F '#{client_tty}' 2>/dev/null | while IFS= read -r tty; do
    [ -w "$tty" ] || continue
    printf '\e]10;%s\a' "$osc_fg" > "$tty"
    printf '\e]11;%s\a' "$osc_bg" > "$tty"
    printf '\e]12;%s\a' "$osc_cursor" > "$tty"
done

# ─── 2. Source the new theme (status bar, borders, pane bg, COLORFGBG)
tmux source-file "${THEME_DIR}/tmux-theme-${next}.conf"

# ─── 3. Write theme flag + clear caches ──────────────────────────
echo "$next" > /tmp/.tmux-theme
rm -f /tmp/.session-status-cache /tmp/.agent-status-cache

# ─── 4. Respawn the opencode TUI pane ────────────────────────────
# respawn-pane -k kills the running process AND restarts the pane's
# original command in one atomic operation.  The wrapper script reads
# /tmp/.tmux-theme → sets COLORFGBG → exec opencode, so lipgloss
# detects the new background on startup.
# Target: window 1, pane 1 (the opencode TUI pane).
tmux respawn-pane -k -t opencode:1.1 2>/dev/null

# Brief visual confirmation
tmux display-message "Theme: ${next}"
