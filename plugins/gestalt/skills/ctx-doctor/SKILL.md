---
name: ctx-doctor
description: Diagnose context-mode runtime, dependency, spawned MCP handshake, hook, FTS5, plugin registration, version, and startup problems. Trigger when the user invokes ctx-doctor or reports that context-mode is missing, unhealthy, or failing to start.
---

# Context Mode Doctor

1. Call `ctx_doctor` and return its complete status report unchanged.
2. Preserve its `[OK]`, `[FAIL]`, and `[WARN]` prefixes.
3. If the MCP call fails, derive the Gestalt plugin root by going two
   directories up from this skill and run its external-runtime bridge:

```sh
node "<PLUGIN_ROOT>/scripts/ctx-doctor.mjs"
```

Report the fallback command, exit status, and complete diagnostic report.
