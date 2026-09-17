#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# RBI Implementation Validation
# ═══════════════════════════════════════════════════════════════════
# Validates critical invariants of the macOS RBI bridge implementation:
# - Old in-container implementation fully removed
# - Static LLM_API_KEY fallback preserved
# - Phase ordering fixed
# - All error paths properly handled

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

_pass=0
_fail=0

pass() {
    echo -e "${GREEN}✓${NC} $1"
    _pass=$((_pass + 1))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    _fail=$((_fail + 1))
}

echo "═══════════════════════════════════════════════════════════════════"
echo "RBI Implementation Validation"
echo "═══════════════════════════════════════════════════════════════════"

# ─── Invariant 1: Old implementation removed ────────────────────────
echo
echo "Invariant 1: Old in-container implementation removed"

if [ ! -f "${ROOT}/lib/rbi-helper.sh" ]; then
    pass "lib/rbi-helper.sh removed"
else
    fail "lib/rbi-helper.sh still exists"
fi

if ! grep -q "rbi-state" "${ROOT}/docker-compose.yml"; then
    pass "rbi-state volume removed from docker-compose.yml"
else
    fail "rbi-state volume still in docker-compose.yml"
fi

if ! grep -q "CODEBOX_RBI_HELPER_" "${ROOT}/.env.example"; then
    pass "Old CODEBOX_RBI_HELPER_* vars removed from .env.example"
else
    fail "Old env vars still in .env.example"
fi

if ! grep -q "lib/rbi-helper" "${ROOT}/entrypoint.sh"; then
    pass "RBI helper installation removed from entrypoint.sh"
else
    fail "RBI helper installation still in entrypoint.sh"
fi

# ─── Invariant 2: Static LLM_API_KEY fallback preserved ─────────────
echo
echo "Invariant 2: Static LLM_API_KEY fallback preserved"

if grep -q "STATIC_KEY = process.env.LLM_API_KEY" "${ROOT}/proxy/gateway-auth-proxy.mjs"; then
    pass "Gateway-auth proxy reads LLM_API_KEY"
else
    fail "Gateway-auth proxy missing LLM_API_KEY fallback"
fi

if grep -q 'return { token: `Bearer ${STATIC_KEY}`' "${ROOT}/proxy/gateway-auth-proxy.mjs"; then
    pass "Gateway-auth proxy uses STATIC_KEY as fallback"
else
    fail "Gateway-auth proxy doesn't use STATIC_KEY fallback"
fi

if grep -q "Helper availability is checked" "${ROOT}/docs/gateway-auth-proxy.md"; then
    pass "Gateway-auth docs describe fallback behavior"
else
    fail "Gateway-auth docs missing fallback documentation"
fi

# ─── Invariant 3: Phase ordering fixed ──────────────────────────────
echo
echo "Invariant 3: Config generation phase ordering fixed"

if grep -q "Pre-compute gateway-auth proxy URL" "${ROOT}/lib/config.sh"; then
    pass "Config functions pre-compute gateway-auth URL"
else
    fail "Config functions don't pre-compute gateway-auth URL"
fi

if grep -q "export LLM_GATEWAY_AUTH_URL=" "${ROOT}/lib/config.sh"; then
    pass "Config exports LLM_GATEWAY_AUTH_URL deterministically"
else
    fail "Config doesn't export LLM_GATEWAY_AUTH_URL"
fi

if grep -q "^export GATEWAY_AUTH_PROXY_ENABLED=" "${ROOT}/entrypoint.sh"; then
    pass "entrypoint.sh exports GATEWAY_AUTH_PROXY_ENABLED"
else
    fail "entrypoint.sh doesn't export GATEWAY_AUTH_PROXY_ENABLED"
fi

# ─── Invariant 4: Error paths properly handled ──────────────────────
echo
echo "Invariant 4: Error paths properly handled"

if grep -q "Invalid port.*must be.*65535" "${ROOT}/bin/rbi-bridge"; then
    pass "Port validation in rbi-bridge"
else
    fail "Missing port validation in rbi-bridge"
fi

if grep -q "bridge returned error" "${ROOT}/bin/rbi-bridge-client"; then
    pass "Client distinguishes error types"
else
    fail "Client doesn't distinguish error types"
fi

if grep -q "FATAL.*LLM_BASE_URL not set" "${ROOT}/entrypoint.sh"; then
    pass "Missing LLM_BASE_URL is fatal when proxy enabled"
else
    fail "Missing LLM_BASE_URL should be fatal"
fi

if grep -q "error_msg.*stderr.*200" "${ROOT}/bin/rbi-bridge"; then
    pass "Python server sanitizes stderr"
else
    fail "Python server doesn't sanitize stderr"
fi

# ─── Invariant 5: New bridge properly installed ─────────────────────
echo
echo "Invariant 5: New macOS bridge properly installed"

if [ -x "${ROOT}/bin/rbi-bridge" ]; then
    pass "Host bridge script exists and is executable"
else
    fail "Host bridge script missing or not executable"
fi

if [ -x "${ROOT}/bin/rbi-bridge-client" ]; then
    pass "Container client wrapper exists and is executable"
else
    fail "Container client wrapper missing or not executable"
fi

if grep -q "rbi-bridge-client /usr/local/bin/rbi-sl-token" "${ROOT}/Dockerfile"; then
    pass "Dockerfile installs client as /usr/local/bin/rbi-sl-token"
else
    fail "Dockerfile doesn't install client correctly"
fi

if grep -q "_manage_rbi_bridge" "${ROOT}/codebox.sh"; then
    pass "codebox.sh has bridge management function"
else
    fail "codebox.sh missing bridge management"
fi

# ─── Invariant 6: Documentation complete ────────────────────────────
echo
echo "Invariant 6: Documentation complete"

if [ -f "${ROOT}/docs/rbi-bridge-macos.md" ]; then
    pass "RBI bridge documentation exists"
else
    fail "RBI bridge documentation missing"
fi

if grep -q "CODEBOX_RBI_BRIDGE_HOST" "${ROOT}/.env.example"; then
    pass "CODEBOX_RBI_BRIDGE_HOST documented in .env.example"
else
    fail "CODEBOX_RBI_BRIDGE_HOST not documented"
fi

if grep -q "deterministically computed" "${ROOT}/AGENTS.md"; then
    pass "AGENTS.md documents phase ordering fix"
else
    fail "AGENTS.md missing phase ordering documentation"
fi

if grep -q "502.*permanent" "${ROOT}/docs/gateway-auth-proxy.md"; then
    pass "Gateway-auth docs explain 502 vs 503"
else
    fail "Gateway-auth docs don't explain status codes"
fi

# ─── Summary ────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════════════════"
if [ ${_fail} -eq 0 ]; then
    echo -e "${GREEN}✓ All invariants validated (${_pass} checks)${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    exit 0
else
    echo -e "${RED}✗ ${_fail} check(s) failed, ${_pass} passed${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    exit 1
fi
