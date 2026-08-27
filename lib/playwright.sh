# ─── lib/playwright.sh ───────────────────────────────────────────────────────
# On-demand Playwright browser installation.
#
# The image ships the `playwright` CLI and the X11/GTK/font/audio system
# libraries (baked by `playwright install-deps chromium`), but NOT the ~984 MB
# of browser binaries. Those are downloaded here, at container start, only when
# CODEBOX_PLAYWRIGHT is enabled — which makes it a per-container runtime
# setting instead of a per-image build arg.
#
# PERSISTENCE: browsers land in PLAYWRIGHT_BROWSERS_PATH
# (/root/.cache/ms-playwright). Mount a named volume there per service so the
# download survives `--force-recreate`, e.g.
#   volumes:
#     - playwright-my-project:/root/.cache/ms-playwright
# Without that mount everything still works, it just re-downloads on recreate.
#
# CODEBOX_PLAYWRIGHT values:
#   false (default) — skip entirely
#   true            — full Chromium + headless shell + ffmpeg (~984 MB)
#   shell           — headless shell only (~340 MB), enough for scraping and
#                     CI-style runs, no headed browser

_PLAYWRIGHT_LOG="/tmp/playwright-install.log"

_install_playwright() {
    local mode="${CODEBOX_PLAYWRIGHT:-false}"
    local dest="${PLAYWRIGHT_BROWSERS_PATH:-/root/.cache/ms-playwright}"
    local args

    case "${mode}" in
        true|1)  args="chromium" ;;
        shell)   args="--only-shell chromium" ;;
        *)       return 0 ;;
    esac

    if ! command -v playwright >/dev/null 2>&1; then
        echo "  ⚠ CODEBOX_PLAYWRIGHT=${mode} but the playwright CLI is missing — skipping"
        return 0
    fi

    # System libraries are baked into the image; warn rather than apt-install at
    # startup, since a missing lib means the image is stale, not misconfigured.
    if ! playwright install-deps --dry-run chromium >/dev/null 2>&1; then
        echo "  ⚠ Playwright system libraries missing — rebuild the image (./codebox.sh rebuild)"
    fi

    if compgen -G "${dest}/chromium*" >/dev/null 2>&1; then
        # Already populated. `playwright install` is idempotent and no-ops in
        # ~0.4s, so run it anyway to pick up browser version bumps.
        # shellcheck disable=SC2086
        if playwright install ${args} >/dev/null 2>&1; then
            echo "  ✓ Playwright browsers ready (${dest})"
        else
            echo "  ⚠ Playwright browser check failed — run: playwright install ${args}"
        fi
        return 0
    fi

    # First start for this volume — a fresh download takes ~1 min, so background
    # it. Blocking here would risk the healthcheck (start_period: 15s).
    echo "  → Downloading Playwright browsers in the background (first start)"
    echo "    Progress: docker exec <container> cat ${_PLAYWRIGHT_LOG}"
    # shellcheck disable=SC2086
    ( playwright install ${args} >"${_PLAYWRIGHT_LOG}" 2>&1 &&
        echo "✓ Playwright browsers installed in ${dest}" >>"${_PLAYWRIGHT_LOG}" ||
        echo "✗ Playwright install failed" >>"${_PLAYWRIGHT_LOG}" ) &
}
