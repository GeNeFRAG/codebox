# oh-my-opencode-slim Model Reference Validation

## Overview

The `oh-my-opencode-slim` plugin defines which models each agent role (orchestrator, oracle, designer, etc.) and council member uses. These model references must align with entries in `templates/model-catalog.json`, which is the single source of truth for model limits, pricing, and protocol configuration.

Model reference validation ensures that:
1. **Static validation**: All model references in the plugin template exist in the catalog (catches typos)
2. **Runtime validation**: Referenced models are available from the configured gateway (warns about unavailable fallbacks)

This validation runs automatically during container startup and is also available as a standalone script.

## Architecture

### Two-Phase Validation

**Phase 1: Static (Template → Full Catalog)**
- Runs during `_configure_opencode()` in `lib/config.sh`
- Checks `templates/oh-my-opencode-slim.json.template` against the **full** `model-catalog.json`
- Catches typos and references to nonexistent models
- Always runs, regardless of gateway configuration

**Phase 2: Runtime (Config → Discovered Catalog)**
- Runs after gateway model discovery (if `LLM_BASE_URL` is set)
- Checks the active plugin config against the **filtered** catalog (post-discovery)
- Warns when referenced models are unavailable from the gateway
- Agent roles with no valid fallback in their array may fail at runtime

### Validation Behavior

| Mode | Invalid Reference Found | Behavior |
|------|------------------------|----------|
| Default (`CODEBOX_STRICT_MODEL_REFS` unset or `false`) | ⚠ Warning printed to stderr | Container starts normally |
| Strict (`CODEBOX_STRICT_MODEL_REFS=true`) | ✗ Error printed to stderr | Container startup fails (`exit 1`) |

**Default behavior**: Validation warns but allows startup. This supports:
- Development/testing with partial gateway coverage
- Gradual catalog updates without breaking existing configs
- User-edited configs that may intentionally reference models not in the catalog

**Strict mode**: Validation failure stops container startup. Use when:
- Running production deployments that must have valid fallback chains
- CI/CD pipelines that should catch misconfigurations early
- Testing catalog changes before deployment

## Configuration

### Environment Variables

```bash
# Enable strict validation (fail on invalid references)
CODEBOX_STRICT_MODEL_REFS=true

# Disable gateway discovery (runtime validation uses full catalog)
LLM_BASE_URL=  # unset
```

### Model Reference Format

Model references in `oh-my-opencode-slim.json` must:
1. Use the `llm/` provider prefix: `"llm/claude-opus-5"`
2. Match a model `id` field in `model-catalog.json` (after stripping the prefix)
3. Appear in either a single-model string or a fallback array:

```json
{
  "presets": {
    "default": {
      "orchestrator": {
        "model": [
          "llm/claude-opus-5",      // Primary
          "llm/claude-opus-4-8",    // Fallback 1
          "llm/claude-sonnet-5"     // Fallback 2
        ]
      },
      "explorer": {
        "model": "llm/claude-haiku-4-5"  // Single model (no fallbacks)
      }
    }
  },
  "council": {
    "presets": {
      "default": {
        "alpha": {
          "model": ["llm/claude-opus-5", "llm/claude-opus-4-8"]
        }
      }
    }
  }
}
```

## Validation Scripts

### Standalone: `scripts/verify-plugin-models.sh`

Validates the plugin template against the full catalog. Useful for:
- Pre-commit checks
- CI/CD validation
- Manual verification after editing templates

```bash
# Basic validation
./scripts/verify-plugin-models.sh

# Example output (all valid):
→ Validating oh-my-opencode-slim model references...
  → Total unique model references: 10
  → Valid (in catalog): 10
  → Invalid (not in catalog): 0
✓ All oh-my-opencode-slim model references are valid

# Example output (invalid references):
→ Validating oh-my-opencode-slim model references...
✗ Plugin template references models not in catalog:
    nonexistent-model
    typo-model-name

  These models do not exist in templates/model-catalog.json.
  Either add them to the catalog or remove them from the plugin template.

  → Total unique model references: 12
  → Valid (in catalog): 10
  → Invalid (not in catalog): 2
```

Exit codes:
- `0`: All references valid
- `1`: Invalid references found or script error

### Test Suite: `scripts/test-plugin-model-validation.sh`

Tests the validation functions in `lib/config.sh`:
- Model reference extraction
- Valid/invalid config detection
- Strict mode enforcement
- Report generation
- Gateway filtering simulation

```bash
./scripts/test-plugin-model-validation.sh

# Output:
✓ Extracted correct model references
✓ Valid plugin config accepted
✓ Invalid reference 'nonexistent' detected
...
✓ All 15 tests passed
```

## Runtime Integration

Validation is integrated into `lib/config.sh` at these points:

1. **After `_generate_config()`**: The catalog has been filtered by gateway discovery (if enabled)
2. **After copying `oh-my-opencode-slim.json.template`**: The plugin config is in place
3. **Before auth.json generation**: Early enough to fail before agent startup

```bash
# Startup log (default mode, valid references):
→ Generating opencode.json from template...
  ✓ Model catalog: 15 models injected
  ✓ Config written to /root/.config/opencode/opencode.json
  ✓ oh-my-opencode-slim.json refreshed from template
  ✓ oh-my-opencode-slim: 10/10 unique model refs in catalog

# Startup log (runtime validation, some models unavailable):
  ⚠ oh-my-opencode-slim references models not in runtime catalog:
      gpt-5.4-mini
      claude-opus-4-7
    These models are not available from the gateway.
    Agent roles may fail at runtime if no valid fallback exists.
  ✓ oh-my-opencode-slim: 8/10 unique model refs in catalog
    Not in catalog: gpt-5.4-mini,claude-opus-4-7

# Startup log (strict mode, invalid reference):
  ✗ FATAL: oh-my-opencode-slim references models not in static catalog:
      nonexistent-model
    These models do not exist in templates/model-catalog.json.
    Update the catalog or fix the plugin template.
  ✗ FATAL: oh-my-opencode-slim validation failed (CODEBOX_STRICT_MODEL_REFS=true)
# Container exits with code 1
```

## Diagnostic Report

The `_report_plugin_model_status()` function prints a summary during startup:

```bash
# All valid:
  ✓ oh-my-opencode-slim: 10/10 unique model refs in catalog

# Some invalid:
  ✓ oh-my-opencode-slim: 8/10 unique model refs in catalog
    Not in catalog: model-x,model-y
```

This report uses the **post-discovery catalog** when gateway is configured, showing which models are actually usable at runtime.

## Developer Workflow

### Adding a New Model

1. Add model entry to `templates/model-catalog.json`
2. Update `oh-my-opencode-slim.json.template` to reference it
3. Validate: `./scripts/verify-plugin-models.sh`
4. Validate full catalog: `./scripts/verify-model-catalog.sh`
5. Test validation functions: `./scripts/test-plugin-model-validation.sh`
6. Restart container: `./codebox.sh restart codebox`

### Removing a Model

1. Remove from `oh-my-opencode-slim.json.template` role definitions
2. Optionally remove from `model-catalog.json` (if no longer supported)
3. Validate as above

### Testing with Invalid References

```bash
# Edit template to add invalid reference
echo '  "test-role": {"model": "llm/invalid-test"},' >> templates/oh-my-opencode-slim.json.template

# Verify detection (should fail):
./scripts/verify-plugin-models.sh

# Test strict mode in container:
CODEBOX_STRICT_MODEL_REFS=true ./codebox.sh restart codebox
# Should fail to start with validation error

# Revert:
git checkout templates/oh-my-opencode-slim.json.template
```

## Implementation Details

### Functions in `lib/config.sh`

#### `_extract_plugin_model_refs(plugin_file)`
- Extracts all model references from plugin config
- Handles both single models and fallback arrays
- Strips `llm/` provider prefix for catalog matching
- Returns newline-separated sorted unique list

#### `_validate_plugin_models(plugin_file, catalog_json, phase)`
- Validates plugin references against catalog
- Args:
  - `plugin_file`: Path to oh-my-opencode-slim config
  - `catalog_json`: Catalog JSON string (full or filtered)
  - `phase`: "static" or "runtime" (affects error messages)
- Returns:
  - `0`: Valid or warnings only
  - `1`: Invalid refs found and `CODEBOX_STRICT_MODEL_REFS=true`

#### `_report_plugin_model_status(plugin_file, catalog_json)`
- Generates diagnostic summary
- Prints valid/total counts
- Lists invalid references (comma-separated)

### Validation Flow

```
Container Startup
    ↓
lib/config.sh:_configure_opencode()
    ↓
_generate_config() → Gateway discovery → Catalog filtering
    ↓
Copy plugin template to active config
    ↓
Phase 1: _validate_plugin_models(config, full_catalog, "static")
    ├─ Invalid refs? → Warn or fail based on CODEBOX_STRICT_MODEL_REFS
    └─ Continue
    ↓
Phase 2: _validate_plugin_models(config, runtime_catalog, "runtime")
    ├─ Gateway unavailable models? → Warn or fail
    └─ Continue
    ↓
_report_plugin_model_status(config, runtime_catalog)
    ↓
Continue with auth.json, agent startup
```

## Edge Cases

### Bind-Mounted Plugin Config

When the user bind-mounts their own `oh-my-opencode-slim.json`:
```yaml
volumes:
  - ./my-plugin-config.json:/root/.config/opencode/oh-my-opencode-slim.json
```

Validation **still runs** against the bind-mounted file:
- Static validation: against full catalog
- Runtime validation: against discovered/filtered catalog
- Warnings/errors appear in startup logs

### No Gateway Configured

When `LLM_BASE_URL` is unset:
- Static validation runs normally
- Runtime validation uses the **full catalog** (no filtering)
- All catalog models are considered "available"

### Gateway Required Mode

When `CODEBOX_REQUIRE_LLM_GATEWAY=true` and gateway is unreachable:
- Catalog retrieval fails before plugin validation
- Container exits before reaching plugin validation

### Empty Plugin Config

When plugin has no model references:
- Validation returns `0` (success)
- Startup log: "oh-my-opencode-slim: no model references found"

### Empty Catalog

When the catalog is empty (gateway returns zero models, or catalog file has `{"models": []}`):
- All model references are treated as invalid
- **Non-strict mode** (default): Warns about invalid references but returns success (exit 0)
  ```
  ⚠ oh-my-opencode-slim: N invalid model reference(s) in runtime catalog:
      model-a
      model-b
    These models are not available from the gateway.
  ```
- **Strict mode** (`CODEBOX_STRICT_MODEL_REFS=true`): Fails validation (exit 1)
  ```
  ✗ FATAL: oh-my-opencode-slim: N invalid model reference(s) in runtime catalog:
      model-a
      model-b
  ✗ FATAL: oh-my-opencode-slim runtime validation failed
  ```

**Production safeguard**: `_get_catalog_for_agent()` in `lib/config.sh` always falls back to the full catalog when gateway discovery fails or returns empty, so runtime validation never sees an empty catalog in normal operation. However, the validation functions correctly handle the edge case if called directly.

## Pi Subagent Model Pins

**Pi subagents are NOT validated** by this system. They are:
- Defined in separate files (`templates/pi-subagents/*.json`)
- Seeded at first boot only (if absent)
- Separately editable by users
- Outside the plugin's preset/council structure

Pi subagent model validation is a separate concern, handled by Pi's own config validation at agent startup.

## Relation to Existing Validation

### `scripts/verify-model-catalog.sh`

Validates the catalog itself:
- Required fields present
- No duplicate IDs
- Claude models pinned to `anthropic-messages`
- Gateway routing invariants
- Optional live gateway ID check

This script validates the **catalog structure**. `verify-plugin-models.sh` validates **consumer references**.

### `scripts/test-model-discovery.sh`

Tests gateway discovery logic:
- Cache behavior
- Filtering
- Fallback to full catalog
- Strict gateway mode

Plugin validation **consumes** the discovered catalog but does not test discovery itself.

## Troubleshooting

### Warning: "references models not in runtime catalog"

**Cause**: Gateway does not offer models referenced in plugin config

**Impact**: Agent roles may fail if their primary model is unavailable and all fallbacks are also missing

**Solutions**:
1. Check gateway `/v1/models` endpoint: `curl -H "Authorization: Bearer $LLM_API_KEY" $LLM_BASE_URL/v1/models`
2. Update plugin config to reference available models
3. Add missing models to gateway
4. Set `LLM_BASE_URL=` (empty) to disable gateway and use full catalog

### Error: "FATAL: oh-my-opencode-slim validation failed"

**Cause**: `CODEBOX_STRICT_MODEL_REFS=true` and invalid references found

**Impact**: Container startup fails

**Solutions**:
1. Fix invalid references in `oh-my-opencode-slim.json.template`
2. Add missing models to `model-catalog.json`
3. Set `CODEBOX_STRICT_MODEL_REFS=false` to demote to warnings (not recommended for production)

### Models in catalog but not in gateway

This is **expected** when:
- Gateway is a subset of provider capabilities
- Testing with dev/staging gateway
- Provider gradually rolls out new models

Runtime validation warns but allows startup. Agent roles fall back to next model in their array.

To fail instead: `CODEBOX_STRICT_MODEL_REFS=true`

## Future Enhancements

Potential additions (not currently implemented):

- **Pi subagent validation**: Extend to validate `templates/pi-subagents/*.json` model references
- **Cross-agent consistency**: Warn when Pi subagent defaults don't align with plugin presets
- **Fallback chain analysis**: Detect roles with zero valid fallbacks after discovery
- **Model capability checks**: Warn when role requires reasoning/vision but model lacks it
- **Cost estimation**: Report total cost exposure for all referenced models
