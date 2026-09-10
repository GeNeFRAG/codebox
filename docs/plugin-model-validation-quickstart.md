# Plugin Model Validation — Quick Start

## What It Does

Validates that model references in `oh-my-opencode-slim.json` (OpenCode agent role presets) match entries in `model-catalog.json`. Catches typos and unavailable models before runtime failures.

## Quick Commands

```bash
# Check template for invalid model references
./scripts/verify-plugin-models.sh

# Run full validation test suite
./scripts/test-plugin-model-validation.sh

# Run integration tests
./scripts/test-plugin-integration.sh

# Enable strict mode (fail on invalid refs)
export CODEBOX_STRICT_MODEL_REFS=true
./codebox.sh restart codebox
```

## When to Use

### During Development

```bash
# 1. Edit plugin template
vim templates/oh-my-opencode-slim.json.template

# 2. Verify references are valid
./scripts/verify-plugin-models.sh

# 3. Restart to see runtime validation
./codebox.sh restart codebox
```

### Before Commit

```bash
# Verify both catalog and plugin consistency
./scripts/verify-model-catalog.sh
./scripts/verify-plugin-models.sh
```

### In CI/CD

```yaml
# .github/workflows/verify.yml
- name: Verify model references
  run: |
    ./scripts/verify-model-catalog.sh
    ./scripts/verify-plugin-models.sh
    ./scripts/test-plugin-model-validation.sh
```

## Validation Phases

| Phase | When | Checks Against | Purpose |
|-------|------|----------------|---------|
| **Static** | Template copy | Full catalog | Catch typos, nonexistent models |
| **Runtime** | After gateway discovery | Filtered catalog | Warn about unavailable models |

## Reading the Output

### ✓ Success (All Valid)

```
→ Generating opencode.json from template...
  ✓ Model catalog: 15 models injected
  ✓ oh-my-opencode-slim.json refreshed from template
  ✓ oh-my-opencode-slim: 10/10 unique model refs in catalog
```

All model references exist and are available.

### ⚠ Warning (Some Unavailable)

```
  ⚠ oh-my-opencode-slim references models not in runtime catalog:
      gpt-5.4-mini
      claude-opus-4-7
    These models are not available from the gateway.
    Agent roles may fail at runtime if no valid fallback exists.
  ✓ oh-my-opencode-slim: 8/10 unique model refs in catalog
    Not in catalog: gpt-5.4-mini,claude-opus-4-7
```

Some models aren't offered by the gateway. Roles with valid fallbacks continue working.

### ✗ Error (Strict Mode)

```
  ✗ FATAL: oh-my-opencode-slim references models not in static catalog:
      nonexistent-model
    These models do not exist in templates/model-catalog.json.
    Update the catalog or fix the plugin template.
  ✗ FATAL: oh-my-opencode-slim validation failed (CODEBOX_STRICT_MODEL_REFS=true)
```

`CODEBOX_STRICT_MODEL_REFS=true` and invalid references found. Container stops.

## Common Scenarios

### Scenario: New Model Added to Gateway

```bash
# 1. Add to catalog
vim templates/model-catalog.json

# 2. Add to plugin roles
vim templates/oh-my-opencode-slim.json.template

# 3. Verify
./scripts/verify-model-catalog.sh
./scripts/verify-plugin-models.sh

# 4. Restart
./codebox.sh restart codebox
```

### Scenario: Gateway Subset (Dev/Test)

Gateway only has Claude models, but catalog has Claude + GPT:

```bash
# Non-strict (default): Warns but starts
./codebox.sh restart codebox
# Output: ⚠ oh-my-opencode-slim references models not in runtime catalog: gpt-*

# Strict: Fails
CODEBOX_STRICT_MODEL_REFS=true ./codebox.sh restart codebox
# Output: ✗ FATAL: oh-my-opencode-slim runtime validation failed
```

**Fix**: Either:
- Add GPT models to dev gateway
- Remove GPT refs from plugin template
- Keep warnings (non-strict) and rely on fallbacks

### Scenario: Typo in Template

```json
{
  "orchestrator": {
    "model": "llm/claude-opus-55"  // Typo: 55 instead of 5
  }
}
```

```bash
./scripts/verify-plugin-models.sh
# Output: ✗ Plugin template references models not in catalog:
#     claude-opus-55
```

**Fix**: Correct the typo to `claude-opus-5`

### Scenario: Model Removed from Catalog

```bash
# Model removed from catalog but still in plugin
./scripts/verify-plugin-models.sh
# Output: ✗ ... references models not in catalog: old-model-id

# Fix options:
# 1. Remove from plugin template
vim templates/oh-my-opencode-slim.json.template

# 2. Re-add to catalog (if removal was a mistake)
vim templates/model-catalog.json
```

## Environment Variables

```bash
# Fail on invalid references (default: false)
CODEBOX_STRICT_MODEL_REFS=true

# Disable gateway discovery (use full catalog for runtime)
unset LLM_BASE_URL
```

## File Locations

```
templates/model-catalog.json              # Source of truth
templates/oh-my-opencode-slim.json.template  # Plugin preset template
/root/.config/opencode/oh-my-opencode-slim.json  # Active config (in container)

scripts/verify-plugin-models.sh           # Standalone validation
scripts/test-plugin-model-validation.sh   # Unit tests
scripts/test-plugin-integration.sh        # Integration tests

lib/config.sh                             # Runtime integration
  _extract_plugin_model_refs()
  _validate_plugin_models()
  _report_plugin_model_status()
```

## See Also

- Full documentation: `docs/plugin-model-validation.md`
- Model catalog validation: `docs/model-discovery.md`
- Gateway discovery: `docs/model-discovery-quickstart.md`
