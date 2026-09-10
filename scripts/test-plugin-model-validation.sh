#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# test-plugin-model-validation.sh — test oh-my-opencode-slim validation
# ═══════════════════════════════════════════════════════════════════
# Tests the model reference validation functions in lib/config.sh.
#
# Usage:
#   ./scripts/test-plugin-model-validation.sh
#
# Exit codes:
#   0 — all tests passed
#   1 — test failures

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

# Sample catalog with 3 models
CATALOG_JSON='{
  "models": [
    {"id": "model-a", "name": "Model A", "context": 10000, "output": 4096, "reasoning": false, "vision": false, "cost": {"input": 1, "output": 2, "cacheRead": 0.1}},
    {"id": "model-b", "name": "Model B", "context": 20000, "output": 8192, "reasoning": true, "vision": true, "cost": {"input": 2, "output": 4, "cacheRead": 0.2}},
    {"id": "model-c", "name": "Model C", "context": 30000, "output": 16384, "reasoning": true, "vision": false, "cost": {"input": 3, "output": 6, "cacheRead": 0.3}}
  ]
}'

# ─── Test 1: Extract model references ───────────────────────────────
test_extract_refs() {
    echo
    echo "Test 1: Extract model references from plugin config"
    
    local plugin_file="${TESTDIR}/plugin.json"
    cat > "${plugin_file}" <<'EOF'
{
  "presets": {
    "default": {
      "role1": {"model": "llm/model-a"},
      "role2": {"model": ["llm/model-b", "llm/model-c"]},
      "role3": {"model": "llm/model-d"}
    }
  },
  "council": {
    "presets": {
      "default": {
        "alpha": {"model": "llm/model-x"},
        "beta": {"model": ["llm/model-y", "llm/model-z"]}
      }
    }
  }
}
EOF
    
    local refs
    refs=$(_extract_plugin_model_refs "${plugin_file}")
    
    # Should extract unique model IDs without llm/ prefix
    local expected="model-a
model-b
model-c
model-d
model-x
model-y
model-z"
    
    if [ "${refs}" = "${expected}" ]; then
        pass "Extracted correct model references"
    else
        fail "Model reference extraction failed"
        echo "  Expected:"
        echo "${expected}" | sed 's/^/    /'
        echo "  Got:"
        echo "${refs}" | sed 's/^/    /'
    fi
}

# ─── Test 2: Valid plugin config ────────────────────────────────────
test_valid_config() {
    echo
    echo "Test 2: Validate plugin config with all valid references"
    
    local plugin_file="${TESTDIR}/valid-plugin.json"
    cat > "${plugin_file}" <<'EOF'
{
  "presets": {
    "default": {
      "role1": {"model": "llm/model-a"},
      "role2": {"model": ["llm/model-b", "llm/model-c"]}
    }
  }
}
EOF
    
    if _validate_plugin_models "${plugin_file}" "${CATALOG_JSON}" "static" 2>/dev/null; then
        pass "Valid plugin config accepted"
    else
        fail "Valid plugin config rejected"
    fi
}

# ─── Test 3: Invalid plugin config ──────────────────────────────────
test_invalid_config() {
    echo
    echo "Test 3: Validate plugin config with invalid references"
    
    local plugin_file="${TESTDIR}/invalid-plugin.json"
    cat > "${plugin_file}" <<'EOF'
{
  "presets": {
    "default": {
      "role1": {"model": "llm/model-a"},
      "role2": {"model": ["llm/nonexistent", "llm/model-b"]},
      "role3": {"model": "llm/also-missing"}
    }
  }
}
EOF
    
    # Should fail validation but not exit (returns 0 in non-strict mode)
    local output
    output=$(_validate_plugin_models "${plugin_file}" "${CATALOG_JSON}" "static" 2>&1)
    
    if echo "${output}" | grep -q "nonexistent"; then
        pass "Invalid reference 'nonexistent' detected"
    else
        fail "Invalid reference 'nonexistent' not detected"
    fi
    
    if echo "${output}" | grep -q "also-missing"; then
        pass "Invalid reference 'also-missing' detected"
    else
        fail "Invalid reference 'also-missing' not detected"
    fi
    
    # model-a and model-b should not be reported as invalid
    if ! echo "${output}" | grep -q "model-a"; then
        pass "Valid reference 'model-a' not flagged"
    else
        fail "Valid reference 'model-a' incorrectly flagged"
    fi
}

# ─── Test 4: Strict mode enforcement ────────────────────────────────
test_strict_mode() {
    echo
    echo "Test 4: Strict mode enforcement"
    
    local plugin_file="${TESTDIR}/strict-plugin.json"
    cat > "${plugin_file}" <<'EOF'
{
  "presets": {
    "default": {
      "role1": {"model": "llm/model-a"},
      "role2": {"model": "llm/invalid-model"}
    }
  }
}
EOF
    
    # Non-strict mode: should warn but return 0
    export CODEBOX_STRICT_MODEL_REFS=false
    if _validate_plugin_models "${plugin_file}" "${CATALOG_JSON}" "static" 2>/dev/null; then
        pass "Non-strict mode allows invalid references with warning"
    else
        fail "Non-strict mode incorrectly rejected config"
    fi
    
    # Strict mode: should fail and return 1
    export CODEBOX_STRICT_MODEL_REFS=true
    if ! _validate_plugin_models "${plugin_file}" "${CATALOG_JSON}" "static" 2>/dev/null; then
        pass "Strict mode rejects invalid references"
    else
        fail "Strict mode should have rejected invalid references"
    fi
    
    unset CODEBOX_STRICT_MODEL_REFS
}

# ─── Test 5: Report generation ──────────────────────────────────────
test_report() {
    echo
    echo "Test 5: Diagnostics report generation"
    
    local plugin_file="${TESTDIR}/report-plugin.json"
    cat > "${plugin_file}" <<'EOF'
{
  "presets": {
    "default": {
      "role1": {"model": ["llm/model-a", "llm/model-b"]},
      "role2": {"model": "llm/model-c"},
      "role3": {"model": "llm/invalid"}
    }
  }
}
EOF
    
    local output
    output=$(_report_plugin_model_status "${plugin_file}" "${CATALOG_JSON}" 2>&1)
    
    if echo "${output}" | grep -q "3/4 unique model refs in catalog"; then
        pass "Report shows correct valid/total count"
    else
        fail "Report count incorrect"
        echo "  Output: ${output}"
    fi
    
    if echo "${output}" | grep -q "invalid"; then
        pass "Report lists invalid model"
    else
        fail "Report should list invalid model"
    fi
}

# ─── Test 6: Empty config handling ──────────────────────────────────
test_empty_config() {
    echo
    echo "Test 6: Empty config handling"
    
    local plugin_file="${TESTDIR}/empty-plugin.json"
    cat > "${plugin_file}" <<'EOF'
{
  "presets": {}
}
EOF
    
    if _validate_plugin_models "${plugin_file}" "${CATALOG_JSON}" "static" 2>/dev/null; then
        pass "Empty config handled correctly"
    else
        fail "Empty config should not fail validation"
    fi
}

# ─── Test 7: Phase labeling ─────────────────────────────────────────
test_phase_labels() {
    echo
    echo "Test 7: Phase-specific error messages"
    
    local plugin_file="${TESTDIR}/phase-plugin.json"
    cat > "${plugin_file}" <<'EOF'
{
  "presets": {
    "default": {
      "role1": {"model": "llm/invalid"}
    }
  }
}
EOF
    
    local static_output runtime_output
    static_output=$(_validate_plugin_models "${plugin_file}" "${CATALOG_JSON}" "static" 2>&1)
    runtime_output=$(_validate_plugin_models "${plugin_file}" "${CATALOG_JSON}" "runtime" 2>&1)
    
    if echo "${static_output}" | grep -q "static catalog"; then
        pass "Static phase uses correct message"
    else
        fail "Static phase message incorrect"
    fi
    
    if echo "${runtime_output}" | grep -q "runtime catalog"; then
        pass "Runtime phase uses correct message"
    else
        fail "Runtime phase message incorrect"
    fi
    
    if echo "${runtime_output}" | grep -q "gateway"; then
        pass "Runtime phase mentions gateway"
    else
        fail "Runtime phase should mention gateway"
    fi
}

# ─── Test 8: Gateway filtering simulation ───────────────────────────
test_gateway_filtering() {
    echo
    echo "Test 8: Gateway discovery filtering simulation"
    
    # Simulate a gateway that only has model-a and model-b
    local filtered_catalog='{
      "models": [
        {"id": "model-a", "name": "Model A", "context": 10000, "output": 4096, "reasoning": false, "vision": false, "cost": {"input": 1, "output": 2, "cacheRead": 0.1}},
        {"id": "model-b", "name": "Model B", "context": 20000, "output": 8192, "reasoning": true, "vision": true, "cost": {"input": 2, "output": 4, "cacheRead": 0.2}}
      ]
    }'
    
    local plugin_file="${TESTDIR}/gateway-plugin.json"
    cat > "${plugin_file}" <<'EOF'
{
  "presets": {
    "default": {
      "role1": {"model": ["llm/model-a", "llm/model-b"]},
      "role2": {"model": ["llm/model-c", "llm/model-a"]}
    }
  }
}
EOF
    
    # Static validation against full catalog should pass
    if _validate_plugin_models "${plugin_file}" "${CATALOG_JSON}" "static" 2>/dev/null; then
        pass "Static validation passes with full catalog"
    else
        fail "Static validation should pass"
    fi
    
    # Runtime validation against filtered catalog should warn about model-c
    local runtime_output
    runtime_output=$(_validate_plugin_models "${plugin_file}" "${filtered_catalog}" "runtime" 2>&1)
    
    if echo "${runtime_output}" | grep -q "model-c"; then
        pass "Runtime validation detects unavailable model-c"
    else
        fail "Runtime validation should detect model-c unavailable from gateway"
    fi
}

# ─── Test 9: Empty catalog handling ────────────────────────────────
test_empty_catalog() {
    echo
    echo "Test 9: Empty catalog handling"
    
    local empty_catalog='{"models": []}'
    local plugin_file="${TESTDIR}/plugin-with-refs.json"
    cat > "${plugin_file}" <<'EOF'
{
  "presets": {
    "default": {
      "role1": {"model": "llm/model-a"}
    }
  }
}
EOF
    
    # Non-strict mode: should warn but return success (0)
    CODEBOX_STRICT_MODEL_REFS=false
    local output
    if output=$(_validate_plugin_models "${plugin_file}" "${empty_catalog}" "runtime" 2>&1); then
        pass "Empty catalog in non-strict mode returns success"
    else
        fail "Empty catalog should return 0 in non-strict mode, got exit code $?"
    fi
    
    if echo "${output}" | grep -q "model-a"; then
        pass "Empty catalog warns about all refs being invalid"
    else
        fail "Empty catalog should warn about invalid references"
    fi
    
    # Strict mode: should fail (return 1)
    CODEBOX_STRICT_MODEL_REFS=true
    if ! _validate_plugin_models "${plugin_file}" "${empty_catalog}" "runtime" 2>/dev/null; then
        pass "Empty catalog in strict mode returns failure"
    else
        fail "Empty catalog should return 1 in strict mode"
    fi
    
    unset CODEBOX_STRICT_MODEL_REFS
}

# ─── Run all tests ───────────────────────────────────────────────────
test_extract_refs
test_valid_config
test_invalid_config
test_strict_mode
test_report
test_empty_config
test_phase_labels
test_gateway_filtering
test_empty_catalog

echo
echo "════════════════════════════════════════════════════════════════"
if [ "${errors}" -eq 0 ]; then
    echo "✓ All ${tests_run} tests passed"
    exit 0
else
    echo "✗ ${errors} test(s) failed out of ${tests_run}"
    exit 1
fi
