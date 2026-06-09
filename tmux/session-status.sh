#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# session-status.sh — tmux status-left: git branch + model + context
# ═══════════════════════════════════════════════════════════════════
# Called by tmux status-left every status-interval seconds.
# For OpenCode: " codebox │ main │ claude-opus-4-6 │ 94.7k ctx"
# For Claude Code: " codebox │ main " (no model/context segments)

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

# ─── Claude Code: branch only ────────────────────────────────────
if [ "${CODEBOX_APP:-opencode}" = "claude-code" ]; then
    echo "#[fg=${_label},bold] codebox ${branch_segment}"
    exit 0
fi

# ─── OpenCode: model + context tokens ────────────────────────────
model="${OPENCODE_MODEL:-?}"
model="${model#llm/}"
model="${model#github-copilot/}"
model="${model#openrouter/}"
model="${model#anthropic/}"
model="${model#google/}"

_row4=$(tmux capture-pane -t codebox:1.1 -p -S 4 -E 4 2>/dev/null)
ctx=$(echo "${_row4: -42}" | grep -oE '[0-9,]+ tokens' | tr -cd '0-9')

ctx_segment=""
if [ -n "$ctx" ] && [ "$ctx" -gt 0 ] 2>/dev/null; then
    ctx_segment="#[fg=${_sep}]│#[fg=${_ctx}] $(_fmt_tokens "$ctx") ctx "
fi

echo "#[fg=${_label},bold] codebox ${branch_segment}#[fg=${_sep}]│#[fg=${_model}] ${model:-?} ${ctx_segment}"
