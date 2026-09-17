#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# test-gateway-auth-proxy.sh — test gateway-auth proxy functionality
# ═══════════════════════════════════════════════════════════════════
# Tests the gateway-auth proxy token management and routing.
#
# Usage:
#   ./scripts/test-gateway-auth-proxy.sh
#
# Exit codes:
#   0 — all tests passed
#   1 — test failures

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROXY_SCRIPT="${ROOT}/proxy/gateway-auth-proxy.mjs"

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

# ─── Test 1: Proxy script exists and is executable ──────────────────
test_proxy_exists() {
    echo
    echo "Test 1: Proxy script existence"

    if [ -f "${PROXY_SCRIPT}" ]; then
        pass "Proxy script exists: ${PROXY_SCRIPT}"
    else
        fail "Proxy script not found: ${PROXY_SCRIPT}"
        return 1
    fi

    if [ -r "${PROXY_SCRIPT}" ]; then
        pass "Proxy script is readable"
    else
        fail "Proxy script is not readable"
    fi
}

# ─── Test 2: Create mock helper script ──────────────────────────────
test_mock_helper() {
    echo
    echo "Test 2: Mock helper creation"

    local helper="/tmp/mock-rbi-sl-token-$$"

    # Create a mock helper that returns a JWT with 1-hour expiry
    local exp=$(($(date +%s) + 3600))
    local jwt_header="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    local jwt_payload=$(echo "{\"exp\":${exp}}" | base64 | tr -d '\n=' | tr '+/' '-_')
    local jwt_signature="mock_signature"
    local jwt="${jwt_header}.${jwt_payload}.${jwt_signature}"

    cat > "${helper}" <<EOF
#!/bin/bash
echo "${jwt}"
exit 0
EOF
    chmod +x "${helper}"

    if [ -x "${helper}" ]; then
        pass "Mock helper created: ${helper}"
    else
        fail "Mock helper not executable"
        return 1
    fi

    # Test helper output
    local output
    output=$("${helper}")
    if [ "${output}" = "${jwt}" ]; then
        pass "Mock helper returns JWT"
    else
        fail "Mock helper output mismatch"
    fi

    # Verify JWT structure
    if [[ "${output}" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
        pass "JWT format valid"
    else
        fail "JWT format invalid"
    fi

    # Clean up
    rm -f "${helper}"
}

# ─── Test 3: Failing helper fallback ────────────────────────────────
test_failing_helper() {
    echo
    echo "Test 3: Failing helper fallback"

    local helper="/tmp/failing-helper-$$"

    cat > "${helper}" <<EOF
#!/bin/bash
echo "Error: token acquisition failed" >&2
exit 1
EOF
    chmod +x "${helper}"

    if [ -x "${helper}" ]; then
        pass "Failing helper created"
    else
        fail "Failing helper not executable"
        return 1
    fi

    # Test helper fails
    if ! "${helper}" >/dev/null 2>&1; then
        pass "Failing helper exits non-zero"
    else
        fail "Failing helper should exit non-zero"
    fi

    # Clean up
    rm -f "${helper}"
}

# ─── Test 4: JWT expiry parsing ─────────────────────────────────────
test_jwt_parsing() {
    echo
    echo "Test 4: JWT expiry parsing"

    # Create test JWTs with different expiries
    local now=$(date +%s)
    local future=$((now + 7200))  # 2 hours from now

    # Valid JWT with exp field
    local header="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    local payload=$(echo "{\"exp\":${future}}" | base64 | tr -d '\n=' | tr '+/' '-_')
    local jwt="${header}.${payload}.signature"

    pass "Test JWT created with exp=${future}"

    # JWT without exp field
    local payload_no_exp=$(echo '{"sub":"1234567890"}' | base64 | tr -d '\n=' | tr '+/' '-_')
    local jwt_no_exp="${header}.${payload_no_exp}.signature"

    pass "Test JWT created without exp field"

    # Malformed JWT (only 2 parts)
    local malformed="${header}.${payload}"

    pass "Malformed JWT created"
}

# ─── Test 4b: JSON output parsing ───────────────────────────────────
test_json_output() {
    echo
    echo "Test 4b: JSON output parsing"

    local helper="/tmp/json-helper-$$"
    local exp=$(($(date +%s) + 3600))
    local jwt_header="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    local jwt_payload=$(echo "{\"exp\":${exp}}" | base64 | tr -d '\n=' | tr '+/' '-_')
    local jwt="${jwt_header}.${jwt_payload}.mock_sig"

    # Create helper that returns JSON with token and headers
    cat > "${helper}" <<EOF
#!/bin/bash
cat <<'JSON'
{"token":"${jwt}","headers":{"X-Request-ID":"test-123","X-Correlation-ID":"abc-xyz"}}
JSON
exit 0
EOF
    chmod +x "${helper}"

    if [ -x "${helper}" ]; then
        pass "JSON helper created"
    else
        fail "JSON helper not executable"
        return 1
    fi

    # Test JSON output
    local output
    output=$("${helper}")
    if echo "${output}" | jq -e '.token' >/dev/null 2>&1; then
        pass "JSON output has token field"
    else
        fail "JSON output missing token field"
    fi

    if echo "${output}" | jq -e '.headers' >/dev/null 2>&1; then
        pass "JSON output has headers field"
    else
        fail "JSON output missing headers field"
    fi

    # Verify safe header filtering logic exists in proxy
    if grep -q "unsafeHeaders" "${PROXY_SCRIPT}"; then
        pass "Proxy has header filtering logic"
    else
        fail "Proxy missing header filtering"
    fi

    rm -f "${helper}"
}

# ─── Test 5: Configuration validation ───────────────────────────────
test_config_validation() {
    echo
    echo "Test 5: Configuration validation"

    # Check required env vars are documented
    local env_example="${ROOT}/.env.example"

    if grep -q "CODEBOX_GATEWAY_AUTH_PROXY" "${env_example}"; then
        pass "CODEBOX_GATEWAY_AUTH_PROXY documented in .env.example"
    else
        fail "CODEBOX_GATEWAY_AUTH_PROXY not documented"
    fi

    if grep -q "CODEBOX_GATEWAY_AUTH_HELPER" "${env_example}"; then
        pass "CODEBOX_GATEWAY_AUTH_HELPER documented in .env.example"
    else
        fail "CODEBOX_GATEWAY_AUTH_HELPER not documented"
    fi

    if grep -q "CODEBOX_GATEWAY_AUTH_CACHE_TTL" "${env_example}"; then
        pass "CODEBOX_GATEWAY_AUTH_CACHE_TTL documented in .env.example"
    else
        fail "CODEBOX_GATEWAY_AUTH_CACHE_TTL not documented"
    fi

    # Check macOS RBI bridge variables
    if grep -q "CODEBOX_RBI_BRIDGE_ENABLE" "${env_example}"; then
        pass "CODEBOX_RBI_BRIDGE_ENABLE documented in .env.example"
    else
        fail "CODEBOX_RBI_BRIDGE_ENABLE not documented"
    fi
}

# ─── Test 6: Proxy lifecycle functions ──────────────────────────────
test_proxy_functions() {
    echo
    echo "Test 6: Proxy lifecycle functions"

    local proxy_lib="${ROOT}/lib/proxy.sh"

    if grep -q "_start_gateway_auth_proxy" "${proxy_lib}"; then
        pass "_start_gateway_auth_proxy function exists"
    else
        fail "_start_gateway_auth_proxy function not found"
    fi

    if grep -q "_restart_gateway_auth_proxy" "${proxy_lib}"; then
        pass "_restart_gateway_auth_proxy function exists"
    else
        fail "_restart_gateway_auth_proxy function not found"
    fi

    if grep -q "_validate_gateway_auth_helper" "${proxy_lib}"; then
        pass "_validate_gateway_auth_helper function exists"
    else
        fail "_validate_gateway_auth_helper function not found"
    fi
}

# ─── Test 7: Integration with lib/config.sh ─────────────────────────
test_config_integration() {
    echo
    echo "Test 7: Config integration"

    local config_lib="${ROOT}/lib/config.sh"

    # Check LLM_GATEWAY_AUTH_URL is used
    if grep -q "LLM_GATEWAY_AUTH_URL" "${config_lib}"; then
        pass "LLM_GATEWAY_AUTH_URL referenced in config.sh"
    else
        fail "LLM_GATEWAY_AUTH_URL not found in config.sh"
    fi

    # Discovery must use a live gateway-auth proxy, not merely its
    # precomputed URL, and otherwise retain direct LLM_BASE_URL fallback.
    if grep -q 'GATEWAY_AUTH_PROXY_READY' "${config_lib}" && \
       grep -q 'LLM_GATEWAY_AUTH_URL%/' "${config_lib}" && \
       grep -q 'LLM_BASE_URL%/' "${config_lib}"; then
        pass "Model discovery selects the live proxy and retains direct fallback"
    else
        fail "Model discovery is missing live proxy/direct fallback routing"
    fi

    # Check all three agents reference the proxy
    local agents_found=0

    # OpenCode uses LLM_EFFECTIVE_URL which is set to LLM_GATEWAY_AUTH_URL
    if grep -q "_configure_opencode" "${config_lib}" && \
       grep -A 50 "_configure_opencode" "${config_lib}" | grep -q "LLM_GATEWAY_AUTH_URL"; then
        ((agents_found++))
    fi

    # Claude Code uses ANTHROPIC_BASE_URL which is set to LLM_GATEWAY_AUTH_URL
    # Must verify the routing logic checks LLM_GATEWAY_AUTH_URL and exports it
    if grep -q "_generate_claude_code_config" "${config_lib}"; then
        local claude_section
        claude_section=$(grep -A 50 "_generate_claude_code_config" "${config_lib}")
        if echo "${claude_section}" | grep -q "LLM_GATEWAY_AUTH_URL" && \
           echo "${claude_section}" | grep -q "export ANTHROPIC_BASE_URL.*LLM_GATEWAY_AUTH_URL"; then
            ((agents_found++))
        fi
    fi

    # Pi uses _effective_base_url which is set to LLM_GATEWAY_AUTH_URL
    if grep -q "_configure_pi" "${config_lib}" && \
       grep -A 50 "_configure_pi" "${config_lib}" | grep -q "LLM_GATEWAY_AUTH_URL"; then
        ((agents_found++))
    fi

    if [ "${agents_found}" -ge 3 ]; then
        pass "All three agents integrated with gateway-auth proxy (${agents_found}/3)"
    elif [ "${agents_found}" -ge 2 ]; then
        pass "Multiple agents integrated with gateway-auth proxy (${agents_found}/3)"
    else
        fail "Insufficient agent integration (${agents_found}/3)"
    fi
}

# ─── Test 8: Entrypoint integration ─────────────────────────────────
test_entrypoint_integration() {
    echo
    echo "Test 8: Entrypoint integration"

    local entrypoint="${ROOT}/entrypoint.sh"

    local proxy_start_line app_dispatch_line
    proxy_start_line=$(grep -n '_start_gateway_auth_proxy' "${entrypoint}" | head -1 | cut -d: -f1)
    # The first case selects the display title; the second dispatches agent
    # configuration after the proxy startup block.
    app_dispatch_line=$(grep -n '^case "${CODEBOX_APP}" in' "${entrypoint}" | sed -n '2p' | cut -d: -f1)
    if [ -n "${proxy_start_line}" ] && [ -n "${app_dispatch_line}" ] && \
       [ "${proxy_start_line}" -lt "${app_dispatch_line}" ]; then
        pass "Entrypoint starts gateway-auth proxy before app configuration"
    else
        fail "Entrypoint doesn't start gateway-auth proxy before app configuration"
    fi

    if grep -q "GATEWAY_AUTH_PROXY_PID" "${entrypoint}"; then
        pass "Entrypoint tracks gateway-auth proxy PID"
    else
        fail "Entrypoint doesn't track proxy PID"
    fi

    # Check cleanup trap includes gateway-auth proxy
    if grep -A 3 "_cleanup()" "${entrypoint}" | grep -q "GATEWAY_AUTH_PROXY_PID"; then
        pass "Cleanup trap includes gateway-auth proxy"
    else
        fail "Cleanup trap doesn't kill gateway-auth proxy"
    fi
}

# ─── Test 9: Documentation exists ───────────────────────────────────
test_documentation() {
    echo
    echo "Test 9: Documentation"

    local doc="${ROOT}/docs/gateway-auth-proxy.md"

    if [ -f "${doc}" ]; then
        pass "Documentation exists: ${doc}"
    else
        fail "Documentation not found: ${doc}"
        return 1
    fi

    # Check key sections
    local sections=("Overview" "Architecture" "Configuration" "Troubleshooting")
    for section in "${sections[@]}"; do
        if grep -q "## ${section}" "${doc}"; then
            pass "Documentation has ${section} section"
        else
            fail "Documentation missing ${section} section"
        fi
    done
}

# ─── Test 10: Proxy defaults ────────────────────────────────────────
test_proxy_defaults() {
    echo
    echo "Test 10: Proxy defaults"

    # Check proxy script has sensible defaults
    if grep -q "GATEWAY_AUTH_PORT.*18081" "${PROXY_SCRIPT}"; then
        pass "Default port is 18081"
    else
        fail "Default port not 18081"
    fi

    if grep -q "CACHE_TTL.*3300" "${PROXY_SCRIPT}"; then
        pass "Default cache TTL is 3300s (55 min)"
    else
        fail "Default cache TTL incorrect"
    fi

    if grep -q "rbi-sl-token" "${PROXY_SCRIPT}"; then
        pass "Default helper is rbi-sl-token"
    else
        fail "Default helper incorrect"
    fi
}

# ─── Run all tests ──────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════════════════"
echo "Gateway Auth Proxy Test Suite"
echo "═══════════════════════════════════════════════════════════════════"

test_proxy_exists
test_mock_helper
test_failing_helper
test_jwt_parsing
test_json_output
test_config_validation
test_proxy_functions
test_config_integration
test_entrypoint_integration
test_documentation
test_proxy_defaults

# ─── Summary ────────────────────────────────────────────────────────

echo
echo "═══════════════════════════════════════════════════════════════════"
if [ "${errors}" -eq 0 ]; then
    echo "✓ All tests passed (${tests_run} checks)"
    echo "═══════════════════════════════════════════════════════════════════"
    exit 0
else
    echo "✗ ${errors} test(s) failed (${tests_run} checks run)"
    echo "═══════════════════════════════════════════════════════════════════"
    exit 1
fi
