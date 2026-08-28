# ─── lib/plugins.sh ─────────────────────────────────────────────────────────
# Verify opencode npm plugins are present.
#
# The image bakes a complete node_modules plus an md5 fingerprint of the
# package.json it was built from (.deps-fingerprint). When that fingerprint
# still matches, there is nothing to do and the install is skipped — worth
# ~4-5s on every start. Every dependency is pinned to an exact version in the
# Dockerfile, so npm has no "latest"/semver tag left to revalidate against
# the registry.
#
# The install still runs when the fingerprint is missing or stale, or when
# node_modules has been wiped — oh-my-opencode-slim's auto-update-checker can
# rm -rf and rebuild node_modules mid-session.

_PLUGINS_FINGERPRINT="${CONFIG_DIR}/.deps-fingerprint"

_plugins_up_to_date() {
    [ -f "${_PLUGINS_FINGERPRINT}" ] || return 1
    [ -d "${CONFIG_DIR}/node_modules/oh-my-opencode-slim" ] || return 1
    [ "$(md5sum "${CONFIG_DIR}/package.json" | cut -d' ' -f1)" \
        = "$(cat "${_PLUGINS_FINGERPRINT}")" ]
}

if [ "${CODEBOX_APP}" = "opencode" ] && [ -f "${CONFIG_DIR}/package.json" ]; then
    if _plugins_up_to_date; then
        echo "  ✓ Plugins ready (cached)"
    else
        echo "→ Ensuring opencode plugins are installed..."
        if (cd "${CONFIG_DIR}" && npm install --prefer-offline --no-audit --no-fund 2>/dev/null); then
            md5sum "${CONFIG_DIR}/package.json" | cut -d' ' -f1 > "${_PLUGINS_FINGERPRINT}"
            echo "  ✓ Plugins ready"
        else
            echo "  ⚠ Plugin install failed (non-fatal) — continuing with cached modules"
        fi
    fi
fi

if [ "${CODEBOX_APP}" = "opencode" ] && [ -d "/workspace/.opencode" ]; then
    echo "  ✓ Project .opencode directory found"
fi
