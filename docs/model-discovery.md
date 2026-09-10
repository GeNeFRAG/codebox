# Gateway Model Discovery

CodeBox can discover available models from your LLM gateway and automatically filter the catalog to only include models the gateway actually supports. This prevents "model not found" errors at runtime.

## How It Works

When `LLM_BASE_URL` is set, CodeBox:

1. **Discovers** available models by calling `${LLM_BASE_URL}/v1/models`
2. **Filters** the catalog (`templates/model-catalog.json`) to only include models that exist in both the catalog AND the gateway's response
3. **Overlays** catalog metadata (limits, pricing, protocol) onto the discovered models
4. **Caches** the discovery result to avoid hammering the gateway on every restart
5. **Injects** the filtered catalog into agent configs (OpenCode, Pi)

## Behavior Modes

### Without LLM_BASE_URL (Native)
```bash
# No gateway configured - use full catalog
unset LLM_BASE_URL
```
- Full catalog is injected into agent configs
- No discovery, no filtering
- Same behavior as before this feature

### With Gateway Available
```bash
export LLM_BASE_URL=https://gateway.example.com
export LLM_API_KEY=your-key
```
- Discovery runs on container start
- Only models in BOTH catalog and gateway are available
- Example: catalog has 22 models, gateway offers 18 → agents see 18

### With Gateway Unavailable (Soft Fail)
```bash
export LLM_BASE_URL=https://gateway.example.com
export LLM_API_KEY=your-key
# Gateway is down or unreachable
```
- Discovery fails with warning
- Falls back to full catalog
- Container starts normally
- You can use models from the catalog, but they may fail at runtime if gateway doesn't support them

### With Gateway Required (Hard Fail)
```bash
export LLM_BASE_URL=https://gateway.example.com
export LLM_API_KEY=your-key
export CODEBOX_REQUIRE_LLM_GATEWAY=true
# Gateway is down or unreachable
```
- Discovery fails
- Container refuses to start
- Use when you want to catch configuration errors early

## Configuration

### Environment Variables

#### `CODEBOX_REQUIRE_LLM_GATEWAY`
- **Type**: boolean
- **Default**: `false`
- **Description**: Fail container startup if gateway is unreachable
- **When to use**: Production environments where you want to catch gateway issues immediately

```bash
# Soft fail (default) - fall back to full catalog if gateway is down
CODEBOX_REQUIRE_LLM_GATEWAY=false

# Hard fail - refuse to start if gateway is down
CODEBOX_REQUIRE_LLM_GATEWAY=true
```

#### `CODEBOX_MODEL_CACHE_TTL`
- **Type**: integer (seconds)
- **Default**: `3600` (1 hour)
- **Description**: How long to cache discovered models
- **Set to `0`**: Disable caching (discover on every config generation)

```bash
# Cache for 1 hour (default)
CODEBOX_MODEL_CACHE_TTL=3600

# Cache for 10 minutes (useful during development)
CODEBOX_MODEL_CACHE_TTL=600

# No caching (always discover)
CODEBOX_MODEL_CACHE_TTL=0
```

#### `CODEBOX_MODEL_DISCOVERY_TIMEOUT`
- **Type**: integer (seconds)
- **Default**: `10`
- **Description**: Timeout for the `/v1/models` request
- **When to increase**: Slow or high-latency gateway

```bash
# Default
CODEBOX_MODEL_DISCOVERY_TIMEOUT=10

# Slow gateway
CODEBOX_MODEL_DISCOVERY_TIMEOUT=30
```

## Cache Behavior

### Cache Location
```
/tmp/codebox-gateway-models-<hash>.json
```

Where `<hash>` is the first 16 characters of SHA256(LLM_BASE_URL). This allows:
- Multiple instances with different gateways to coexist
- Cache to survive container restarts (if `/tmp` is preserved)
- Different services in `docker-compose.override.yml` to share cache

### Cache Format
```json
{
  "timestamp": 1704067200,
  "models": [
    "claude-opus-5",
    "claude-sonnet-5",
    "gpt-5"
  ]
}
```

### When Cache Is Used
- On every `docker compose restart` (if not expired)
- When starting additional services from `docker-compose.override.yml`
- By Pi subagents (they read parent's cache)

### When Cache Is Refreshed
- After TTL expires
- When `CODEBOX_MODEL_CACHE_TTL=0`
- Manually: `rm /tmp/codebox-gateway-models-*.json && docker compose restart`

## Agent-Specific Behavior

### OpenCode
- Filtered models injected into `.provider.llm.models` in `/root/.config/opencode/opencode.json`
- If configured model (`OPENCODE_MODEL`) is not in filtered list, uses `OPENCODE_MODEL_FALLBACK` if set
- Discovery failure + `CODEBOX_REQUIRE_LLM_GATEWAY=false` → full catalog

### Pi
- Filtered models injected into the `llm` provider in `/root/.pi/agent/models.json`
- If `PI_MODEL` is not in filtered list, Pi starts but user must `/model` to pick an available one
- Discovery failure + `CODEBOX_REQUIRE_LLM_GATEWAY=false` → full catalog
- **Subagents**: inherit the same filtered catalog (via shared cache)

### Claude Code
- **No changes** - Claude Code discovers its own models at runtime via `ANTHROPIC_BASE_URL`
- Discovery does not affect Claude Code

## Pi Subagents

Pi subagents (defined in `/root/.pi/agent/agents/*.md`) pin specific models like `claude-sonnet-5`. The discovery system validates these pins:

1. Parent Pi discovers and caches available models
2. Child Pi (subagent) reads the same cache
3. If subagent's pinned model is not in the filtered list, it fails with a clear error

This is **correct behavior** - a subagent should not silently switch to a different model than its definition specifies.

To fix a broken subagent model pin:
1. Check what models are available: `jq '.models[].id' /root/.pi/agent/models.json`
2. Edit `/root/.pi/agent/agents/<name>.md` to pin an available model
3. Restart the container or run `/reload` in Pi

## Troubleshooting

### Discovery Always Fails
```
✗ Gateway discovery failed, using full catalog (22 models)
```

**Causes**:
- Gateway is down or unreachable
- `LLM_API_KEY` is invalid
- Network issues (firewall, proxy, DNS)
- Timeout too short for slow gateway

**Solutions**:
```bash
# Test discovery manually
curl -H "Authorization: Bearer $LLM_API_KEY" "$LLM_BASE_URL/v1/models"

# Increase timeout
export CODEBOX_MODEL_DISCOVERY_TIMEOUT=30

# Check proxy settings
echo $HTTPS_PROXY

# Bypass cache to force fresh discovery
export CODEBOX_MODEL_CACHE_TTL=0
docker compose restart
```

### No Models After Filtering
```
  ⚠ Gateway returned 18 models but none match catalog
  ⚠ Gateway discovery failed or yielded no matches, using full catalog (22 models)
```

**Cause**: Gateway offers models, but none are in `templates/model-catalog.json`

**Note**: When `CODEBOX_REQUIRE_LLM_GATEWAY=false` (default), this falls back to full catalog with a warning. When `CODEBOX_REQUIRE_LLM_GATEWAY=true`, container fails to start

**Solutions**:
1. Check what gateway offers: `curl -H "Authorization: Bearer $LLM_API_KEY" "$LLM_BASE_URL/v1/models" | jq '.data[].id'`
2. Check catalog: `jq '.models[].id' templates/model-catalog.json`
3. Add missing models to the catalog (see [Adding Models](#adding-models))

### Configured Model Not Available
OpenCode log:
```
✗ OPENCODE_MODEL=llm/claude-opus-4-8 not in filtered catalog, trying fallback...
✓ Using fallback model: llm/claude-sonnet-5
```

**Cause**: The model you configured is not offered by your gateway

**Solutions**:
```bash
# Check what's available
docker exec -it <container> jq '.provider.llm.models | keys' /root/.config/opencode/opencode.json

# Set to an available model
export OPENCODE_MODEL=llm/claude-sonnet-5

# Or set a fallback
export OPENCODE_MODEL_FALLBACK=llm/claude-sonnet-5
```

### Cache Stale After Gateway Update
```
# Gateway added new models but agents don't see them
```

**Solution**:
```bash
# Clear cache
docker exec -it <container> rm /tmp/codebox-gateway-models-*.json
docker compose restart

# Or disable cache for one restart
CODEBOX_MODEL_CACHE_TTL=0 docker compose restart
```

### Corporate Proxy or TLS Interception (Zscaler, etc.)
```
  ⚠ Failed to parse gateway response: curl: (60) SSL certificate problem
```

**Cause**: Corporate proxy/firewall intercepts TLS connections with custom CA certificate

**Solutions**:
```bash
# Option 1: Mount your corporate CA certificate
export CA_CERT_PATH=/path/to/corporate-ca.crt
docker compose up -d
# Container installs it into system trust store at startup

# Option 2: Verify certificate is installed
docker exec -it <container> ls -la /usr/local/share/ca-certificates/
docker exec -it <container> curl -v $LLM_BASE_URL/v1/models

# Option 3 (NOT RECOMMENDED): Disable TLS verification
# Only use for testing; never in production
docker exec -it <container> curl -k $LLM_BASE_URL/v1/models
```

### Gateway URL Has Trailing Slash
```bash
# URLs like https://gateway.com/ now handled correctly
export LLM_BASE_URL=https://gateway.com/
# Automatically normalized to https://gateway.com/v1/models
# (not https://gateway.com//v1/models)
```

### Time-Related Cache Issues
```
# Cache rejected due to negative age (time went backward)
```

**Cause**: System time changed backward (NTP correction, container migration)

**Solution**:
```bash
# Clear affected cache
docker exec -it <container> rm /tmp/codebox-gateway-models-*.json
docker compose restart
```

## Testing

### Test Script
```bash
# Run automated tests
./scripts/test-model-discovery.sh

# With live gateway
export LLM_BASE_URL=https://gateway.example.com
export LLM_API_KEY=your-key
./scripts/test-model-discovery.sh
```

### Manual Testing

#### Test Discovery
```bash
# In container
source /opt/opencode/lib/config.sh
discovered=$(_discover_gateway_models)
echo "$discovered" | jq '.'
```

#### Test Filtering
```bash
# In container
source /opt/opencode/lib/config.sh
catalog=$(_get_catalog_for_agent 2>&1)
echo "$catalog" | jq '.models | length'
```

#### Test Cache
```bash
# Write
echo '{"timestamp": '$(date +%s)', "models": ["test-model"]}' > /tmp/codebox-gateway-models-test.json

# Read
export LLM_BASE_URL=https://test
source /opt/opencode/lib/config.sh
_read_model_cache
```

## Adding Models

When your gateway adds a new model:

1. **Add to catalog**: Edit `templates/model-catalog.json`
   ```json
   {
     "id": "new-model",
     "name": "New Model",
     "context": 200000,
     "output": 8192,
     "reasoning": true,
     "vision": true,
     "cost": {
       "input": 3.0,
       "output": 15.0,
       "cacheRead": 0.3,
       "cacheWrite": 3.75
     }
   }
   ```

2. **Validate**: Run `./scripts/verify-model-catalog.sh`

3. **Clear cache**: `rm /tmp/codebox-gateway-models-*.json`

4. **Restart**: `docker compose restart`

The new model will be discovered and available immediately.

## Implementation Details

### Key Functions (lib/config.sh)

- `_discover_gateway_models()` — calls `/v1/models`, returns model IDs
- `_filter_catalog_models($catalog, $allowed_ids)` — filters catalog by ID list
- `_get_catalog_for_agent()` — orchestrator that calls discovery + filtering
- `_opencode_models_from_catalog($catalog)` — transforms catalog to OpenCode shape
- `_pi_models_from_catalog($catalog)` — transforms catalog to Pi shape

### Cache Functions
- `_cache_key_for_gateway()` — generates cache file path
- `_read_model_cache()` — reads cache if valid
- `_write_model_cache($models)` — writes cache with timestamp

### Flow
```
LLM_BASE_URL set?
  ├─ No  → full catalog
  └─ Yes → discover from gateway
           ├─ Success → filter catalog → inject to agent
           ├─ Failure + required → fail startup
           └─ Failure + not required → warn + full catalog
```

## Related Files

- `lib/config.sh` — discovery and filtering implementation
- `templates/model-catalog.json` — source of truth for model metadata
- `scripts/test-model-discovery.sh` — automated test suite
- `scripts/verify-model-catalog.sh` — catalog validation
- `.env.example` — environment variable documentation

## Backward Compatibility

This feature is **fully backward compatible**:

- Without `LLM_BASE_URL`: identical behavior to before (full catalog)
- With `LLM_BASE_URL` but gateway down: falls back to full catalog (like before)
- Existing `.env` files work unchanged
- No new required variables

The only breaking change is if you set `CODEBOX_REQUIRE_LLM_GATEWAY=true`, which is opt-in.
