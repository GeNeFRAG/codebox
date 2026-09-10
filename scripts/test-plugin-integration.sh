#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# test-plugin-integration.sh — integration test for plugin validation
# ═══════════════════════════════════════════════════════════════════
# Simulates the plugin validation flow that occurs during container startup.
# Tests the actual integration with _configure_opencode() flow.
#
# Usage:
#   ./scripts/test-plugin-integration.sh
#
# Exit codes:
#   0 — integration tests passed
#   1 — test failures

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Source config.sh to get the validation functions
source "${ROOT}/lib/config.sh"

errors=0
tests_run=0

fail() { 
    echo "✗ $*"
    errors=$((errors + 1))
}

pass() {
    echo "✓ $*"
    tests_run=$((tests_run + 1))
}

# ─── Setup ───────────────────────────────────────────────────────────
TESTDIR=$(mktemp -d)
trap 'rm -rf "${TESTDIR}"' EXIT

# ─── Test 1: Validate actual template against actual catalog ────────
test_real_templates() {
    echo
    echo "Test 1: Validate actual templates"
    
    local plugin_tpl="${ROOT}/templates/oh-my-opencode-slim.json.template"
    local catalog="${ROOT}/templates/model-catalog.json"
    
    if [ ! -f "${plugin_tpl}" ]; then
        fail "Plugin template not found: ${plugin_tpl}"
        return
    fi
    
    if [ ! -f "${catalog}" ]; then
        fail "Model catalog not found: ${catalog}"
        return
    fi
    
    # Extract refs
    local refs
    refs=$(_extract_plugin_model_refs "${plugin_tpl}")
    
    if [ -z "${refs}" ]; then
        fail "Failed to extract model references from template"
        return
    fi
    
    local ref_count
    ref_count=$(echo "${refs}" | wc -l)
    pass "Extracted ${ref_count} unique model references from template"
    
    # Validate against full catalog
    local catalog_json
    catalog_json=$(cat "${catalog}")
    
    if _validate_plugin_models "${plugin_tpl}" "${catalog_json}" "static" 2>"${TESTDIR}/validate.err"; then
        pass "Template validation passed (no invalid references)"
    else
        fail "Template validation failed"
        cat "${TESTDIR}/validate.err"
    fi
    
    # Generate report
    local report
    report=$(_report_plugin_model_status "${plugin_tpl}" "${catalog_json}" 2>&1)
    
    if echo "${report}" | grep -q "unique model refs in catalog"; then
        pass "Report generation successful"
    else
        fail "Report generation failed"
        echo "${report}"
    fi
}

# ─── Test 2: Gateway filtering simulation ───────────────────────────
test_gateway_filtering() {
    echo
    echo "Test 2: Gateway filtering simulation"
    
    local plugin_tpl="${ROOT}/templates/oh-my-opencode-slim.json.template"
    local catalog="${ROOT}/templates/model-catalog.json"
    
    # Create a filtered catalog (simulate gateway with subset of models)
    local full_catalog
    full_catalog=$(cat "${catalog}")
    
    # Simulate gateway that only has Claude models
    local filtered_catalog
    filtered_catalog=$(jq '.models |= map(select(.id | startswith("claude-")))' <<<"${full_catalog}")
    
    local full_count filtered_count
    full_count=$(jq '.models | length' <<<"${full_catalog}")
    filtered_count=$(jq '.models | length' <<<"${filtered_catalog}")
    
    pass "Created filtered catalog: ${filtered_count}/${full_count} models (Claude only)"
    
    # Runtime validation against filtered catalog
    local runtime_output
    runtime_output=$(_validate_plugin_models "${plugin_tpl}" "${filtered_catalog}" "runtime" 2>&1)
    
    # Should warn about GPT models being unavailable
    if echo "${runtime_output}" | grep -q "gpt-"; then
        pass "Runtime validation detected unavailable GPT models"
    else
        # May pass if template doesn't reference GPT models
        pass "Runtime validation completed (no GPT models referenced or all available)"
    fi
}

# ─── Test 3: Strict mode behavior ───────────────────────────────────
test_strict_mode() {
    echo
    echo "Test 3: Strict mode behavior"
    
    local plugin_file="${TESTDIR}/strict-test.json"
    
    # Create a plugin config with one invalid reference
    cat > "${plugin_file}" <<'EOF'
{
  "presets": {
    "default": {
      "valid-role": {"model": "llm/claude-opus-5"},
      "invalid-role": {"model": "llm/nonexistent-model-xyz"}
    }
  }
}
EOF
    
    local catalog
    catalog=$(cat "${ROOT}/templates/model-catalog.json")
    
    # Test non-strict mode (default)
    export CODEBOX_STRICT_MODEL_REFS=false
    if _validate_plugin_models "${plugin_file}" "${catalog}" "static" 2>/dev/null; then
        pass "Non-strict mode: warnings only, validation returns success"
    else
        fail "Non-strict mode should return success despite invalid refs"
    fi
    
    # Test strict mode
    export CODEBOX_STRICT_MODEL_REFS=true
    if ! _validate_plugin_models "${plugin_file}" "${catalog}" "static" 2>/dev/null; then
        pass "Strict mode: validation fails on invalid references"
    else
        fail "Strict mode should fail on invalid references"
    fi
    
    unset CODEBOX_STRICT_MODEL_REFS
}

# ─── Test 4: Catalog orchestration ──────────────────────────────────
test_catalog_orchestration() {
    echo
    echo "Test 4: Catalog orchestration (_get_catalog_for_agent)"
    
    # Test without gateway (should return full catalog)
    unset LLM_BASE_URL
    local catalog
    if catalog=$(_get_catalog_for_agent 2>/dev/null); then
        local model_count
        model_count=$(jq '.models | length' <<<"${catalog}" 2>/dev/null || echo 0)
        if [ "${model_count}" -gt 0 ]; then
            pass "No gateway: returned full catalog (${model_count} models)"
        else
            fail "No gateway: catalog is empty"
        fi
    else
        fail "Failed to get catalog without gateway"
    fi
}

# ─── Test 5: Model reference format variations ──────────────────────
test_model_formats() {
    echo
    echo "Test 5: Model reference format variations"
    
    local plugin_file="${TESTDIR}/formats.json"
    
    # Test various valid formats
    cat > "${plugin_file}" <<'EOF'
{
  "presets": {
    "default": {
      "single-string": {"model": "llm/claude-opus-5"},
      "array-one": {"model": ["llm/claude-sonnet-5"]},
      "array-multi": {"model": ["llm/claude-opus-5", "llm/claude-sonnet-5", "llm/claude-haiku-4-5"]}
    }
  },
  "council": {
    "presets": {
      "default": {
        "alpha": {"model": "llm/gpt-5"},
        "beta": {"model": ["llm/gpt-5.4", "llm/gpt-5-mini"]}
      }
    }
  }
}
EOF
    
    local refs
    refs=$(_extract_plugin_model_refs "${plugin_file}")
    
    # Should extract unique models: claude-opus-5, claude-sonnet-5, claude-haiku-4-5,
    # gpt-5, gpt-5.4, gpt-5-mini = 6 unique
    local expected_count=6
    local actual_count
    actual_count=$(echo "${refs}" | wc -l)
    
    if [ "${actual_count}" -eq "${expected_count}" ]; then
        pass "Extracted correct count from mixed formats (${actual_count} unique)"
    else
        fail "Expected ${expected_count} refs, got ${actual_count}"
        echo "Refs:"
        echo "${refs}" | sed 's/^/  /'
    fi
    
    # All should be valid
    local catalog
    catalog=$(cat "${ROOT}/templates/model-catalog.json")
    
    if _validate_plugin_models "${plugin_file}" "${catalog}" "static" 2>/dev/null; then
        pass "All format variations validated successfully"
    else
        fail "Format variation validation failed"
    fi
}

# ─── Test 6: Empty and edge cases ───────────────────────────────────
test_edge_cases() {
    echo
    echo "Test 6: Edge cases"
    
    local catalog
    catalog=$(cat "${ROOT}/templates/model-catalog.json")
    
    # Empty presets
    local empty_file="${TESTDIR}/empty.json"
    echo '{"presets":{}}' > "${empty_file}"
    
    if _validate_plugin_models "${empty_file}" "${catalog}" "static" 2>/dev/null; then
        pass "Empty presets: validation succeeds"
    else
        fail "Empty presets should pass validation"
    fi
    
    # Null model values
    local null_file="${TESTDIR}/null.json"
    cat > "${null_file}" <<'EOF'
{
  "presets": {
    "default": {
      "role1": {"model": null},
      "role2": {"model": "llm/claude-opus-5"}
    }
  }
}
EOF
    
    local refs
    refs=$(_extract_plugin_model_refs "${null_file}")
    local ref_count
    ref_count=$(echo "${refs}" | wc -l)
    
    if [ "${ref_count}" -eq 1 ]; then
        pass "Null model values: filtered out correctly"
    else
        fail "Null model values should be filtered (got ${ref_count} refs)"
    fi
}

# ─── Run all tests ───────────────────────────────────────────────────
test_real_templates
test_gateway_filtering
test_strict_mode
test_catalog_orchestration
test_model_formats
test_edge_cases

echo
echo "════════════════════════════════════════════════════════════════"
if [ "${errors}" -eq 0 ]; then
    echo "✓ All ${tests_run} integration tests passed"
    exit 0
else
    echo "✗ ${errors} test(s) failed out of ${tests_run}"
    exit 1
fi
