#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# session-status.sh — tmux status-left: " codebox │ main "
# ═══════════════════════════════════════════════════════════════════

source /opt/opencode/tmux/theme-colors.sh

# ─── Git branch ───────────────────────────────────────────────────
branch=$(git -C /workspace branch --show-current 2>/dev/null)
if [ -z "$branch" ] && git -C /workspace rev-parse --is-inside-work-tree &>/dev/null; then
    branch=$(git -C /workspace rev-parse --short HEAD 2>/dev/null)
fi

branch_segment=""
if [ -n "$branch" ]; then
    branch_segment="#[fg=${_sep}]│#[fg=${_branch}] ${branch} "
fi

echo "#[fg=${_label},bold] codebox ${branch_segment}"
