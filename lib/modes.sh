# ─── lib/modes.sh ───────────────────────────────────────────────────────────
# Launch loops for each supported mode: tmux, web.
# This is the final stage of the entrypoint — it does not return.

_backoff_sleep() { echo $(( 3 * (1 << (${1:-0} > 5 ? 5 : ${1:-0})) )); }

# Extract ttyd's built-in HTML and inject a CSS override to remove the 5px
# terminal padding so the terminal fills the full browser viewport.
_TTYD_INDEX="/tmp/ttyd-index.html"
_generate_ttyd_index() {
    # ttyd serves its HTML at "/" — start it briefly on a random port to grab it.
    local _port _pid
    _port=$(( RANDOM % 10000 + 50000 ))
    ttyd --port "$_port" --interface 127.0.0.1 -- echo >/dev/null 2>&1 &
    _pid=$!
    # Wait for it to be ready (up to 2s)
    for _i in $(seq 1 20); do
        curl -s "http://127.0.0.1:${_port}/" -o "${_TTYD_INDEX}" 2>/dev/null && break
        sleep 0.1
    done
    kill "$_pid" 2>/dev/null; wait "$_pid" 2>/dev/null

    if [ ! -s "${_TTYD_INDEX}" ]; then
        echo "  ! Could not extract ttyd HTML — fullscreen override not applied"
        rm -f "${_TTYD_INDEX}"
        return 1
    fi

    # Inject CSS + JS override right before </body>:
    # 1. Remove the 5px terminal padding
    # 2. Sync body/container background with the terminal's background color
    #    so sub-pixel gaps from character-cell rounding are invisible.
    # 3. Emit modified-Enter keys. xterm.js flattens Shift-Enter and
    #    Ctrl-Enter to a bare CR (its keydown handler honours only Alt),
    #    so agents that bind them (Pi: tui.input.newLine = shift+enter)
    #    never see them. We re-encode them as xterm modifyOtherKeys
    #    (ESC [ 27 ; mod ; 13 ~), which tmux 3.3a parses and forwards
    #    when `extended-keys on` is set (see tmux/tmux.conf).
    #    Alt-Enter is left alone — xterm.js already sends ESC CR.
    cat >> "${_TTYD_INDEX}" <<'PATCH'
<style>body,#terminal-container{background:#000!important}#terminal-container .terminal{padding:0!important;height:100%!important}</style>
<script>
(function(){
  function sync(){
    var v=document.querySelector(".xterm-viewport");
    if(v&&v.style.backgroundColor){
      document.body.style.backgroundColor=v.style.backgroundColor;
      var c=document.getElementById("terminal-container");
      if(c)c.style.backgroundColor=v.style.backgroundColor;
    }
  }
  new MutationObserver(sync).observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:["style"]});
  setInterval(sync,500);

  var bound=false;
  function bindKeys(){
    var t=window.term;
    if(bound||!t||!t.attachCustomKeyEventHandler||!t.input)return;
    bound=true;
    t.attachCustomKeyEventHandler(function(e){
      if(e.type!=="keydown"||e.key!=="Enter"||e.altKey)return true;
      if(!e.shiftKey&&!e.ctrlKey)return true;
      var mod=1+(e.shiftKey?1:0)+(e.ctrlKey?4:0);
      t.input("\x1b[27;"+mod+";13~");
      return false;
    });
  }
  var tries=setInterval(function(){bindKeys();if(bound)clearInterval(tries);},200);
})();
</script>
PATCH
    echo "  ✓ ttyd fullscreen index generated"
}

_serve_ttyd_loop() {
    local wrapper_path="$1" mode_label="$2"
    local _index_flag=""
    if [ -s "${_TTYD_INDEX}" ]; then
        _index_flag="--index ${_TTYD_INDEX}"
    fi
    # Match xterm.js background to tmux theme so sub-pixel gaps are invisible
    local _theme_bg="#1a1b26"
    if [ "$(cat /tmp/.tmux-theme 2>/dev/null)" = "light" ]; then
        _theme_bg="#d5d6db"
    fi
    local _fail_count=0
    while true; do
        if [ ! -x "${wrapper_path}" ]; then
            echo "  ✗ ${wrapper_path} missing or not executable — cannot start ${mode_label} session"
            echo "    Container restart required to regenerate the wrapper script."
            exit 1
        fi
        ttyd \
            --port "${CODEBOX_PORT:-3000}" \
            --interface 0.0.0.0 \
            --writable \
            ${_index_flag} \
            ${_TTYD_SSL_FLAGS:-} \
            -t titleFixed="${CODEBOX_TITLE:-${APP_TITLE_PREFIX} (${mode_label})}" \
            -t macOptionIsMeta=true \
            -t macOptionClickForcesSelection=true \
            -t "theme={\"background\":\"${_theme_bg}\"}" \
            ${CODEBOX_TUI_ARGS:-} \
            "${wrapper_path}"
        _rc=$?
        if [ "${_rc}" -eq 0 ]; then _fail_count=0; else _fail_count=$((_fail_count + 1)); fi
        _sleep=$(_backoff_sleep "$_fail_count")
        echo ""
        echo "  ⟳ ttyd exited (rc=${_rc}). Restart #${_fail_count} in ${_sleep}s..."
        echo ""
        sleep "${_sleep}"
    done
}

# Normalize mode: "tui" is an alias for "tmux"
CODEBOX_MODE="${CODEBOX_MODE:-web}"
[ "${CODEBOX_MODE}" = "tui" ] && CODEBOX_MODE="tmux"
TMUX_SESSION="codebox"

cd /workspace

if [ "${CODEBOX_MODE}" = "tmux" ]; then
    # Generate fullscreen ttyd index for tmux mode
    _generate_ttyd_index
    # ── tmux mode: run app inside tmux, served by ttyd ───────────
    # Architecture: ttyd → wrapper script → tmux new/attach → app
    #
    # Restart on /exit is handled by tmux itself:
    #   remain-on-exit on  → keeps dead pane visible
    #   pane-died hook     → respawns after 2s delay
    # See tmux.conf for the hook definition.
    #
    # Browser disconnects don't kill the tmux session; reopening the
    # URL reattaches instantly.

    # Apply custom tmux config if mounted
    if [ -f "/root/.config/opencode/tmux.conf" ]; then
        cp /root/.config/opencode/tmux.conf /root/.tmux.conf
        echo "  ✓ Custom tmux.conf applied"
    fi

    export TMUX_THEME_DIR="/opt/opencode/tmux"

    echo "→ Starting ${APP_TITLE_PREFIX} TUI via tmux + ttyd on 0.0.0.0:${CODEBOX_PORT:-3000}..."
    echo "  Access: ${_TTYD_PROTOCOL:-http}://localhost:${CODEBOX_PORT:-3000}"
    echo "  Attach: docker exec -it <container> tmux attach -t ${TMUX_SESSION}"
    echo ""

    export CODEBOX_EXTRA_ARGS="${CODEBOX_EXTRA_ARGS:-}"
    cp /opt/opencode/tmux/tmux-wrapper.sh /tmp/tmux-wrapper.sh || {
        echo "  ✗ FATAL: could not copy tmux-wrapper.sh from /opt/opencode/tmux/"
        exit 1
    }
    chmod +x /tmp/tmux-wrapper.sh

    # ttyd serves the wrapper. If ttyd crashes, restart it.
    # The tmux session persists independently across ttyd restarts.
    _serve_ttyd_loop /tmp/tmux-wrapper.sh "tmux"

else
    # ── Web mode (default) ───────────────────────────────────────
    case "${CODEBOX_APP}" in
        claude-code|pi)
            echo "  ✗ FATAL: web mode is not supported for ${APP_TITLE_PREFIX} — use tmux"
            exit 1
            ;;
    esac

    # OpenCode web mode
    echo "→ Starting opencode web on 0.0.0.0:${CODEBOX_PORT:-3000}..."
    echo "  Access: http://localhost:${CODEBOX_PORT:-3000}"
    echo ""

    _fail_count=0
    while true; do
        "${APP_BIN}" web \
            --hostname 0.0.0.0 \
            --port "${CODEBOX_PORT:-3000}" \
            ${CODEBOX_EXTRA_ARGS:-}
        _rc=$?
        if [ "${_rc}" -eq 0 ]; then _fail_count=0; else _fail_count=$((_fail_count + 1)); fi
        _sleep=$(_backoff_sleep "$_fail_count")
        echo ""
        echo "  ⟳ opencode web exited (rc=${_rc}). Restart #${_fail_count} in ${_sleep}s..."
        echo ""

        _restart_proxy
        sleep "${_sleep}"
    done
fi
