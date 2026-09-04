import { afterEach, describe, expect, it } from "vitest";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createCLIRunner } from "../../lib/cli-runner.js";

describe("Calendar helper routing", () => {
  let binDir;

  afterEach(() => {
    if (binDir) rmSync(binDir, { recursive: true, force: true });
  });

  it.each(["writeOnly", "restricted", "unknown", "futureAuthorizationState"])("routes %s calendar access through the helper without a direct read", async (authorization) => {
    binDir = mkdtempSync(join(tmpdir(), "apple-pim-write-only-"));
    const calendarCLI = join(binDir, "calendar-cli");
    writeFileSync(calendarCLI, "#!/bin/sh\n");
    chmodSync(calendarCLI, 0o755);

    const directCalls = [];
    const helperCalls = [];
    const { runCLI } = createCLIRunner(binDir, {}, {
      helperExists: () => true,
      runDirectImpl: async (cliPath, args) => {
        directCalls.push({ cliPath, args });
        if (args[0] !== "auth-status") {
          throw new Error("calendar read attempted directly");
        }
        return { authorization };
      },
      runViaHelperImpl: async (cli, args, env, timeoutMs) => {
        helperCalls.push({ cli, args, timeoutMs });
        return { events: [] };
      },
    });

    await expect(runCLI("calendar-cli", ["events"])).resolves.toEqual({ events: [] });
    expect(directCalls).toEqual([{ cliPath: calendarCLI, args: ["auth-status"] }]);
    expect(helperCalls).toEqual([{ cli: "calendar-cli", args: ["events"], timeoutMs: authorization === "writeOnly" ? 120_000 : 30_000 }]);
    await expect(runCLI("calendar-cli", ["events"])).resolves.toEqual({ events: [] });
    expect(helperCalls[1].timeoutMs).toBe(30_000);
    expect(directCalls).toHaveLength(1);
  });

  it.each(["authorized", "fullAccess"])("keeps %s calendar reads direct", async (authorization) => {
    binDir = mkdtempSync(join(tmpdir(), "apple-pim-full-access-"));
    const calendarCLI = join(binDir, "calendar-cli");
    writeFileSync(calendarCLI, "#!/bin/sh\n");
    chmodSync(calendarCLI, 0o755);
    const directCalls = [];
    const { runCLI } = createCLIRunner(binDir, {}, {
      helperExists: () => true,
      runDirectImpl: async (cliPath, args) => {
        directCalls.push(args);
        return args[0] === "auth-status" ? { authorization } : { events: [] };
      },
      runViaHelperImpl: async () => { throw new Error("authorized read attempted through helper"); },
    });
    await expect(runCLI("calendar-cli", ["events"])).resolves.toEqual({ events: [] });
    expect(directCalls).toEqual([["auth-status"], ["events"]]);
  });

});
