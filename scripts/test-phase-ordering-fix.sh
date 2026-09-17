#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Phase Ordering Fix Validation
# ═══════════════════════════════════════════════════════════════════
# Validates that gateway-auth starts before config generation so discovery can
# use the token helper, while agent config still computes its URL deterministically.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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
echo "Phase Ordering Fix Validation"
echo "═══════════════════════════════════════════════════════════════════"

# ─── Test 1: Entry point starts proxy before config dispatch ────────
echo
echo "Test 1: Gateway-auth proxy starts before app configuration"

config_file="${ROOT}/lib/config.sh"
entrypoint_file="${ROOT}/entrypoint.sh"
proxy_line=$(grep -n '_start_gateway_auth_proxy' "${entrypoint_file}" | head -1 | cut -d: -f1)
config_line=$(grep -n '^case "${CODEBOX_APP}" in' "${entrypoint_file}" | sed -n '2p' | cut -d: -f1)

if [[ -n "${proxy_line}" && -n "${config_line}" && "${proxy_line}" -lt "${config_line}" ]]; then
    pass "Gateway-auth proxy starts before app configuration"
else
    fail "Gateway-auth proxy must start before app configuration"
fi

if grep -q 'GATEWAY_AUTH_PROXY_READY' "${config_file}" && \
   grep -q 'LLM_GATEWAY_AUTH_URL%/' "${config_file}"; then
    pass "Model discovery uses the live gateway-auth proxy"
else
    fail "Model discovery is missing live proxy routing"
fi

# ─── Test 2: entrypoint.sh exports GATEWAY_AUTH_PROXY_ENABLED ───────
echo
echo "Test 2: entrypoint.sh exports GATEWAY_AUTH_PROXY_ENABLED"

if grep -q '^export GATEWAY_AUTH_PROXY_ENABLED=' "${entrypoint_file}"; then
    pass "GATEWAY_AUTH_PROXY_ENABLED is exported"
else
    fail "GATEWAY_AUTH_PROXY_ENABLED not exported"
fi

# ─── Test 3: entrypoint.sh fails fast on missing LLM_BASE_URL ───────
echo
echo "Test 3: entrypoint.sh fails fast on missing LLM_BASE_URL"

if grep -A 8 'if \[ "${GATEWAY_AUTH_PROXY_ENABLED}" = "true" \]' "${entrypoint_file}" | grep -q 'exit 1'; then
    pass "Gateway-auth startup failure is fatal when enabled"
else
    fail "Gateway-auth startup failure should be fatal"
fi

# ─── Test 4: AGENTS.md documents the phase dependency ────────────────
echo
echo "Test 4: AGENTS.md documents phase ordering"

agents_doc="${ROOT}/AGENTS.md"

if grep -q "before config generation" "${agents_doc}"; then
    pass "AGENTS.md documents proxy-before-config ordering"
else
    fail "AGENTS.md missing proxy-before-config documentation"
fi

# ─── Test 5: Verify port computation uses CODEBOX_GATEWAY_AUTH_PORT ──
echo
echo "Test 5: Port computation uses CODEBOX_GATEWAY_AUTH_PORT"

if grep -q 'CODEBOX_GATEWAY_AUTH_PORT:-18081' "${config_file}"; then
    pass "Config uses CODEBOX_GATEWAY_AUTH_PORT with correct default"
else
    fail "Config doesn't use correct port variable"
fi

# ─── Summary ────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════════════════"
if [ ${_fail} -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed (${_pass} checks)${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    exit 0
else
    echo -e "${RED}✗ ${_fail} test(s) failed, ${_pass} passed${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    exit 1
fi
