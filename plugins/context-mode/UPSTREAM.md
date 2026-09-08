# context-mode origin and downstream changes

- Upstream repository: https://github.com/mksglu/context-mode
- Upstream branch: `codex-hardening`
- Imported commit: `4b1348d4bba530d26cfc73181a0c2f263923e334`
- Describe: `v1.0.169-56-g4b1348d`
- Upstream package version: `1.0.169`
- Downstream package version: `2.7.1`
- License: Elastic-2.0
- Import date: 2026-07-22

This is an attributed Codex-focused adaptation, not an exact copy. The
repository checksum fixture records the adapted source files, executable modes,
and contents while excluding generated dependencies and build artifacts.

## Downstream changes

- Retains only Codex plugin manifests, configuration, hook entrypoints, and
  user-facing documentation. Other host packaging, configuration, hook
  wrappers, website content, and release automation are omitted.
- Replaces the self-healing first-run launcher with a small `start.mjs` that
  resolves a versioned external runtime, performs a read-only artifact
  preflight, and starts its `server.bundle.mjs`.
- Adds `scripts/prepare-runtime.mjs` for explicit locked dependency install,
  type-checking, bundle creation, validation, and preparation-manifest creation.
- Adds an atomic external-runtime installer under
  `${GESTALT_HOME:-$HOME/.gestalt}`, isolated by platform, architecture, and
  Node ABI. It canonicalizes CLI entrypoint paths so symlinked marketplace or
  temporary directories still run preparation. This avoids dependence on
  Codex's replaceable plugin cache.
- Routes Codex hooks through a cache-local launcher into the external runtime.
- Adds an idempotent Codex integration reconciler. Marketplace setup and a
  legacy plugin `SessionStart` hook repair native MCP registration, stable-hook
  enablement, user-level hook launchers, and incomplete older installations
  while preserving unrelated TOML and JSON entries.
- Disables the plugin manifest contribution after installing its package and
  registers a native workspace-inheriting MCP launcher instead. This works
  around current Codex builds omitting session/workspace variables from plugin
  MCP child environments without starting duplicate servers or hooks.
- Treats Codex stable hooks as enabled when no explicit feature override exists,
  and recognizes the context-mode plugin under any Codex marketplace name.
- Validates plugin-provided hooks at Codex's conventional `hooks/hooks.json`
  path and accepts version-matched external-runtime and marketplace roots.
- Rejects Bun commands that exist on disk or PATH but fail a version probe,
  preventing broken package-manager shims from being selected for execution.
- Recovers a missing `CODEX_HOME` from Codex's installed plugin-cache path so
  MCP diagnostics, storage, and hooks stay inside the selected profile.
  MCP and hook entrypoints never build or repair the package.
- Moves the eight rewritten routing and command skills into the Gestalt plugin,
  giving Codex one provider for skill listing and enable/disable controls.
- Removes upstream self-update as a supported Gestalt repair path. Local repair
  may only use the versioned package shipped by this repository; the Codex
  integration reconciler rejects non-versioned or package-version-mismatched
  cache roots so test fixtures cannot replace the live MCP launcher.
- Keeps the upstream TypeScript adapter registry for now because server and CLI
  compilation share it. It is implementation residue, not a supported-host
  promise; extracting a Codex-only core is a separate architectural change.

## Updating context-mode

Import a reviewed upstream revision, reapply the Codex-only changes above,
choose a distinct downstream package version, regenerate the checksum fixture,
and run `bash tests/run.sh` plus `git diff --check`.
