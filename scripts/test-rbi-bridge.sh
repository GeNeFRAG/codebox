#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# test-rbi-bridge.sh — test macOS RBI bridge functionality
# ═══════════════════════════════════════════════════════════════════
# Tests the macOS RBI bridge implementation (host-side server and
# container-side client wrapper).
#
# Usage:
#   ./scripts/test-rbi-bridge.sh
#
# Exit codes:
#   0 — all tests passed
#   1 — test failures

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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

# ─── Test 1: Bridge scripts exist ───────────────────────────────────
test_bridge_scripts() {
    echo
    echo "Test 1: Bridge scripts exist"

    if [ -f "${ROOT}/bin/rbi-bridge" ]; then
        pass "Host bridge script exists"
    else
        fail "Host bridge script not found"
    fi

    if [ -x "${ROOT}/bin/rbi-bridge" ]; then
        pass "Host bridge script is executable"
    else
        fail "Host bridge script not executable"
    fi

    if [ -f "${ROOT}/bin/rbi-bridge-client" ]; then
        pass "Container client wrapper exists"
    else
        fail "Container client wrapper not found"
    fi

    if [ -x "${ROOT}/bin/rbi-bridge-client" ]; then
        pass "Container client wrapper is executable"
    else
        fail "Container client wrapper not executable"
    fi
}

# ─── Test 2: Configuration validation ───────────────────────────────
test_config() {
    echo
    echo "Test 2: Configuration validation"

    local env_example="${ROOT}/.env.example"

    if grep -q "CODEBOX_RBI_BRIDGE_ENABLE" "${env_example}"; then
        pass "CODEBOX_RBI_BRIDGE_ENABLE documented in .env.example"
    else
        fail "CODEBOX_RBI_BRIDGE_ENABLE not documented"
    fi

    if grep -q "CODEBOX_RBI_BRIDGE_PORT" "${env_example}"; then
        pass "CODEBOX_RBI_BRIDGE_PORT documented in .env.example"
    else
        fail "CODEBOX_RBI_BRIDGE_PORT not documented"
    fi

    if grep -q "CODEBOX_RBI_BRIDGE_HOST" "${env_example}"; then
        pass "CODEBOX_RBI_BRIDGE_HOST documented in .env.example"
    else
        fail "CODEBOX_RBI_BRIDGE_HOST not documented"
    fi
}

# ─── Test 3: codebox.sh integration ─────────────────────────────────
test_codebox_integration() {
    echo
    echo "Test 3: codebox.sh integration"

    if grep -q "_manage_rbi_bridge" "${ROOT}/codebox.sh"; then
        pass "codebox.sh has bridge management function"
    else
        fail "codebox.sh missing bridge management"
    fi

    # Check bridge is called in start/stop/restart/down
    local commands=("start" "stop" "restart" "down")
    for cmd in "${commands[@]}"; do
        if grep -A 5 "^[[:space:]]*${cmd})" "${ROOT}/codebox.sh" | grep -q "_manage_rbi_bridge"; then
            pass "Bridge managed in ${cmd} command"
        else
            fail "Bridge not managed in ${cmd} command"
        fi
    done
}

# ─── Test 4: Dockerfile integration ─────────────────────────────────
test_dockerfile() {
    echo
    echo "Test 4: Dockerfile integration"

    if grep -q "rbi-bridge-client" "${ROOT}/Dockerfile"; then
        pass "Dockerfile installs rbi-bridge-client"
    else
        fail "Dockerfile doesn't install rbi-bridge-client"
    fi

    if grep -q "bin/rbi-bridge-client /usr/local/bin/rbi-sl-token" "${ROOT}/Dockerfile"; then
        pass "Client installed as /usr/local/bin/rbi-sl-token"
    else
        fail "Client not installed at correct location"
    fi
}

# ─── Test 5: Documentation exists ───────────────────────────────────
test_documentation() {
    echo
    echo "Test 5: Documentation"

    local doc="${ROOT}/docs/rbi-bridge-macos.md"

    if [ -f "${doc}" ]; then
        pass "Documentation exists: ${doc}"
    else
        fail "Documentation not found: ${doc}"
        return 1
    fi

    # Check key sections
    local sections=("Overview" "Architecture" "Requirements" "Configuration" "Troubleshooting")
    for section in "${sections[@]}"; do
        if grep -q "## ${section}" "${doc}"; then
            pass "Documentation has ${section} section"
        else
            fail "Documentation missing ${section} section"
        fi
    done
}

# ─── Test 6: AGENTS.md updates ──────────────────────────────────────
test_agents_md() {
    echo
    echo "Test 6: AGENTS.md updates"

    if grep -q "bin/rbi-bridge" "${ROOT}/AGENTS.md"; then
        pass "AGENTS.md documents bin/rbi-bridge"
    else
        fail "AGENTS.md missing bin/rbi-bridge entry"
    fi

    if grep -q "bin/rbi-bridge-client" "${ROOT}/AGENTS.md"; then
        pass "AGENTS.md documents bin/rbi-bridge-client"
    else
        fail "AGENTS.md missing bin/rbi-bridge-client entry"
    fi

    if grep -q "rbi-bridge-macos.md" "${ROOT}/AGENTS.md"; then
        pass "AGENTS.md references docs/rbi-bridge-macos.md"
    else
        fail "AGENTS.md missing rbi-bridge-macos.md reference"
    fi

    # Check old in-container helper is removed
    if ! grep -q "lib/rbi-helper.sh" "${ROOT}/AGENTS.md"; then
        pass "Old rbi-helper.sh removed from AGENTS.md"
    else
        fail "Old rbi-helper.sh still referenced in AGENTS.md"
    fi

    if ! grep -q "rbi-helper-quickstart.md" "${ROOT}/AGENTS.md"; then
        pass "Old rbi-helper-quickstart.md removed from AGENTS.md"
    else
        fail "Old rbi-helper-quickstart.md still referenced"
    fi
}

# ─── Test 7: .gitignore rules ───────────────────────────────────────
test_gitignore() {
    echo
    echo "Test 7: .gitignore rules"

    if grep -q "rbi-bridge.pid" "${ROOT}/.gitignore"; then
        pass ".gitignore excludes bridge PID file"
    else
        fail ".gitignore missing bridge PID file"
    fi

    if grep -q "rbi-bridge.log" "${ROOT}/.gitignore"; then
        pass ".gitignore excludes bridge log file"
    else
        fail ".gitignore missing bridge log file"
    fi

    if grep -q "rbi-bridge-server.py" "${ROOT}/.gitignore"; then
        pass ".gitignore excludes bridge server script"
    else
        fail ".gitignore missing bridge server script"
    fi
}

# ─── Test 8: Old implementation removed ─────────────────────────────
test_old_removed() {
    echo
    echo "Test 8: Old implementation removed"

    if [ ! -f "${ROOT}/lib/rbi-helper.sh" ]; then
        pass "lib/rbi-helper.sh removed"
    else
        fail "lib/rbi-helper.sh still exists"
    fi

    if [ ! -f "${ROOT}/docs/rbi-helper-quickstart.md" ]; then
        pass "docs/rbi-helper-quickstart.md removed"
    else
        fail "docs/rbi-helper-quickstart.md still exists"
    fi

    if ! grep -q "rbi-state-self" "${ROOT}/docker-compose.yml"; then
        pass "rbi-state volume removed from docker-compose.yml"
    else
        fail "rbi-state volume still in docker-compose.yml"
    fi

    if ! grep -q "CODEBOX_RBI_HELPER_INSTALL" "${ROOT}/.env.example"; then
        pass "Old CODEBOX_RBI_HELPER_* variables removed from .env.example"
    else
        fail "Old RBI helper variables still in .env.example"
    fi

    if ! grep -q "_install_rbi_helper" "${ROOT}/entrypoint.sh"; then
        pass "RBI helper installation removed from entrypoint.sh"
    else
        fail "RBI helper installation still in entrypoint.sh"
    fi
}

# ─── Test 9: Gateway-auth proxy compatibility ───────────────────────
test_proxy_compat() {
    echo
    echo "Test 9: Gateway-auth proxy compatibility"

    # Proxy should remain unchanged - it just calls whatever helper is on PATH
    if grep -q "CODEBOX_GATEWAY_AUTH_HELPER" "${ROOT}/proxy/gateway-auth-proxy.mjs"; then
        pass "Proxy still uses CODEBOX_GATEWAY_AUTH_HELPER"
    else
        fail "Proxy doesn't use CODEBOX_GATEWAY_AUTH_HELPER"
    fi

    # Static LLM_API_KEY fallback should still exist
    if grep -q "LLM_API_KEY" "${ROOT}/proxy/gateway-auth-proxy.mjs"; then
        pass "Proxy keeps LLM_API_KEY fallback"
    else
        fail "Proxy missing LLM_API_KEY fallback"
    fi
}

# ─── Test 10: Client wrapper implementation ─────────────────────────
test_client_wrapper() {
    echo
    echo "Test 10: Client wrapper implementation"

    local client="${ROOT}/bin/rbi-bridge-client"

    # Check it uses host.docker.internal
    if grep -q "host.docker.internal" "${client}"; then
        pass "Client uses host.docker.internal"
    else
        fail "Client doesn't use host.docker.internal"
    fi

    # Check it respects CODEBOX_RBI_BRIDGE_PORT
    if grep -q "CODEBOX_RBI_BRIDGE_PORT" "${client}"; then
        pass "Client respects CODEBOX_RBI_BRIDGE_PORT"
    else
        fail "Client doesn't check CODEBOX_RBI_BRIDGE_PORT"
    fi

    # Check it has proper error handling
    if grep -q "Error:" "${client}"; then
        pass "Client has error handling"
    else
        fail "Client missing error handling"
    fi

    # Check it distinguishes between network errors and HTTP errors
    if grep -q "Could not resolve host" "${client}" && grep -q "Connection refused" "${client}" && grep -q "bridge returned error" "${client}"; then
        pass "Client distinguishes between error types"
    else
        fail "Client doesn't distinguish between error types"
    fi
}

# ─── Test 11: Bridge server implementation ──────────────────────────
test_bridge_server() {
    echo
    echo "Test 11: Bridge server implementation"

    local bridge="${ROOT}/bin/rbi-bridge"

    # Check platform detection
    if grep -q "Darwin" "${bridge}"; then
        pass "Bridge checks for macOS"
    else
        fail "Bridge doesn't check platform"
    fi

    # Check rbi-sl-token availability check
    if grep -q "command -v rbi-sl-token" "${bridge}"; then
        pass "Bridge checks for rbi-sl-token"
    else
        fail "Bridge doesn't check for helper"
    fi

    # Check it has start/stop/status commands
    for cmd in "start" "stop" "status"; do
        if grep -q "${cmd}" "${bridge}"; then
            pass "Bridge has ${cmd} command"
        else
            fail "Bridge missing ${cmd} command"
        fi
    done
}

# ─── Run all tests ──────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════════════════"
echo "macOS RBI Bridge Test Suite"
echo "═══════════════════════════════════════════════════════════════════"

test_bridge_scripts
test_config
test_codebox_integration
test_dockerfile
test_documentation
test_agents_md
test_gitignore
test_old_removed
test_proxy_compat
test_client_wrapper
test_bridge_server

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
