#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# verify-mcp-sync.sh — ensure all MCP templates define the same servers
# ═══════════════════════════════════════════════════════════════════
# Run this after editing any MCP template to catch drift.
# Exit 0 = all templates in sync; Exit 1 = mismatch found.

set -euo pipefail

TEMPLATES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/templates}"

extract_servers() {
    # Extract server names by finding keys whose object contains "type":
    # Match lines like '    "server_name": {' (indented exactly 4 spaces for
    # Claude Code or 6 spaces for OpenCode nested under mcp.mcpServers)
    grep -E '^\s{4,8}"[a-z]' "$1" | grep -B0 -A0 "" | \
        sed -n 's/^[[:space:]]*"\([a-z][a-z0-9_-]*\)"[[:space:]]*:.*/\1/p' | \
        grep -v -E '^(type|command|args|env|environment|enabled|url)$' | sort
}

opencode_servers=$(extract_servers "${TEMPLATES_DIR}/opencode.json.template")
claude_servers=$(extract_servers "${TEMPLATES_DIR}/claude-code.mcp.json.template")

errors=0

# OpenCode may have extra servers (it wraps more config), but should be a superset
missing=$(comm -23 <(echo "$claude_servers") <(echo "$opencode_servers"))
if [ -n "$missing" ]; then
    echo "✗ Servers in Claude Code template but missing from OpenCode:"
    echo "$missing"
    errors=$((errors + 1))
fi

if [ "$errors" -eq 0 ]; then
    echo "✓ All MCP templates are in sync ($(echo "$claude_servers" | wc -l) servers)"
    exit 0
else
    exit 1
fi
