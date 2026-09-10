#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# test-model-discovery-integration.sh — integration tests for model discovery
# ═══════════════════════════════════════════════════════════════════
# Tests the full config generation flow with discovery enabled.
# Must be run inside a container.
#
# Usage:
#   docker exec -it <container> /opt/opencode/scripts/test-model-discovery-integration.sh

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

# Check we're in a container
if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ]; then
    echo "✗ This test must run inside a container"
    echo "  Usage: docker exec -it <container> $0"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "CodeBox Model Discovery Integration Test"
echo "═══════════════════════════════════════════════════════════════"

# ─── Test 1: OpenCode config generation ─────────────────────────────
test_opencode_config() {
    echo
    echo "Test 1: OpenCode config generation with discovery"
    
    local config_file="${CONFIG_DIR}/opencode.json"
    
    if [ -f "${config_file}" ]; then
        pass "Config file exists: ${config_file}"
        
        # Check models are present
        local model_count
        model_count=$(jq '.provider.llm.models | length' "${config_file}" 2>/dev/null || echo 0)
        
        if [ "${model_count}" -gt 0 ]; then
            pass "Models injected: ${model_count} models"
        else
            fail "No models in config"
        fi
        
        # Check a known model has the right structure
        local has_limits
        has_limits=$(jq '.provider.llm.models | to_entries | first | .value | has("limit")' "${config_file}" 2>/dev/null)
        
        if [ "${has_limits}" = "true" ]; then
            pass "Model entries have limit structure"
        else
            fail "Model entries missing limit"
        fi
    elif [ "${CODEBOX_APP:-}" = "opencode" ]; then
        fail "Config file not found: ${config_file}"
    else
        echo "  → OpenCode config not generated (CODEBOX_APP=${CODEBOX_APP:-unset})"
    fi
}

# ─── Test 2: Pi config generation ───────────────────────────────────
test_pi_config() {
    echo
    echo "Test 2: Pi config generation with discovery"
    
    local models_file="${PI_CONFIG_DIR}/models.json"
    
    if [ -f "${models_file}" ]; then
        pass "Models file exists: ${models_file}"
        
        # Check llm provider exists
        local has_provider
        has_provider=$(jq 'has("providers") and (.providers | has("llm"))' "${models_file}" 2>/dev/null)
        
        if [ "${has_provider}" = "true" ]; then
            pass "LLM provider configured"
            
            # Check models array
            local model_count
            model_count=$(jq '.providers.llm.models | length' "${models_file}" 2>/dev/null || echo 0)
            
            if [ "${model_count}" -gt 0 ]; then
                pass "Models injected: ${model_count} models"
            else
                fail "No models in provider"
            fi
            
            # Check first model has required fields
            local first_model
            first_model=$(jq '.providers.llm.models[0]' "${models_file}" 2>/dev/null)
            
            local has_required
            has_required=$(jq 'has("id") and has("name") and has("contextWindow") and has("maxTokens") and has("cost") and (.cost | has("cacheWrite"))' <<<"${first_model}" 2>/dev/null)
            
            if [ "${has_required}" = "true" ]; then
                pass "Model entries have required Pi fields including cacheWrite"
            else
                fail "Model entries missing required fields"
            fi
        else
            fail "LLM provider not found"
        fi
    else
        echo "  → Models file not found (expected if LLM_BASE_URL not set): ${models_file}"
    fi
}

# ─── Test 3: Discovery with mock gateway ────────────────────────────
test_mock_discovery() {
    echo
    echo "Test 3: Discovery with mock gateway"
    
    # Set up a mock scenario
    export LLM_BASE_URL="https://mock-gateway.test"
    export LLM_API_KEY="mock-key"
    export CODEBOX_MODEL_CACHE_TTL=3600

    # Seed the discovery cache to simulate a gateway response without network I/O.
    local mock_models='["claude-opus-5","claude-sonnet-5","gpt-5"]'
    _write_model_cache "${mock_models}"
    
    # Try to get catalog
    local catalog
    if catalog=$(_get_catalog_for_agent 2>/dev/null); then
        pass "Got catalog with mock discovery"
        
        local filtered_count
        filtered_count=$(jq '.models | length' <<<"${catalog}" 2>/dev/null || echo 0)
        
        local expected_count
        expected_count=$(jq --argjson ids "${mock_models}" \
            '[.models[] | select(.id as $id | $ids | index($id))] | length' \
            "${MODEL_CATALOG}")
        if [ "${filtered_count}" -eq "${expected_count}" ]; then
            pass "Correctly filtered to ${filtered_count} cataloged mock models"
        else
            fail "Expected ${expected_count} filtered models, got ${filtered_count}"
        fi
    else
        echo "  → Discovery failed (expected without real gateway)"
    fi
    
    # Clean up
    rm -f "$(_cache_key_for_gateway)" 2>/dev/null
}

# ─── Test 4: Fallback behavior ──────────────────────────────────────
test_fallback_behavior() {
    echo
    echo "Test 4: Fallback behavior when gateway unavailable"
    
    # Set up unreachable gateway
    export LLM_BASE_URL="https://unreachable-gateway.test"
    export LLM_API_KEY="test-key"
    export CODEBOX_MODEL_CACHE_TTL=0
    export CODEBOX_REQUIRE_LLM_GATEWAY=false
    
    # Clear any cache
    rm -f "$(_cache_key_for_gateway)" 2>/dev/null
    
    local catalog
    if catalog=$(_get_catalog_for_agent); then
        pass "Fallback to full catalog succeeded"
        
        local model_count
        model_count=$(jq '.models | length' <<<"${catalog}" 2>/dev/null || echo 0)
        
        # Should have full catalog
        local full_count
        full_count=$(jq '.models | length' "${MODEL_CATALOG}" 2>/dev/null || echo 0)
        
        if [ "${model_count}" -eq "${full_count}" ]; then
            pass "Full catalog returned (${model_count} models)"
        else
            fail "Unexpected model count: ${model_count} (expected ${full_count})"
        fi
    else
        fail "Fallback failed"
    fi
}

# ─── Test 5: Required gateway behavior ──────────────────────────────
test_required_gateway() {
    echo
    echo "Test 5: Required gateway failure mode"
    
    # Set up unreachable gateway with required=true
    export LLM_BASE_URL="https://unreachable-gateway.test"
    export LLM_API_KEY="test-key"
    export CODEBOX_MODEL_CACHE_TTL=0
    export CODEBOX_REQUIRE_LLM_GATEWAY=true
    
    # Clear any cache
    rm -f "$(_cache_key_for_gateway)" 2>/dev/null
    
    # Should fail
    if ! _get_catalog_for_agent 2>/dev/null; then
        pass "Correctly failed when gateway required but unavailable"
    else
        fail "Should have failed with CODEBOX_REQUIRE_LLM_GATEWAY=true"
    fi
}

# ─── Run all tests ───────────────────────────────────────────────────
main() {
    test_opencode_config
    test_pi_config
    test_mock_discovery
    test_fallback_behavior
    test_required_gateway
    
    echo
    echo "═══════════════════════════════════════════════════════════════"
    if [ "${errors}" -eq 0 ]; then
        echo "✓ All ${tests_run} integration tests passed"
        exit 0
    else
        echo "✗ ${errors} test(s) failed (${tests_run} run)"
        exit 1
    fi
}

main "$@"
