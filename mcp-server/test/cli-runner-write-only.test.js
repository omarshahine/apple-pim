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

  it("routes writeOnly calendar access through the helper without a direct read", async () => {
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
        return { authorization: "writeOnly" };
      },
      runViaHelperImpl: async (cli, args) => {
        helperCalls.push({ cli, args });
        return { events: [] };
      },
    });

    await expect(runCLI("calendar-cli", ["events"])).resolves.toEqual({ events: [] });
    expect(directCalls).toEqual([{ cliPath: calendarCLI, args: ["auth-status"] }]);
    expect(helperCalls).toEqual([{ cli: "calendar-cli", args: ["events"] }]);
  });
});
