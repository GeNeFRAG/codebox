# macOS RBI Bridge

## Overview

The macOS RBI bridge provides transparent access to the host-installed `rbi-sl-token` helper from within the CodeBox container. Unlike the previous in-container approach (which required downloading binaries from Artifactory), this bridge leverages the macOS helper you already have installed.

## Architecture

```
Container                             Host (macOS)
┌──────────────────────┐              ┌────────────────────┐
│ gateway-auth-proxy   │              │  rbi-bridge server │
│        ↓             │              │  (Python HTTP)     │
│ rbi-sl-token wrapper │──HTTP────────>│        ↓           │
│ (rbi-bridge-client)  │  host.dock...│  rbi-sl-token      │
└──────────────────────┘              │  (native macOS)    │
                                      └────────────────────┘
```

1. **Host side**: `codebox.sh` automatically starts a Python HTTP server that invokes the local `rbi-sl-token`
2. **Container side**: A wrapper script at `/usr/local/bin/rbi-sl-token` makes HTTP calls to the bridge
3. **Proxy integration**: `gateway-auth-proxy.mjs` calls the wrapper like any other helper
4. **Docker Desktop networking**: Container reaches host via `host.docker.internal`

## Requirements

- **macOS** — The bridge uses Docker Desktop's `host.docker.internal` networking
- **Docker Desktop** (or compatible runtime) — Colima, Podman Desktop, and Rancher Desktop also work. For non-Docker-Desktop runtimes, set `CODEBOX_RBI_BRIDGE_HOST` to your runtime's host alias (e.g., `host.lima.internal` for Colima)
- **rbi-sl-token** — Must be installed on the macOS host and available in `PATH`

> **⚠ Bridge must be running before container starts.** The gateway-auth proxy checks helper availability once at startup and caches the result permanently. If you start the bridge after the container, the proxy will continue using the static `LLM_API_KEY` fallback until the container is restarted.

## Configuration

Enable the bridge in `.env`:

```bash
# Enable macOS RBI bridge (opt-in, default: false)
CODEBOX_RBI_BRIDGE_ENABLE=true

# Bridge server port on host (optional, default: 8092)
# CODEBOX_RBI_BRIDGE_PORT=8092

# Bridge hostname for container (default: host.docker.internal)
# Override if not using Docker Desktop (e.g., Colima: host.lima.internal)
# CODEBOX_RBI_BRIDGE_HOST=host.docker.internal

# Enable gateway-auth proxy (required for bridge to be used)
CODEBOX_GATEWAY_AUTH_PROXY=true
```

## Usage

The bridge is **automatically managed** by `codebox.sh`:

```bash
# Start container (automatically starts bridge if enabled)
./codebox.sh start codebox

# Stop container (automatically stops bridge)
./codebox.sh stop codebox

# Restart (automatically restarts bridge)
./codebox.sh restart codebox

# Check bridge status
./bin/rbi-bridge status
```

## Verification

### 1. Check bridge is running

```bash
./bin/rbi-bridge status
```

Expected output:
```
Bridge: running (PID 12345)
Log: .docker/rbi-bridge.log (3 lines)
```

### 2. Test from host

```bash
curl http://127.0.0.1:8092/token
```

Should return a JWT or JSON with token.

### 3. Test from container

```bash
docker exec codebox rbi-sl-token
```

Should return the same token.

### 4. Check gateway-auth proxy logs

```bash
./codebox.sh logs codebox | grep gateway-auth
```

Look for:
```
✓ Token helper found: rbi-sl-token
✓ Gateway-auth proxy running (PID 1234)
Stats: ... token_source=helper ...
```

## Troubleshooting

### Bridge fails to start

**Symptom:**
```
Error: rbi-sl-token not found in PATH
```

**Fix:**
Install `rbi-sl-token` on your macOS host. Verify:
```bash
which rbi-sl-token
rbi-sl-token --version
```

---

**Symptom:**
```
Error: RBI bridge is only supported on macOS
```

**Fix:**
The bridge only works on macOS with Docker Desktop. On Linux, use static `LLM_API_KEY` or install `rbi-sl-token` directly in the container.

---

### Container can't reach bridge

**Symptom (in container logs):**
```
Error: RBI bridge unavailable at host.docker.internal:8092
Connection refused
```

**Fix:**
Check bridge is running:
```bash
./bin/rbi-bridge status
```

If not running:
```bash
./bin/rbi-bridge start 8092
```

---

**Symptom:**
```
Docker Desktop host.docker.internal not available
```

**Fix:**
Ensure Docker Desktop is running (not Rancher Desktop or Podman). The bridge requires Docker Desktop's `host.docker.internal` networking feature.

---

### Tokens not refreshing

**Symptom:**
Requests fail with 401 after ~1 hour

**Check:**
1. Bridge logs: `cat .docker/rbi-bridge.log`
2. Helper working: `rbi-sl-token` (run manually on host)
3. Proxy logs: `./codebox.sh logs codebox | grep "token_source=helper"`

**If helper fails:**
The bridge passes through any errors from `rbi-sl-token`. Check helper configuration on the host.

---

### Bridge port conflict

**Symptom:**
```
Error: Bridge failed to start
OSError: [Errno 48] Address already in use
```

**Fix:**
Choose a different port:
```bash
# In .env
CODEBOX_RBI_BRIDGE_PORT=8093
```

---

## Security Notes

- **Localhost only**: Bridge listens on `127.0.0.1`, not exposed to network
- **Host<->Container trust**: HTTP is acceptable since communication is local
- **No token persistence**: Tokens flow through memory, never written to disk
- **Helper isolation**: Bridge invokes helper as separate process, tokens cleaned up after use
- **Port security**: Bridge port is not exposed in docker-compose.yml

## Manual Bridge Management

For debugging, the bridge can be managed independently:

```bash
# Start bridge manually
./bin/rbi-bridge start 8092

# Stop bridge
./bin/rbi-bridge stop

# Check status
./bin/rbi-bridge status

# View logs
cat .docker/rbi-bridge.log
```

**Note:** `codebox.sh start/stop/restart` manage the bridge automatically when `CODEBOX_RBI_BRIDGE_ENABLE=true`, so manual management is rarely needed.

## Comparison to In-Container Helper

| Aspect | Old (In-Container) | New (Bridge) |
|--------|-------------------|--------------|
| **Installation** | Download from Artifactory | Use host-installed helper |
| **Updates** | Manual (change version in .env) | Automatic (follows host) |
| **Platform** | Linux x86_64/aarch64 | macOS only |
| **Credentials** | File-backed in container volume | Host keychain |
| **Binary** | Linux ELF | macOS Mach-O (native) |
| **Setup complexity** | Checksums, version pinning | One env var |

## Disabling the Bridge

Set `CODEBOX_RBI_BRIDGE_ENABLE=false` in `.env` (or remove the variable). The container will fall back to static `LLM_API_KEY` if the helper is not available.

## Related Documentation

- [Gateway Auth Proxy](gateway-auth-proxy.md) — Token management architecture
- [Model Discovery](model-discovery.md) — How discovery works with rotating tokens
- `.env.example` — Full configuration reference
