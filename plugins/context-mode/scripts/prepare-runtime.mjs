#!/usr/bin/env node
/** Prepare immutable context-mode runtime artifacts before Codex starts MCP. */
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  REQUIRED_FILES,
  verifyPreparedRuntime,
} from "./runtime-preflight.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_PLUGIN_ROOT = resolve(SCRIPT_DIR, "..");
const MANIFEST = ".context-mode-prepared.json";
const WAIT_MS = 250;
const WAIT_TIMEOUT_MS = 180_000;
const STALE_LOCK_MS = 300_000;

const delay = (ms) => new Promise((done) => setTimeout(done, ms));
function findBun() {
  const selection = process.env.CONTEXT_MODE_PACKAGE_MANAGER ?? "auto";
  if (!new Set(["auto", "bun", "npm"]).has(selection)) {
    throw new Error(`CONTEXT_MODE_PACKAGE_MANAGER must be auto, bun, or npm; found ${selection}`);
  }
  if (selection === "npm") return null;
  if (typeof globalThis.Bun !== "undefined") return process.execPath;
  const candidates = [
    process.env.BUN_INSTALL ? join(process.env.BUN_INSTALL, "bin", "bun") : null,
    join(homedir(), ".bun", "bin", "bun"),
    "/usr/local/bin/bun",
    "/usr/bin/bun",
  ].filter(Boolean);
  const bun = candidates.find((candidate) => {
    if (!existsSync(candidate)) return false;
    try {
      execFileSync(candidate, ["--version"], {
        stdio: "ignore",
        timeout: 1_000,
        windowsHide: true,
      });
      return true;
    } catch {
      return false;
    }
  }) ?? null;
  if (selection === "bun" && !bun) {
    throw new Error("CONTEXT_MODE_PACKAGE_MANAGER=bun but no working Bun executable was found");
  }
  return bun;
}

function run(pluginRoot, tempDir, command, args, timeout = WAIT_TIMEOUT_MS) {
  mkdirSync(tempDir, { recursive: true });
  execFileSync(command, args, {
    cwd: pluginRoot,
    env: {
      ...process.env,
      TMPDIR: tempDir,
      TMP: tempDir,
      TEMP: tempDir,
      BUN_INSTALL_CACHE_DIR: join(tempDir, "bun-cache"),
      npm_config_cache: join(tempDir, "npm-cache"),
    },
    stdio: "inherit",
    timeout,
    windowsHide: true,
    shell: process.platform === "win32" && command.endsWith(".cmd"),
  });
}

function installBuildDependencies(pluginRoot, tempDir) {
  const bun = findBun();
  if (bun) {
    run(pluginRoot, tempDir, bun, ["install", "--frozen-lockfile"]);
    return;
  }
  run(
    pluginRoot,
    tempDir,
    process.platform === "win32" ? "npm.cmd" : "npm",
    ["ci", "--no-audit", "--no-fund"],
  );
}

function buildRuntimeArtifacts(pluginRoot, tempDir) {
  installBuildDependencies(pluginRoot, tempDir);
  const npm = process.platform === "win32" ? "npm.cmd" : "npm";
  run(pluginRoot, tempDir, npm, ["exec", "--", "tsc", "--noEmit"]);
  run(pluginRoot, tempDir, npm, ["run", "bundle", "--silent"]);
  run(pluginRoot, tempDir, npm, ["run", "assert-bundle", "--silent"]);
}

function verifyNativeDependencies(pluginRoot) {
  const require = createRequire(join(pluginRoot, "package.json"));
  const Database = require("better-sqlite3");
  const database = new Database(":memory:");
  database.close();
}

function writeManifest(pluginRoot) {
  const packageVersion = JSON.parse(readFileSync(join(pluginRoot, "package.json"), "utf8")).version;
  const files = {};
  for (const relative of REQUIRED_FILES) {
    const absolute = join(pluginRoot, relative);
    if (!existsSync(absolute)) throw new Error(`prepared runtime is missing ${relative}`);
    files[relative] = createHash("sha256").update(readFileSync(absolute)).digest("hex");
  }
  writeFileSync(
    join(pluginRoot, MANIFEST),
    JSON.stringify({
      schemaVersion: 2,
      packageVersion,
      preparedAt: new Date().toISOString(),
      node: process.versions.node,
      nodeModulesAbi: process.versions.modules,
      platform: process.platform,
      arch: process.arch,
      bun: process.versions.bun ?? null,
      files,
    }, null, 2) + "\n",
  );
}

function removeStaleLock(lockDir, ownerPath, recoveryDir) {
  try {
    mkdirSync(recoveryDir);
  } catch (error) {
    if (error?.code === "EEXIST") return;
    throw error;
  }
  try {
    const ownerPid = Number.parseInt(readFileSync(ownerPath, "utf8"), 10);
    let ownerAlive = Number.isInteger(ownerPid) && ownerPid > 0;
    if (ownerAlive) {
      try { process.kill(ownerPid, 0); } catch (error) { ownerAlive = error?.code !== "ESRCH"; }
    }
    if (!ownerAlive || Date.now() - statSync(lockDir).mtimeMs > STALE_LOCK_MS) {
      rmSync(lockDir, { recursive: true, force: true });
    }
  } catch {
    // Another preparer may have released the lock.
  } finally {
    rmSync(recoveryDir, { recursive: true, force: true });
  }
}

export async function prepareRuntime(pluginRoot = DEFAULT_PLUGIN_ROOT, { force = false } = {}) {
  const lockDir = join(pluginRoot, ".context-mode-prepare.lock");
  const ownerPath = join(lockDir, "owner.pid");
  const recoveryDir = join(pluginRoot, ".context-mode-prepare.recovery.lock");
  const tempDir = join(pluginRoot, ".context-mode-prepare-tmp");
  if (!force && verifyPreparedRuntime(pluginRoot).ok) return;

  const deadline = Date.now() + WAIT_TIMEOUT_MS;
  while (Date.now() < deadline) {
    let ownsLock = false;
    try {
      mkdirSync(lockDir);
      writeFileSync(ownerPath, `${process.pid}\n`);
      ownsLock = true;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      removeStaleLock(lockDir, ownerPath, recoveryDir);
    }

    if (ownsLock) {
      try {
        if (force || !verifyPreparedRuntime(pluginRoot).ok) {
          buildRuntimeArtifacts(pluginRoot, tempDir);
          verifyNativeDependencies(pluginRoot);
          writeManifest(pluginRoot);
        }
      } finally {
        rmSync(tempDir, { recursive: true, force: true });
        rmSync(lockDir, { recursive: true, force: true });
      }
      const result = verifyPreparedRuntime(pluginRoot);
      if (!result.ok) throw new Error(`preparation incomplete: ${result.problems.join(", ")}`);
      return;
    }

    if (verifyPreparedRuntime(pluginRoot).ok) return;
    await delay(WAIT_MS);
  }
  throw new Error(`timed out waiting for preparation lock: ${lockDir}`);
}

if (
  process.argv[1] &&
  realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))
) {
  const checkOnly = process.argv.includes("--check");
  const force = process.argv.includes("--force");
  if (checkOnly) {
    const result = verifyPreparedRuntime(DEFAULT_PLUGIN_ROOT);
    if (!result.ok) {
      process.stderr.write(`context-mode is not prepared: ${result.problems.join(", ")}\n`);
      process.exit(1);
    }
  } else {
    await prepareRuntime(DEFAULT_PLUGIN_ROOT, { force });
  }
  process.stdout.write(`context-mode prepared: ${DEFAULT_PLUGIN_ROOT}\n`);
}
