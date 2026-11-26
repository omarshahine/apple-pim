import { afterEach, describe, expect, it } from "vitest";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { canReadRemindersStore, createCLIRunner } from "../../lib/cli-runner.js";

// reminder-cli's auth-status reports `authorization` (EventKit) and `remindersStore.readable`
// (whether this process can read the Reminders database, i.e. Full Disk Access). Sections,
// subtasks, tags and the private-write readback all need the database.
describe("canReadRemindersStore", () => {
  it.each(["authorized", "fullAccess"])("is true when %s and the store is readable", (authorization) => {
    expect(canReadRemindersStore({ authorization, remindersStore: { readable: true } })).toBe(true);
  });

  it("is false for an older reminder-cli that reports no store", () => {
    expect(canReadRemindersStore({ authorization: "authorized" })).toBe(false);
  });

  it("is false for unknown shapes rather than failing open", () => {
    for (const status of [undefined, {}, { remindersStore: { readable: true } },
      { authorization: "authorized", remindersStore: { readable: "yes" } },
      { authorization: "denied", remindersStore: { readable: true } }]) {
      expect(canReadRemindersStore(status)).toBe(false);
    }
  });
});

describe("Reminders store routing", () => {
  let binDir;

  afterEach(() => {
    if (binDir) rmSync(binDir, { recursive: true, force: true });
  });

  function runner({
    host = { authorization: "authorized", remindersStore: { readable: false } },
    helper = { authorization: "authorized", remindersStore: { readable: true } },
    helperRun = async (args) => ({ via: "helper", args }),
  } = {}) {
    binDir = mkdtempSync(join(tmpdir(), "apple-pim-reminder-store-"));
    writeFileSync(join(binDir, "reminder-cli"), "#!/bin/sh\n");
    chmodSync(join(binDir, "reminder-cli"), 0o755);
    const directCalls = [];
    const helperCalls = [];
    const { runCLI } = createCLIRunner(binDir, {}, {
      helperExists: () => true,
      runDirectImpl: async (_path, args) => {
        directCalls.push(args);
        return args[0] === "auth-status" ? host : { via: "direct", args };
      },
      runViaHelperImpl: async (cli, args) => {
        helperCalls.push(args);
        return args[0] === "auth-status" ? helper : helperRun(args);
      },
    });
    return { runCLI, directCalls, helperCalls };
  }

  it("sends metadata reads to a helper that can read the store", async () => {
    const r = runner();
    await expect(r.runCLI("reminder-cli", ["items"])).resolves.toEqual({ via: "helper", args: ["items"] });
    expect(r.directCalls).toEqual([["auth-status"]]);
  });

  it("keeps commands that never read the store direct", async () => {
    const r = runner();
    await expect(r.runCLI("reminder-cli", ["create", "--title", "x"])).resolves.toMatchObject({ via: "direct" });
    expect(r.helperCalls).toEqual([]);
  });

  it("stays direct when the host can read the store", async () => {
    const r = runner({ host: { authorization: "authorized", remindersStore: { readable: true } } });
    await expect(r.runCLI("reminder-cli", ["set-tags", "--private"])).resolves.toMatchObject({ via: "direct" });
    expect(r.helperCalls).toEqual([]);
  });

  it("stays direct when the helper cannot read the store either", async () => {
    const r = runner({ helper: { authorization: "authorized", remindersStore: { readable: false } } });
    await expect(r.runCLI("reminder-cli", ["items"])).resolves.toMatchObject({ via: "direct" });
  });

  it("retries a failed helper read direct", async () => {
    const r = runner({ helperRun: async () => { throw new Error("helper broke"); } });
    await expect(r.runCLI("reminder-cli", ["get", "--id", "X"])).resolves.toMatchObject({ via: "direct" });
  });

  it("never retries a failed private write direct", async () => {
    const r = runner({ helperRun: async () => { throw new Error("verification failed"); } });
    await expect(r.runCLI("reminder-cli", ["set-flag", "--id", "X", "--private"])).rejects.toThrow("verification failed");
    expect(r.directCalls).toEqual([["auth-status"]]);
  });
});
