import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { basename, isAbsolute, resolve } from "node:path";

export interface McpProbeLaunch {
  command: string;
  args: string[];
  label: string;
}

export interface McpHandshakeResult {
  ok: boolean;
  detail: string;
}

interface JsonRpcResponse {
  id?: number;
  result?: {
    serverInfo?: { name?: string };
    tools?: Array<{ name?: string }>;
  };
  error?: { code?: number; message?: string };
}

const PROTOCOL_VERSION = "2024-11-05";
const STDERR_LIMIT = 400;

/**
 * Resolve the launcher a newly spawned executor would use. In a running Codex
 * MCP process, argv[1] is the configured context-mode bridge, so replay it
 * exactly. Source/package doctors fall back to the package launcher or bundle.
 */
export function resolveMcpProbeLaunch(
  pluginRoot: string,
  argv1 = process.argv[1],
): McpProbeLaunch | null {
  if (
    argv1 &&
    isAbsolute(argv1) &&
    basename(argv1) === "context-mode-mcp.mjs" &&
    existsSync(argv1)
  ) {
    return { command: process.execPath, args: [argv1], label: argv1 };
  }

  for (const candidate of [
    resolve(pluginRoot, "start.mjs"),
    resolve(pluginRoot, "server.bundle.mjs"),
    resolve(pluginRoot, "build", "server.js"),
  ]) {
    if (existsSync(candidate)) {
      return { command: process.execPath, args: [candidate], label: candidate };
    }
  }
  return null;
}

function compactStderr(stderr: string): string {
  return stderr.replace(/\s+/g, " ").trim().slice(0, STDERR_LIMIT);
}

function terminateChild(child: ChildProcessWithoutNullStreams): void {
  if (child.exitCode !== null || child.signalCode !== null) return;
  try { child.kill("SIGTERM"); } catch { return; }
  const forceKill = setTimeout(() => {
    if (child.exitCode === null && child.signalCode === null) {
      try { child.kill("SIGKILL"); } catch { /* best effort */ }
    }
  }, 500);
  forceKill.unref();
}

/**
 * Spawn a fresh MCP server and complete the same initialize -> initialized ->
 * tools/list exchange used by executor sessions. Never calls ctx_doctor in the
 * child, avoiding recursive diagnostics.
 */
export function probeMcpHandshake(
  launch: McpProbeLaunch,
  timeoutMs = 8_000,
): Promise<McpHandshakeResult> {
  return new Promise((resolveResult) => {
    let child: ChildProcessWithoutNullStreams;
    try {
      child = spawn(launch.command, launch.args, {
        stdio: ["pipe", "pipe", "pipe"],
        env: {
          ...process.env,
          CONTEXT_MODE_DISABLE_VERSION_CHECK: "1",
        },
      });
    } catch (error) {
      resolveResult({ ok: false, detail: `could not spawn ${launch.label}: ${error instanceof Error ? error.message : String(error)}` });
      return;
    }

    let settled = false;
    let phase: "initialize" | "tools/list" = "initialize";
    let stdout = "";
    let stderr = "";
    let timeout: ReturnType<typeof setTimeout>;

    const finish = (result: McpHandshakeResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      terminateChild(child);
      resolveResult(result);
    };

    const failureDetail = (reason: string) => {
      const diagnostic = compactStderr(stderr);
      return diagnostic ? `${reason} — ${diagnostic}` : reason;
    };

    child.stderr.on("data", (chunk: Buffer) => {
      if (stderr.length < STDERR_LIMIT * 2) stderr += chunk.toString("utf8");
    });

    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
      let newline: number;
      while ((newline = stdout.indexOf("\n")) >= 0) {
        const line = stdout.slice(0, newline).trim();
        stdout = stdout.slice(newline + 1);
        if (!line) continue;
        let response: JsonRpcResponse;
        try { response = JSON.parse(line) as JsonRpcResponse; } catch { continue; }

        if (response.id === 1 && phase === "initialize") {
          if (response.error) {
            finish({ ok: false, detail: failureDetail(`initialize error: ${response.error.message ?? response.error.code ?? "unknown"}`) });
            return;
          }
          if (response.result?.serverInfo?.name !== "context-mode") {
            finish({ ok: false, detail: failureDetail("initialize returned unexpected server identity") });
            return;
          }
          phase = "tools/list";
          child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
          child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list" }) + "\n");
          continue;
        }

        if (response.id === 2 && phase === "tools/list") {
          if (response.error) {
            finish({ ok: false, detail: failureDetail(`tools/list error: ${response.error.message ?? response.error.code ?? "unknown"}`) });
            return;
          }
          const names = response.result?.tools?.map((tool) => tool.name) ?? [];
          if (!names.includes("ctx_doctor")) {
            finish({ ok: false, detail: failureDetail("tools/list omitted ctx_doctor") });
            return;
          }
          finish({ ok: true, detail: "initialize + tools/list passed (ctx_doctor available)" });
          return;
        }
      }
    });

    child.on("error", (error) => {
      finish({ ok: false, detail: failureDetail(`spawn error: ${error.message}`) });
    });
    child.stdin.on("error", (error) => {
      finish({ ok: false, detail: failureDetail(`stdin closed during ${phase}: ${error.message}`) });
    });
    child.on("close", (code, signal) => {
      if (!settled) {
        const status = signal ? `signal ${signal}` : `exit ${code ?? "unknown"}`;
        finish({ ok: false, detail: failureDetail(`connection closed during ${phase} (${status})`) });
      }
    });

    timeout = setTimeout(() => {
      finish({ ok: false, detail: failureDetail(`timed out during ${phase} after ${timeoutMs}ms`) });
    }, timeoutMs);

    child.stdin.write(JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: "ctx-doctor-spawn-probe", version: "1.0" },
      },
    }) + "\n");
  });
}
