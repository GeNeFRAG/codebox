#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# verify-model-catalog.sh — validate templates/model-catalog.json
# ═══════════════════════════════════════════════════════════════════
# The catalog is the single source of truth for model limits/pricing and
# is injected into BOTH agents by lib/config.sh:
#   - opencode → .provider.llm.models
#   - pi       → ~/.pi/agent/models.json
#
# Checks performed:
#   1. Catalog is valid JSON with the required per-model fields.
#   2. The snapshot in opencode.json.template still matches the catalog
#      (the template is only a readable fallback; drift is a bug).
#   3. Every Claude model is pinned to anthropic-messages. On the OpenAI
#      route this gateway turns reasoning_effort into a thinking token
#      budget: signatures come back as the placeholder "reasoning_content",
#      usage.reasoning stays 0, and max_tokens <= budget is a hard 400.
#      (Pi-only: opencode reads just limits/pricing from the catalog.)
#   4. Non-anthropic-messages Claude models declare a cacheControlFormat
#      escape hatch, else prompt caching is silently off.
#   5. Optional: with LLM_BASE_URL + LLM_API_KEY set, cross-check every
#      catalog id, context window and output cap against the live gateway.
#
# Exit 0 = catalog consistent; Exit 1 = problem found.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="${ROOT}/templates/model-catalog.json"
OC_TEMPLATE="${ROOT}/templates/opencode.json.template"
errors=0

fail() { echo "✗ $*"; errors=$((errors + 1)); }

command -v jq >/dev/null || { echo "✗ jq is required"; exit 1; }
[ -s "${CATALOG}" ] || { echo "✗ missing or empty: ${CATALOG}"; exit 1; }

# ─── 1. Schema ──────────────────────────────────────────────────────
if ! jq -e . "${CATALOG}" >/dev/null 2>&1; then
    echo "✗ ${CATALOG} is not valid JSON"
    exit 1
fi

missing=$(jq -r '
    .models[]
    | select((.id|type != "string") or (.name|type != "string")
             or (.context|type != "number") or (.output|type != "number")
             or (.reasoning|type != "boolean")
             or (.cost.input|type != "number") or (.cost.output|type != "number")
             or (.cost.cacheRead|type != "number"))
    | .id // "(no id)"' "${CATALOG}")
[ -n "${missing}" ] && fail "models with missing/invalid required fields:"$'\n'"${missing}"

dupes=$(jq -r '[.models[].id] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "${CATALOG}")
[ -n "${dupes}" ] && fail "duplicate model ids:"$'\n'"${dupes}"

# ─── 2. opencode.json.template snapshot must match the catalog ──────
if [ -s "${OC_TEMPLATE}" ]; then
    from_catalog=$(jq -S '
        [ .models[] | {key: .id, value: {
              name: .name,
              cost: ({input: .cost.input, output: .cost.output, cache_read: .cost.cacheRead}
                     + (if .cost.cacheWrite then {cache_write: .cost.cacheWrite} else {} end)),
              limit: {context: .context, output: .output}
          }} ] | from_entries' "${CATALOG}")
    from_template=$(jq -S '.provider.llm.models' "${OC_TEMPLATE}" 2>/dev/null)
    if [ "${from_catalog}" != "${from_template}" ]; then
        fail "opencode.json.template snapshot has drifted from model-catalog.json"
        diff <(echo "${from_template}") <(echo "${from_catalog}") \
            | sed 's/^/    /' | head -40
        echo "    → the catalog wins at runtime; re-sync the template snapshot"
    fi
fi

# ─── 3+4. Gateway-specific routing invariants ───────────────────────
bad_api=$(jq -r '.models[] | select((.id|startswith("claude-")) and .api != "anthropic-messages") | .id' "${CATALOG}")
if [ -n "${bad_api}" ]; then
    no_cache=$(jq -r '.models[]
        | select((.id|startswith("claude-")) and .api != "anthropic-messages")
        | select(.compat.cacheControlFormat != "anthropic") | .id' "${CATALOG}")
    fail "Claude models not pinned to anthropic-messages (placeholder thinking signatures, unaccounted reasoning tokens, max_tokens/budget 400s):"$'\n'"${bad_api}"
    [ -n "${no_cache}" ] && fail "…and without compat.cacheControlFormat=anthropic, prompt caching is off too:"$'\n'"${no_cache}"
fi

# ─── 5. Optional live gateway cross-check ───────────────────────────
if [ -n "${LLM_BASE_URL:-}" ] && [ -n "${LLM_API_KEY:-}" ]; then
    live=$(curl -sf --max-time 15 -H "Authorization: Bearer ${LLM_API_KEY}" \
           "${LLM_BASE_URL}/v1/models" 2>/dev/null)
    if [ -n "${live}" ] && jq -e .data >/dev/null 2>&1 <<<"${live}"; then
        while IFS=$'\t' read -r id ctx out; do
            entry=$(jq -c --arg id "${id}" '.data[] | select(.id == $id)' <<<"${live}")
            if [ -z "${entry}" ]; then
                fail "catalog model not offered by gateway: ${id}"
                continue
            fi
            l_ctx=$(jq -r '.max_input_tokens // empty' <<<"${entry}")
            l_out=$(jq -r '.max_output_tokens // empty' <<<"${entry}")
            [ -n "${l_ctx}" ] && [ "${l_ctx}" != "${ctx}" ] && \
                fail "${id}: context ${ctx} in catalog, gateway reports ${l_ctx}"
            [ -n "${l_out}" ] && [ "${l_out}" != "${out}" ] && \
                fail "${id}: max output ${out} in catalog, gateway reports ${l_out}"
        done < <(jq -r '.models[] | "\(.id)\t\(.context)\t\(.output)"' "${CATALOG}")
        echo "  → cross-checked against ${LLM_BASE_URL}"
    else
        echo "  → gateway unreachable; skipped live cross-check"
    fi
else
    echo "  → LLM_BASE_URL/LLM_API_KEY unset; skipped live cross-check"
fi

if [ "${errors}" -eq 0 ]; then
    echo "✓ Model catalog consistent ($(jq '.models | length' "${CATALOG}") models)"
    exit 0
fi
exit 1
