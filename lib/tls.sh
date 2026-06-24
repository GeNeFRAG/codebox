# ─── lib/tls.sh ─────────────────────────────────────────────────────────────
# Generate locally-trusted TLS certificates for ttyd using mkcert.
# Enables the browser Clipboard API over HTTPS (requires a secure context).
#
# The mkcert CA root persists in a bind mount (.docker/mkcert-ca/) so the
# user only needs to import it into their host trust store once.
# Unlike named volumes, bind mounts survive `docker compose down -v`.
#
# Env vars:
#   CODEBOX_TLS       — "true" (default for tui/tmux) or "false" to disable
#   CODEBOX_TLS_CERT  — path to custom certificate (skips mkcert)
#   CODEBOX_TLS_KEY   — path to custom private key  (skips mkcert)
#
# Exports:
#   _TTYD_SSL_FLAGS    — ttyd CLI flags (empty when TLS is off)
#   _TTYD_PROTOCOL     — "https" or "http"

_TTYD_SSL_FLAGS=""
_TTYD_PROTOCOL="http"

CODEBOX_MODE="${CODEBOX_MODE:-web}"

CODEBOX_TLS="${CODEBOX_TLS:-true}"

if [ "${CODEBOX_MODE}" = "web" ] || [ "${CODEBOX_TLS}" != "true" ]; then
    export _TTYD_SSL_FLAGS _TTYD_PROTOCOL
    return 0
fi

_TLS_DIR="/tmp/tls"
_TLS_CERT="${CODEBOX_TLS_CERT:-${_TLS_DIR}/cert.pem}"
_TLS_KEY="${CODEBOX_TLS_KEY:-${_TLS_DIR}/key.pem}"

if [ -z "${CODEBOX_TLS_CERT:-}" ] || [ -z "${CODEBOX_TLS_KEY:-}" ]; then
    mkdir -p "${_TLS_DIR}"
    _CAROOT="/certs/mkcert-ca"
    _CA_CREATED=false

    if [ ! -f "${_CAROOT}/rootCA.pem" ]; then
        mkdir -p "${_CAROOT}"
        _CA_CREATED=true
    fi

    export CAROOT="${_CAROOT}"
    mkcert -install 2>/dev/null
    mkcert -cert-file "${_TLS_CERT}" -key-file "${_TLS_KEY}" \
        localhost 127.0.0.1 ::1 2>/dev/null

    echo "→ TLS: mkcert certificate generated for localhost"

    if [ "${_CA_CREATED}" = "true" ]; then
        echo ""
        echo "  ┌─────────────────────────────────────────────────────────────┐"
        echo "  │  To remove browser certificate warnings (one-time setup):   │"
        echo "  │                                                             │"
        echo "  │  Import .docker/mkcert-ca/rootCA.pem into your trust store  │"
        echo "  │                                                             │"
        echo "  │  macOS:  open .docker/mkcert-ca/rootCA.pem  (add to        │"
        echo "  │          Keychain, set Always Trust) or:                    │"
        echo "  │          sudo security add-trusted-cert -d -r trustRoot    │"
        echo "  │          -k /Library/Keychains/System.keychain \\            │"
        echo "  │          .docker/mkcert-ca/rootCA.pem                      │"
        echo "  │  Linux:  sudo cp .docker/mkcert-ca/rootCA.pem \\            │"
        echo "  │          /usr/local/share/ca-certificates/mkcert-ca.crt    │"
        echo "  │          && sudo update-ca-certificates                    │"
        echo "  │  Windows: certutil -addstore Root \\                        │"
        echo "  │           .docker/mkcert-ca/rootCA.pem                     │"
        echo "  │                                                             │"
        echo "  │  The CA persists in .docker/mkcert-ca/ (survives rebuilds). │"
        echo "  └─────────────────────────────────────────────────────────────┘"
        echo ""
    fi

elif [ -f "${_TLS_CERT}" ] && [ -f "${_TLS_KEY}" ]; then
    echo "→ TLS: using custom certificate"
else
    echo "  ⚠ TLS: certificate or key not found — falling back to plain HTTP"
    export _TTYD_SSL_FLAGS _TTYD_PROTOCOL
    return 0
fi

_TTYD_SSL_FLAGS="--ssl --ssl-cert ${_TLS_CERT} --ssl-key ${_TLS_KEY}"
_TTYD_PROTOCOL="https"

export _TTYD_SSL_FLAGS _TTYD_PROTOCOL
