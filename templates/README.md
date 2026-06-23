# templates/

Config templates substituted at container startup by `lib/config.sh` using `envsubst`. Each template is read from `/opt/opencode/templates/` inside the container and written to the agent's runtime config location.

| File | Written to | Used by |
|------|-----------|---------|
| `opencode.json.template` | `/root/.config/opencode/opencode.json` | OpenCode |
| `claude-code.mcp.json.template` | `/opt/opencode/templates/claude-code-mcp.json` | Claude Code |
| `oh-my-opencode-slim.json.template` | `/root/.config/opencode/oh-my-opencode-slim.json` | OpenCode (agent roles) |

## How substitution works

`lib/config.sh` calls `envsubst` with an explicit variable allowlist (e.g. `${LLM_API_KEY} ${GRAFANA_URL} ...`). Only variables in that list are substituted — dollar signs in other parts of the JSON are left as-is. If you add a new `$MY_VAR` to a template, you must also add `${MY_VAR}` to the `envsubst` call in the relevant config function in `lib/config.sh`.

## Adding a new env var

1. Add `$MY_VAR` to the template where needed.
2. Add `${MY_VAR}` to the `envsubst` variable list in `lib/config.sh` (function `_generate_config` or `_generate_claude_code_config`).
3. Document `MY_VAR` in `.env.example`.
4. `./codebox.sh restart codebox` to apply (templates are bind-mounted, no rebuild needed).

See **Recipe: Add an MCP Server** in `AGENTS.md` for the full MCP server workflow.
