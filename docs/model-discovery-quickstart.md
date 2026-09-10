# Model Discovery Quick Start

This guide shows you how to use gateway model discovery in CodeBox.

## 5-Minute Setup

### 1. Basic Setup (Recommended)

Add to your `.env`:
```bash
LLM_BASE_URL=https://your-gateway.example.com
LLM_API_KEY=your-api-key
```

That's it! On next restart, CodeBox will:
- ✓ Discover available models from `/v1/models`
- ✓ Filter catalog to only supported models
- ✓ Cache results for 1 hour
- ✓ Fall back to full catalog if gateway is down

### 2. Strict Mode (Production)

Fail fast if gateway is unavailable:
```bash
LLM_BASE_URL=https://your-gateway.example.com
LLM_API_KEY=your-api-key
CODEBOX_REQUIRE_LLM_GATEWAY=true
```

Container won't start if gateway is unreachable.

### 3. Custom Cache Duration

```bash
# Cache for 10 minutes (during development)
CODEBOX_MODEL_CACHE_TTL=600

# No caching (always discover)
CODEBOX_MODEL_CACHE_TTL=0
```

## Quick Test

After starting the container:

```bash
# Check what models were discovered
docker exec -it codebox jq '.provider.llm.models | keys' \
  /root/.config/opencode/opencode.json

# For Pi
docker exec -it codebox jq '.providers.llm.models[].id' \
  /root/.pi/agent/models.json
```

## Common Scenarios

### Scenario 1: Gateway Has Fewer Models Than Catalog

**Catalog**: 22 models  
**Gateway**: 18 models  
**Result**: Agents see 18 models (the intersection)

```
Startup log:
  ✓ Gateway discovery: 18/18 catalog models available
  ✓ Model catalog: 18 models injected
```

### Scenario 2: Your Configured Model Not Available

```
Startup log:
  ⚠ OPENCODE_MODEL=claude-opus-4-8 not in filtered catalog
  ✓ Using fallback model: claude-sonnet-5
```

**Fix**: Set an available model or fallback:
```bash
OPENCODE_MODEL=claude-sonnet-5
OPENCODE_MODEL_FALLBACK=claude-haiku-4-5
```

### Scenario 3: Gateway Temporarily Down

```
Startup log:
  ⚠ Gateway discovery failed, using full catalog (22 models)
```

**With default settings**: Container starts, falls back to full catalog  
**With REQUIRE_GATEWAY=true**: Container refuses to start

### Scenario 4: New Model Added to Gateway

```bash
# Clear cache to pick up new models
docker exec -it codebox rm /tmp/codebox-gateway-models-*.json
docker compose restart
```

Or wait for cache to expire (default 1 hour).

## Verification

### Check Discovery Worked

```bash
# See startup logs
docker compose logs codebox | grep -i "discovery\|catalog"

# Should show something like:
#   ✓ Gateway discovery: 18/18 catalog models available
#   ✓ Model catalog: 18 models injected
```

### Check Cache

```bash
# Find cache file
docker exec -it codebox ls -lh /tmp/codebox-gateway-models-*.json

# Read cache
docker exec -it codebox cat /tmp/codebox-gateway-models-*.json | jq .
```

### Test Discovery Manually

```bash
# Inside container
docker exec -it codebox bash -c "
  source /opt/opencode/lib/config.sh
  discovered=\$(_discover_gateway_models)
  echo \"\$discovered\" | jq 'length'
"
```

## Troubleshooting

### Discovery Always Fails

```bash
# Test gateway manually
curl -H "Authorization: Bearer $LLM_API_KEY" \
  "$LLM_BASE_URL/v1/models" | jq '.data[].id'
```

**Common causes**:
- Invalid API key
- Wrong gateway URL
- Network/firewall blocking
- Timeout too short

**Solutions**:
```bash
# Increase timeout
CODEBOX_MODEL_DISCOVERY_TIMEOUT=30

# Check environment
docker exec -it codebox env | grep LLM_
```

### Cache Stale

```bash
# Clear cache
docker exec -it codebox rm /tmp/codebox-gateway-models-*.json
docker compose restart

# Or disable cache temporarily
CODEBOX_MODEL_CACHE_TTL=0 docker compose up -d
```

### Model Not Available

```bash
# Check what's available
docker exec -it codebox jq '.provider.llm.models | keys' \
  /root/.config/opencode/opencode.json

# Update your .env to use an available model
OPENCODE_MODEL=llm/claude-sonnet-5
```

## Disable Discovery

To go back to the old behavior (no discovery):

```bash
# Option 1: Remove LLM_BASE_URL
unset LLM_BASE_URL

# Option 2: Keep URL but disable discovery (not supported - just omit LLM_BASE_URL)
# Discovery is automatic when LLM_BASE_URL is set
```

## Next Steps

- **Full docs**: See `docs/model-discovery.md`
- **Testing**: Run `./scripts/test-model-discovery.sh`
- **Implementation details**: See `IMPLEMENTATION.md`

## FAQ

**Q: Does this work with all agents?**  
A: OpenCode and Pi use discovery. Claude Code discovers models itself at runtime.

**Q: What if I have multiple gateways?**  
A: Not supported. Use one gateway per container. Run multiple containers for multiple gateways.

**Q: Can I force a specific model list?**  
A: Not directly. Edit `templates/model-catalog.json` to define what's available.

**Q: Does discovery slow down startup?**  
A: First start: ~100-500ms. Subsequent: <1ms (cached).

**Q: What happens to Pi subagents?**  
A: They inherit the filtered catalog and validate their pinned models against it.

**Q: Can I see what was discovered?**  
A: Yes, check cache: `docker exec -it codebox cat /tmp/codebox-gateway-models-*.json`

**Q: How do I add a new model?**  
A: Add to `templates/model-catalog.json`, then clear cache and restart.
