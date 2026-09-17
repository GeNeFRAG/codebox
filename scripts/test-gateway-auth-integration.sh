#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# test-gateway-auth-integration.sh — integration test for gateway-auth proxy
# ═══════════════════════════════════════════════════════════════════
# Tests the gateway-auth proxy with a real (mock) HTTP server.
#
# Usage:
#   ./scripts/test-gateway-auth-integration.sh
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

# Create mock upstream server that echoes Authorization header
# Supports auth retry testing via request tracking
create_mock_upstream() {
    local port="${1:-18082}"
    cat > "/tmp/mock-upstream-$$.mjs" <<'EOF'
import http from 'node:http';
const port = parseInt(process.env.PORT || '18082', 10);
const requestCounts = {}; // Track requests per path

const server = http.createServer((req, res) => {
    const auth = req.headers.authorization || 'none';
    const path = req.url;

    // Track request count for this path
    requestCounts[path] = (requestCounts[path] || 0) + 1;
    const reqNum = requestCounts[path];

    if (path === '/v1/models') {
        res.writeHead(200, {'Content-Type': 'application/json'});
        res.end(JSON.stringify({data: [{id: 'test-model'}]}));
    } else if (path === '/v1/chat/completions') {
        res.writeHead(200, {'Content-Type': 'application/json'});
        res.end(JSON.stringify({
            id: 'test',
            choices: [{message: {role: 'assistant', content: 'ok'}}],
            auth_received: auth
        }));
    } else if (path === '/auth-test') {
        res.writeHead(200, {'Content-Type': 'text/plain'});
        res.end(auth);
    } else if (path === '/auth-retry-401') {
        // First request: 401, subsequent: 200 with token
        if (reqNum === 1) {
            res.writeHead(401, {'Content-Type': 'application/json'});
            res.end(JSON.stringify({error: 'Unauthorized'}));
        } else {
            res.writeHead(200, {'Content-Type': 'text/plain'});
            res.end(`retry-success:${auth}`);
        }
    } else if (path === '/auth-retry-403') {
        // First request: 403, subsequent: 200 with token
        if (reqNum === 1) {
            res.writeHead(403, {'Content-Type': 'application/json'});
            res.end(JSON.stringify({error: 'Forbidden'}));
        } else {
            res.writeHead(200, {'Content-Type': 'text/plain'});
            res.end(`retry-success:${auth}`);
        }
    } else if (path === '/deep/nested/path') {
        // Test that retry preserves full path
        res.writeHead(200, {'Content-Type': 'text/plain'});
        res.end(`path-ok:${path}:${auth}`);
    } else if (path === '/header-test') {
        // Test that custom headers from helper are forwarded
        const customHeader = req.headers['x-custom-header'] || 'none';
        res.writeHead(200, {'Content-Type': 'text/plain'});
        res.end(`auth:${auth}|custom:${customHeader}`);
    } else {
        res.writeHead(404);
        res.end();
    }
});
server.listen(port, '127.0.0.1', () => {
    console.log('Mock upstream listening on 127.0.0.1:' + port);
});
EOF
    chmod +x "/tmp/mock-upstream-$$.mjs"
}

# ─── Integration Test: Proxy with mock helper ───────────────────────
test_proxy_integration() {
    echo
    echo "Integration Test: Gateway-auth proxy with mock helper"

    # Check if node is available
    if ! command -v node &>/dev/null; then
        echo "⚠ Node.js not available, skipping integration test"
        return 0
    fi

    # Create mock upstream server
    create_mock_upstream 18082
    PORT=18082 node "/tmp/mock-upstream-$$.mjs" &>/dev/null &
    local upstream_pid=$!
    sleep 1

    if ! kill -0 "${upstream_pid}" 2>/dev/null; then
        echo "⚠ Mock upstream failed to start, skipping integration test"
        rm -f "/tmp/mock-upstream-$$.mjs"
        return 0
    fi

    pass "Mock upstream started (PID ${upstream_pid})"

    # Create mock helper
    local exp=$(($(date +%s) + 3600))
    local jwt_header="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    local jwt_payload=$(echo "{\"exp\":${exp}}" | base64 | tr -d '\n=' | tr '+/' '-_')
    local jwt_signature="mock_signature"
    local jwt="${jwt_header}.${jwt_payload}.${jwt_signature}"

    local helper="/tmp/mock-helper-$$"
    cat > "${helper}" <<EOF
#!/bin/bash
echo "${jwt}"
exit 0
EOF
    chmod +x "${helper}"
    pass "Mock helper created"

    # Start gateway-auth proxy
    UPSTREAM_URL="http://127.0.0.1:18082" \
    CODEBOX_GATEWAY_AUTH_PORT=18083 \
    CODEBOX_GATEWAY_AUTH_HELPER="${helper}" \
    CODEBOX_GATEWAY_AUTH_CACHE_TTL=3600 \
    CODEBOX_GATEWAY_AUTH_LOG_LEVEL=warn \
    LLM_API_KEY="static-fallback-key" \
    node "${PROXY_SCRIPT}" &>/dev/null &
    local proxy_pid=$!
    sleep 2

    if ! kill -0 "${proxy_pid}" 2>/dev/null; then
        fail "Gateway-auth proxy failed to start"
        kill "${upstream_pid}" 2>/dev/null
        rm -f "${helper}" "/tmp/mock-upstream-$$.mjs"
        return 1
    fi

    pass "Gateway-auth proxy started (PID ${proxy_pid})"

    # Test 1: Proxy injects token from helper
    local response
    response=$(curl -sf -H "Authorization: Bearer client-token" \
        http://127.0.0.1:18083/auth-test 2>/dev/null)

    if [[ "${response}" == "Bearer ${jwt_header}."* ]]; then
        pass "Proxy replaced client token with helper token"
    else
        fail "Token not replaced correctly (got: ${response})"
    fi

    # Test 2: Model discovery works through proxy
    response=$(curl -sf http://127.0.0.1:18083/v1/models 2>/dev/null)
    if echo "${response}" | grep -q "test-model"; then
        pass "Model discovery works through proxy"
    else
        fail "Model discovery failed"
    fi

    # Test 3: CodeBox discovery selects the live proxy rather than sending its
    # static key directly to the upstream gateway.
    local discovered
    discovered=$(
        export LLM_BASE_URL="http://127.0.0.1:18082"
        export LLM_GATEWAY_AUTH_URL="http://127.0.0.1:18083"
        export GATEWAY_AUTH_PROXY_READY=true
        export CODEBOX_MODEL_CACHE_TTL=0
        source "${ROOT}/lib/config.sh"
        _discover_gateway_models
    )
    if echo "${discovered}" | jq -e 'index("test-model") != null' >/dev/null 2>&1; then
        pass "CodeBox discovery uses live gateway-auth proxy"
    else
        fail "CodeBox discovery did not use gateway-auth proxy (got: ${discovered})"
    fi

    # Test 4: Auth retry on 401 - first request fails, proxy refreshes token and retries
    response=$(curl -sf http://127.0.0.1:18083/auth-retry-401 2>/dev/null)
    if echo "${response}" | grep -q "retry-success:Bearer ${jwt_header}"; then
        pass "Auth retry on 401 works (token refreshed and request retried)"
    else
        fail "Auth retry on 401 failed (got: ${response})"
    fi

    # Test 4: Auth retry on 403 - first request fails, proxy refreshes token and retries
    response=$(curl -sf http://127.0.0.1:18083/auth-retry-403 2>/dev/null)
    if echo "${response}" | grep -q "retry-success:Bearer ${jwt_header}"; then
        pass "Auth retry on 403 works (token refreshed and request retried)"
    else
        fail "Auth retry on 403 failed (got: ${response})"
    fi

    # Test 5: Retry preserves full request path (not just base URL)
    # This is critical - bug was using 'upstream' (base URL) instead of 'targetUrl' (full path)
    response=$(curl -sf http://127.0.0.1:18083/deep/nested/path 2>/dev/null)
    if echo "${response}" | grep -q "path-ok:/deep/nested/path:Bearer ${jwt_header}"; then
        pass "Retry preserves full request path"
    else
        fail "Retry path preservation failed (got: ${response})"
    fi

    # Cleanup
    kill "${proxy_pid}" "${upstream_pid}" 2>/dev/null
    rm -f "${helper}" "/tmp/mock-upstream-$$.mjs"
    sleep 1

    pass "Integration test cleanup complete"
}

# ─── Test: Fallback to static key when helper unavailable ──────────
test_static_key_fallback() {
    echo
    echo "Integration Test: Static key fallback when helper unavailable"

    # Check if node is available
    if ! command -v node &>/dev/null; then
        echo "⚠ Node.js not available, skipping static key test"
        return 0
    fi

    # Create mock upstream server
    create_mock_upstream 18084
    PORT=18084 node "/tmp/mock-upstream-$$.mjs" &>/dev/null &
    local upstream_pid=$!
    sleep 1

    if ! kill -0 "${upstream_pid}" 2>/dev/null; then
        echo "⚠ Mock upstream failed to start, skipping static key test"
        rm -f "/tmp/mock-upstream-$$.mjs"
        return 0
    fi

    pass "Mock upstream started for static key test"

    # Create failing helper
    local helper="/tmp/failing-helper-$$"
    cat > "${helper}" <<EOF
#!/bin/bash
echo "Helper not available" >&2
exit 1
EOF
    chmod +x "${helper}"

    # Start gateway-auth proxy with failing helper but valid static key
    UPSTREAM_URL="http://127.0.0.1:18084" \
    CODEBOX_GATEWAY_AUTH_PORT=18085 \
    CODEBOX_GATEWAY_AUTH_HELPER="${helper}" \
    CODEBOX_GATEWAY_AUTH_LOG_LEVEL=warn \
    LLM_API_KEY="static-fallback-key-12345" \
    node "${PROXY_SCRIPT}" &>/dev/null &
    local proxy_pid=$!
    sleep 2

    if ! kill -0 "${proxy_pid}" 2>/dev/null; then
        fail "Gateway-auth proxy failed to start with failing helper"
        kill "${upstream_pid}" 2>/dev/null
        rm -f "${helper}" "/tmp/mock-upstream-$$.mjs"
        return 1
    fi

    pass "Gateway-auth proxy started with failing helper"

    # Test: Proxy falls back to static key
    local response
    response=$(curl -sf http://127.0.0.1:18085/auth-test 2>/dev/null)

    if [[ "${response}" == "Bearer static-fallback-key-12345" ]]; then
        pass "Proxy correctly fell back to static LLM_API_KEY"
    else
        fail "Static key fallback failed (got: ${response})"
    fi

    # Cleanup
    kill "${proxy_pid}" "${upstream_pid}" 2>/dev/null
    rm -f "${helper}" "/tmp/mock-upstream-$$.mjs"
    sleep 1

    pass "Static key test cleanup complete"
}

# ─── Test: JSON helper with custom headers ────────────────────────
test_json_helper_headers() {
    echo
    echo "Integration Test: JSON helper with custom headers"

    # Check if node is available
    if ! command -v node &>/dev/null; then
        echo "⚠ Node.js not available, skipping JSON helper test"
        return 0
    fi

    # Create mock upstream server
    create_mock_upstream 18084
    PORT=18084 node "/tmp/mock-upstream-$$.mjs" &>/dev/null &
    local upstream_pid=$!
    sleep 1

    if ! kill -0 "${upstream_pid}" 2>/dev/null; then
        echo "⚠ Mock upstream failed to start, skipping JSON helper test"
        rm -f "/tmp/mock-upstream-$$.mjs"
        return 0
    fi

    pass "Mock upstream started for JSON helper test"

    # Create JSON helper that returns token + custom headers
    local exp=$(($(date +%s) + 3600))
    local jwt_header="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    local jwt_payload=$(echo "{\"exp\":${exp}}" | base64 | tr -d '\n=' | tr '+/' '-_')
    local jwt_signature="json_helper_signature"
    local jwt="${jwt_header}.${jwt_payload}.${jwt_signature}"

    local helper="/tmp/json-helper-$$"
    cat > "${helper}" <<EOF
#!/bin/bash
cat <<JSON_OUTPUT
{
  "token": "${jwt}",
  "headers": {
    "X-Custom-Header": "custom-value-123",
    "X-Request-Id": "req-456"
  }
}
JSON_OUTPUT
exit 0
EOF
    chmod +x "${helper}"
    pass "JSON helper created"

    # Start gateway-auth proxy with JSON helper
    UPSTREAM_URL="http://127.0.0.1:18084" \
    CODEBOX_GATEWAY_AUTH_PORT=18085 \
    CODEBOX_GATEWAY_AUTH_HELPER="${helper}" \
    CODEBOX_GATEWAY_AUTH_CACHE_TTL=3600 \
    CODEBOX_GATEWAY_AUTH_LOG_LEVEL=warn \
    LLM_API_KEY="static-fallback-key" \
    node "${PROXY_SCRIPT}" &>/dev/null &
    local proxy_pid=$!
    sleep 2

    if ! kill -0 "${proxy_pid}" 2>/dev/null; then
        fail "Gateway-auth proxy failed to start with JSON helper"
        kill "${upstream_pid}" 2>/dev/null
        rm -f "${helper}" "/tmp/mock-upstream-$$.mjs"
        return 1
    fi

    pass "Gateway-auth proxy started with JSON helper"

    # Test: Custom headers from JSON helper are forwarded to upstream
    local response
    response=$(curl -sf http://127.0.0.1:18085/header-test 2>/dev/null)

    if echo "${response}" | grep -q "auth:Bearer ${jwt_header}"; then
        pass "JSON helper token forwarded correctly"
    else
        fail "JSON helper token not forwarded (got: ${response})"
    fi

    if echo "${response}" | grep -q "custom:custom-value-123"; then
        pass "JSON helper custom headers forwarded correctly"
    else
        fail "JSON helper custom headers not forwarded (got: ${response})"
    fi

    # Cleanup
    kill "${proxy_pid}" "${upstream_pid}" 2>/dev/null
    rm -f "${helper}" "/tmp/mock-upstream-$$.mjs"
    sleep 1

    pass "JSON helper test cleanup complete"
}

# ─── Run tests ──────────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════════════════"
echo "Gateway Auth Proxy Integration Test"
echo "═══════════════════════════════════════════════════════════════════"

test_proxy_integration
test_static_key_fallback
test_json_helper_headers

# ─── Summary ────────────────────────────────────────────────────────

echo
echo "═══════════════════════════════════════════════════════════════════"
if [ "${errors}" -eq 0 ]; then
    echo "✓ All integration tests passed (${tests_run} checks)"
    echo "═══════════════════════════════════════════════════════════════════"
    exit 0
else
    echo "✗ ${errors} test(s) failed (${tests_run} checks run)"
    echo "═══════════════════════════════════════════════════════════════════"
    exit 1
fi
