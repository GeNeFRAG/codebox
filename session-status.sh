#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# session-status.sh — tmux status-left: git branch + model + context
# ═══════════════════════════════════════════════════════════════════
# Called by tmux status-left every status-interval seconds (tmux mode only).
# Outputs: " opencode │ main │ claude-opus-4-6 │ 94.7k ctx"
#
# Model comes from OPENCODE_MODEL env var (always correct).
# Context tokens are scraped from the TUI pane's right sidebar
# (row 4, last 42 chars).  Shows nothing for tokens until the
# TUI is actually rendered.

export TZ="${TZ:-UTC}"

# ─── Theme colors (dark/light) ────────────────────────────────────
_theme=$(cat /tmp/.tmux-theme 2>/dev/null || echo "dark")
if [ "$_theme" = "light" ]; then
    _sep="#8990b3"; _label="#2e7de9"; _branch="#587539"
    _model="#7847bd"; _ctx="#8c6c3e"
else
    _sep="#565f89"; _label="#7aa2f7"; _branch="#9ece6a"
    _model="#bb9af7"; _ctx="#e0af68"
fi

# ─── Git branch ───────────────────────────────────────────────────
branch=$(git -C /workspace branch --show-current 2>/dev/null)
if [ -z "$branch" ] && git -C /workspace rev-parse --is-inside-work-tree &>/dev/null; then
    branch=$(git -C /workspace rev-parse --short HEAD 2>/dev/null)
fi

# ─── Model: always from config ───────────────────────────────────
model="${OPENCODE_MODEL:-?}"
model="${model#llm/}"
model="${model#github-copilot/}"
model="${model#openrouter/}"
model="${model#anthropic/}"
model="${model#google/}"

# ─── Context tokens: scrape from TUI right sidebar ───────────────
# Row 4 of the TUI pane always shows "NNN,NNN tokens" in the last
# ~42 characters (the right sidebar).  Empty until TUI is rendered.
_row4=$(tmux capture-pane -t opencode:1.1 -p -S 4 -E 4 2>/dev/null)
ctx=$(echo "${_row4: -42}" | grep -oE '[0-9,]+ tokens' | tr -cd '0-9')

# ─── Format context tokens ───────────────────────────────────────
ctx_segment=""
if [ -n "$ctx" ] && [ "$ctx" -gt 0 ] 2>/dev/null; then
    if [ "$ctx" -ge 1000000 ]; then
        ctx_str="$(( ctx / 1000000 )).$(( (ctx % 1000000) / 100000 ))M"
    elif [ "$ctx" -ge 1000 ]; then
        ctx_str="$(( ctx / 1000 )).$(( (ctx % 1000) / 100 ))k"
    else
        ctx_str="${ctx}"
    fi
    ctx_segment="#[fg=${_sep}]│#[fg=${_ctx}] ${ctx_str} ctx "
fi

# ─── Output ───────────────────────────────────────────────────────
branch_segment=""
if [ -n "$branch" ]; then
    branch_segment="#[fg=${_sep}]│#[fg=${_branch}] ${branch} "
fi
echo "#[fg=${_label},bold] opencode ${branch_segment}#[fg=${_sep}]│#[fg=${_model}] ${model:-?} ${ctx_segment}"
