#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# theme-colors.sh — shared theme palette for tmux status bar scripts
# ═══════════════════════════════════════════════════════════════════
# Source this to get $_theme and tmux hex color variables.

export TZ="${TZ:-UTC}"

_theme=$(cat /tmp/.tmux-theme 2>/dev/null || echo "dark")
if [ "$_theme" = "light" ]; then
    _sep="#8990b3"; _label="#2e7de9"; _branch="#587539"
    _model="#7847bd"; _ctx="#8c6c3e"
    _count="#8c6c3e"; _name="#3760bf"
else
    _sep="#565f89"; _label="#7aa2f7"; _branch="#9ece6a"
    _model="#bb9af7"; _ctx="#e0af68"
    _count="#e0af68"; _name="#a9b1d6"
fi

_fmt_tokens() {
    local n="$1"
    if [ "$n" -ge 1000000 ]; then
        echo "$(( n / 1000000 )).$(( (n % 1000000) / 100000 ))M"
    elif [ "$n" -ge 1000 ]; then
        echo "$(( n / 1000 )).$(( (n % 1000) / 100 ))k"
    else
        echo "${n}"
    fi
}
