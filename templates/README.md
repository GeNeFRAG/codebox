# templates/

Config templates substituted at container startup by `lib/config.sh` using `envsubst`. Each template is read from `/opt/opencode/templates/` inside the container and written to the agent's runtime config location.

| File | Written to | Used by |
|------|-----------|---------|
| `opencode.json.template` | `/root/.config/opencode/opencode.json` | OpenCode |
| `mcp-servers/*.json` | `/root/.claude/claude-code-mcp.json` | Claude Code (MCP servers) |
| `oh-my-opencode-slim.json.template` | `/root/.config/opencode/oh-my-opencode-slim.json` | OpenCode (agent roles) |

`mcp-servers/` is the odd one out: instead of one `envsubst` pass over a whole
template, `_generate_claude_code_mcp_config()` walks its `all_servers` list, skips
anything disabled via `CODEBOX_MCP_<NAME>`, runs each remaining part through
`envsubst`, and `jq`-merges the results into a single file.

> `claude-code.mcp.json.template` is **not** substituted at startup and is not
> written anywhere. It is the reference manifest `scripts/verify-mcp-sync.sh` diffs
> against `mcp-servers/` and `opencode.json.template` to catch a server added to one
> agent but not the other. Keep it in sync when adding a server.

## How substitution works

`lib/config.sh` calls `envsubst` with an explicit variable allowlist (e.g. `${LLM_API_KEY} ${GRAFANA_URL} ...`). Only variables in that list are substituted — dollar signs in other parts of the JSON are left as-is. If you add a new `$MY_VAR` to a template, you must also add `${MY_VAR}` to the `envsubst` call in the relevant config function in `lib/config.sh`.

## Adding a new env var

1. Add `$MY_VAR` to the template where needed.
2. Add `${MY_VAR}` to the `envsubst` variable list in `lib/config.sh` (function `_generate_config` or `_generate_claude_code_config`).
3. Document `MY_VAR` in `.env.example`.
4. `./codebox.sh restart codebox` to apply (templates are bind-mounted, no rebuild needed).

See **Recipe: Add an MCP Server** in `AGENTS.md` for the full MCP server workflow.
