#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# session-status-claude.sh — tmux status-left for Claude Code mode
# ═══════════════════════════════════════════════════════════════════
# Simplified status bar: " claude-code │ main "
# No model display (Claude Code manages its own model selection).
# No context token scraping (Claude Code uses different TUI layout).

export TZ="${TZ:-UTC}"

# ─── Theme colors (dark/light) ────────────────────────────────────
_theme=$(cat /tmp/.tmux-theme 2>/dev/null || echo "dark")
if [ "$_theme" = "light" ]; then
    _sep="#8990b3"; _label="#2e7de9"; _branch="#587539"
else
    _sep="#565f89"; _label="#7aa2f7"; _branch="#9ece6a"
fi

# ─── Git branch ───────────────────────────────────────────────────
branch=$(git -C /workspace branch --show-current 2>/dev/null)
if [ -z "$branch" ] && git -C /workspace rev-parse --is-inside-work-tree &>/dev/null; then
    branch=$(git -C /workspace rev-parse --short HEAD 2>/dev/null)
fi

# ─── Output ───────────────────────────────────────────────────────
branch_segment=""
if [ -n "$branch" ]; then
    branch_segment="#[fg=${_sep}]│#[fg=${_branch}] ${branch} "
fi
echo "#[fg=${_label},bold] claude-code ${branch_segment}"
