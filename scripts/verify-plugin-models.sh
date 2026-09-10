#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# verify-plugin-models.sh — validate oh-my-opencode-slim model refs
# ═══════════════════════════════════════════════════════════════════
# Validates that model references in templates/oh-my-opencode-slim.json.template
# match entries in templates/model-catalog.json.
#
# This is a static check that runs against the template file directly,
# before any gateway discovery or filtering. It catches typos and references
# to nonexistent models.
#
# Runtime validation (checking against discovered gateway models) happens
# automatically during container startup in lib/config.sh.
#
# Exit codes:
#   0 — all model references are valid
#   1 — invalid references found or script error

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="${ROOT}/templates/model-catalog.json"
PLUGIN_TPL="${ROOT}/templates/oh-my-opencode-slim.json.template"

errors=0

fail() { echo "✗ $*"; errors=$((errors + 1)); }

command -v jq >/dev/null || { echo "✗ jq is required"; exit 1; }
[ -s "${CATALOG}" ] || { echo "✗ missing or empty: ${CATALOG}"; exit 1; }
[ -s "${PLUGIN_TPL}" ] || { echo "✗ missing or empty: ${PLUGIN_TPL}"; exit 1; }

# ─── Extract model references from plugin template ──────────────────
# Returns newline-separated list of unique model IDs (strips "llm/" prefix)
extract_refs() {
    jq -r '
        ((.presets.default // {}) | to_entries[] | .value.model),
        ((.council.presets.default // {}) | to_entries[] | .value.model)
        | if type == "array" then .[] else . end
        | select(. != null and . != "")
        | sub("^llm/"; "")' "${PLUGIN_TPL}" 2>/dev/null | sort -u
}

# ─── Validate references against catalog ────────────────────────────
echo "→ Validating oh-my-opencode-slim model references..."

refs=$(extract_refs)
if [ -z "${refs}" ]; then
    echo "  ⚠ No model references found in ${PLUGIN_TPL}"
    exit 0
fi

# Get valid model IDs from catalog
valid_ids=$(jq -r '.models[].id' "${CATALOG}" 2>/dev/null | sort -u)
if [ -z "${valid_ids}" ]; then
    fail "Failed to extract model IDs from catalog"
    exit 1
fi

# Find invalid references
invalid_refs=$(comm -23 <(echo "${refs}") <(echo "${valid_ids}"))

if [ -n "${invalid_refs}" ]; then
    fail "Plugin template references models not in catalog:"
    echo "${invalid_refs}" | sed 's/^/    /'
    echo
    echo "  These models do not exist in templates/model-catalog.json."
    echo "  Either add them to the catalog or remove them from the plugin template."
    echo
fi

# Report statistics
total=$(echo "${refs}" | wc -l)
valid=$(comm -12 <(echo "${refs}") <(echo "${valid_ids}") | wc -l)
invalid=$(comm -23 <(echo "${refs}") <(echo "${valid_ids}") | wc -l)

echo "  → Total unique model references: ${total}"
echo "  → Valid (in catalog): ${valid}"
echo "  → Invalid (not in catalog): ${invalid}"

if [ "${invalid}" -gt 0 ]; then
    echo
    echo "  Models referenced in plugin template:"
    echo "${refs}" | sed 's/^/    /'
    echo
    echo "  Valid catalog models:"
    echo "${valid_ids}" | sed 's/^/    /'
fi

if [ "${errors}" -eq 0 ]; then
    echo "✓ All oh-my-opencode-slim model references are valid"
    exit 0
fi
exit 1
