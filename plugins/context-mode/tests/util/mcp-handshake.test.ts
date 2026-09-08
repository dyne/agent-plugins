import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { describe, expect, test } from "vitest";
import {
  probeMcpHandshake,
  resolveMcpProbeLaunch,
  type McpProbeLaunch,
} from "../../src/util/mcp-handshake.js";

function nodeScript(source: string): McpProbeLaunch {
  return { command: process.execPath, args: ["-e", source], label: "test fixture" };
}

const successfulServer = String.raw`
let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
    if (!line.trim()) continue;
    const request = JSON.parse(line);
    if (request.method === "initialize") {
      process.stdout.write(JSON.stringify({jsonrpc:"2.0",id:request.id,result:{protocolVersion:"2024-11-05",capabilities:{tools:{}},serverInfo:{name:"context-mode",version:"test"}}}) + "\n");
    }
    if (request.method === "tools/list") {
      process.stdout.write(JSON.stringify({jsonrpc:"2.0",id:request.id,result:{tools:[{name:"ctx_doctor"}]}}) + "\n");
    }
  }
});
`;

describe("spawned MCP handshake probe", () => {
  test("completes initialize and tools/list", async () => {
    const result = await probeMcpHandshake(nodeScript(successfulServer), 2_000);

    expect(result).toEqual({
      ok: true,
      detail: "initialize + tools/list passed (ctx_doctor available)",
    });
  });

  test("reports a child that closes during initialize with bounded stderr", async () => {
    const result = await probeMcpHandshake(nodeScript(`
      process.stdin.once("data", () => {
        process.stderr.write("fixture initialization failed\\n");
        process.exit(23);
      });
    `), 2_000);

    expect(result.ok).toBe(false);
    expect(result.detail).toContain("connection closed during initialize (exit 23)");
    expect(result.detail).toContain("fixture initialization failed");
  });

  test("reports the handshake phase on timeout", async () => {
    const result = await probeMcpHandshake(nodeScript(`
      process.stdin.resume();
      setInterval(() => {}, 1000);
    `), 100);

    expect(result).toEqual({
      ok: false,
      detail: "timed out during initialize after 100ms",
    });
  });

  test("prefers the configured Codex bridge over package fallbacks", () => {
    const fixtureRoot = mkdtempSync(join(tmpdir(), "ctx-handshake-resolver-"));
    const bridge = join(fixtureRoot, "context-mode-mcp.mjs");
    writeFileSync(bridge, "// fixture\n");

    try {
      const launch = resolveMcpProbeLaunch(resolve(import.meta.dirname, "..", ".."), bridge);

      expect(launch).toEqual({ command: process.execPath, args: [bridge], label: bridge });
    } finally {
      rmSync(fixtureRoot, { recursive: true, force: true });
    }
  });
});
