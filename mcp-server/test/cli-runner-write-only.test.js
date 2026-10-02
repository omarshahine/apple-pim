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

  // Availability reads (events, get, search) may read the local Calendar store, which needs
  // Full Disk Access. The default host has Calendar access but not the store; the default
  // helper has both.
  function storeRunner({
    host = { authorization: "authorized", calendarStore: { readable: false } },
    helper = { authorization: "authorized", calendarStore: { readable: true } },
    helperRead = async (args) => ({ via: "helper", args }),
    helperExists = () => true,
    dir,
  } = {}) {
    // The helper's store answer is cached per binDir for the process; a fresh dir
    // per runner keeps tests apart, and passing one shares that cache.
    if (!dir) {
      binDir = mkdtempSync(join(tmpdir(), "apple-pim-store-read-"));
      writeFileSync(join(binDir, "calendar-cli"), "#!/bin/sh\n");
      chmodSync(join(binDir, "calendar-cli"), 0o755);
    }
    const calendarCLI = join(dir ?? binDir, "calendar-cli");
    const directCalls = [];
    const helperCalls = [];
    const { runCLI } = createCLIRunner(dir ?? binDir, {}, {
      helperExists,
      runDirectImpl: async (cliPath, args, env, timeoutMs) => {
        expect(cliPath).toBe(calendarCLI);
        directCalls.push({ args, timeoutMs });
        if (args[0] !== "auth-status") return { via: "direct", args };
        if (host instanceof Error) throw host;
        return host;
      },
      runViaHelperImpl: async (cli, args, env, timeoutMs) => {
        expect(cli).toBe("calendar-cli");
        helperCalls.push({ args, timeoutMs });
        if (args[0] !== "auth-status") return helperRead(args);
        if (helper instanceof Error) throw helper;
        return helper;
      },
    });
    return { runCLI, directCalls, helperCalls, binDir: dir ?? binDir };
  }

  it("sends only availability reads to a helper that can read the store this host cannot", async () => {
    const { runCLI, directCalls, helperCalls } = storeRunner();
    await expect(runCLI("calendar-cli", ["events"])).resolves.toEqual({ via: "helper", args: ["events"] });
    await expect(runCLI("calendar-cli", ["create", "--title", "x"])).resolves.toEqual({ via: "direct", args: ["create", "--title", "x"] });
    await expect(runCLI("calendar-cli", ["list"])).resolves.toEqual({ via: "direct", args: ["list"] });
    await expect(runCLI("calendar-cli", ["get", "--id", "e1"])).resolves.toEqual({ via: "helper", args: ["get", "--id", "e1"] });
    await expect(runCLI("calendar-cli", ["search", "x"])).resolves.toEqual({ via: "helper", args: ["search", "x"] });
    expect(directCalls).toEqual([
      { args: ["auth-status"], timeoutMs: 30_000 },
      { args: ["create", "--title", "x"], timeoutMs: 30_000 },
      { args: ["list"], timeoutMs: 30_000 },
    ]);
    expect(helperCalls).toEqual([
      { args: ["auth-status"], timeoutMs: 30_000 },
      { args: ["events"], timeoutMs: 30_000 },
      { args: ["get", "--id", "e1"], timeoutMs: 30_000 },
      { args: ["search", "x"], timeoutMs: 30_000 },
    ]);
  });

  it.each([
    ["notDetermined", { authorization: "notDetermined" }],
    ["denied", { authorization: "denied" }],
    ["authorized without the store", { authorization: "authorized", calendarStore: { readable: false } }],
    ["authorized with no calendarStore", { authorization: "authorized" }],
  ])("keeps availability reads direct when the helper is %s", async (_, helper) => {
    const { runCLI, directCalls, helperCalls } = storeRunner({ helper });
    await expect(runCLI("calendar-cli", ["events"])).resolves.toEqual({ via: "direct", args: ["events"] });
    await expect(runCLI("calendar-cli", ["events"])).resolves.toEqual({ via: "direct", args: ["events"] });
    expect(directCalls).toEqual([
      { args: ["auth-status"], timeoutMs: 30_000 },
      { args: ["events"], timeoutMs: 30_000 },
      { args: ["events"], timeoutMs: 30_000 },
    ]);
    expect(helperCalls).toEqual([{ args: ["auth-status"], timeoutMs: 30_000 }]);
  });

  it("keeps availability reads direct when the helper probe fails", async () => {
    const { runCLI, directCalls, helperCalls } = storeRunner({ helper: new Error("Helper exited with code 1") });
    await expect(runCLI("calendar-cli", ["events"])).resolves.toEqual({ via: "direct", args: ["events"] });
    expect(directCalls).toEqual([
      { args: ["auth-status"], timeoutMs: 30_000 },
      { args: ["events"], timeoutMs: 30_000 },
    ]);
    expect(helperCalls).toEqual([{ args: ["auth-status"], timeoutMs: 30_000 }]);
  });

  it("runs calendar direct without any probe when the helper is not installed", async () => {
    const { runCLI, directCalls, helperCalls } = storeRunner({ helperExists: () => false });
    await expect(runCLI("calendar-cli", ["events"])).resolves.toEqual({ via: "direct", args: ["events"] });
    expect(directCalls).toEqual([{ args: ["events"], timeoutMs: 30_000 }]);
    expect(helperCalls).toEqual([]);
  });

  it("shares one helper probe between concurrent first availability reads", async () => {
    const { runCLI, directCalls, helperCalls } = storeRunner();
    await expect(Promise.all([
      runCLI("calendar-cli", ["events"]),
      runCLI("calendar-cli", ["get", "--id", "e1"]),
    ])).resolves.toEqual([
      { via: "helper", args: ["events"] },
      { via: "helper", args: ["get", "--id", "e1"] },
    ]);
    expect(directCalls).toEqual([{ args: ["auth-status"], timeoutMs: 30_000 }]);
    expect(helperCalls).toEqual([
      { args: ["auth-status"], timeoutMs: 30_000 },
      { args: ["events"], timeoutMs: 30_000 },
      { args: ["get", "--id", "e1"], timeoutMs: 30_000 },
    ]);
  });

  it("shares one helper probe between runners on the same binDir", async () => {
    // The OpenClaw plugin builds a runner per tool call; the helper's answer outlives it.
    const first = storeRunner();
    await expect(first.runCLI("calendar-cli", ["events"])).resolves.toEqual({ via: "helper", args: ["events"] });
    const second = storeRunner({ dir: first.binDir });
    await expect(second.runCLI("calendar-cli", ["events"])).resolves.toEqual({ via: "helper", args: ["events"] });
    // Each runner probes the host itself; only the first asks the helper.
    expect(first.directCalls).toEqual([{ args: ["auth-status"], timeoutMs: 30_000 }]);
    expect(second.directCalls).toEqual([{ args: ["auth-status"], timeoutMs: 30_000 }]);
    expect(first.helperCalls.map((c) => c.args[0])).toEqual(["auth-status", "events"]);
    expect(second.helperCalls.map((c) => c.args[0])).toEqual(["events"]);
  });

  it("probes the helper again after a probe that failed", async () => {
    const first = storeRunner({ helper: new Error("Helper timed out after 30000ms.") });
    await expect(first.runCLI("calendar-cli", ["events"])).resolves.toEqual({ via: "direct", args: ["events"] });
    const second = storeRunner({ dir: first.binDir });
    await expect(second.runCLI("calendar-cli", ["events"])).resolves.toEqual({ via: "helper", args: ["events"] });
    expect(first.helperCalls.map((c) => c.args[0])).toEqual(["auth-status"]);
    expect(second.helperCalls.map((c) => c.args[0])).toEqual(["auth-status", "events"]);
  });

  it("retries a failed helper availability read direct and keeps trying the helper first", async () => {
    const { runCLI, directCalls, helperCalls } = storeRunner({
      helperRead: async () => { throw new Error("Helper exited with code 1"); },
    });
    await expect(runCLI("calendar-cli", ["events"])).resolves.toEqual({ via: "direct", args: ["events"] });
    await expect(runCLI("calendar-cli", ["get", "--id", "e1"])).resolves.toEqual({ via: "direct", args: ["get", "--id", "e1"] });
    expect(directCalls).toEqual([
      { args: ["auth-status"], timeoutMs: 30_000 },
      { args: ["events"], timeoutMs: 30_000 },
      { args: ["get", "--id", "e1"], timeoutMs: 30_000 },
    ]);
    expect(helperCalls).toEqual([
      { args: ["auth-status"], timeoutMs: 30_000 },
      { args: ["events"], timeoutMs: 30_000 },
      { args: ["get", "--id", "e1"], timeoutMs: 30_000 },
    ]);
  });

  it.each(["authorized", "fullAccess"])("never touches the helper when this %s host can read the store", async (authorization) => {
    const { runCLI, directCalls, helperCalls } = storeRunner({
      host: { authorization, calendarStore: { readable: true } },
    });
    await runCLI("calendar-cli", ["events"]);
    await runCLI("calendar-cli", ["get", "--id", "e1"]);
    await runCLI("calendar-cli", ["create", "--title", "x"]);
    expect(directCalls.map((c) => c.args[0])).toEqual(["auth-status", "events", "get", "create"]);
    expect(helperCalls).toEqual([]);
  });

  it.each([
    ["a read", ["events"], ["create", "--title", "x"]],
    ["a write", ["create", "--title", "x"], ["events"]],
  ])("gives the prompt window to the first calendar call when it is %s", async (_, first, second) => {
    // notDetermined sends the whole CLI to the helper; the read route reuses that decision.
    const { runCLI, directCalls, helperCalls } = storeRunner({ host: { authorization: "notDetermined" } });
    await runCLI("calendar-cli", first);
    await runCLI("calendar-cli", second);
    expect(directCalls).toEqual([{ args: ["auth-status"], timeoutMs: 30_000 }]);
    expect(helperCalls).toEqual([
      { args: first, timeoutMs: 120_000 },
      { args: second, timeoutMs: 30_000 },
    ]);
  });

  it("checks for the helper when the CLI is probed, not at the first read", async () => {
    // A helper installed after the probe never moves this process's reads.
    let installed = false;
    const { runCLI, directCalls, helperCalls } = storeRunner({ helperExists: () => installed });
    await runCLI("calendar-cli", ["list"]);
    installed = true;
    await expect(runCLI("calendar-cli", ["events"])).resolves.toEqual({ via: "direct", args: ["events"] });
    expect(directCalls.map((c) => c.args)).toEqual([["list"], ["events"]]);
    expect(helperCalls).toEqual([]);
  });

  it.each([
    ["denied", { authorization: "denied" }],
    ["a direct probe that throws", new Error("spawn EACCES")],
  ])("never retries a helper call direct when the whole CLI uses the helper (%s)", async (_, host) => {
    const { runCLI, directCalls, helperCalls } = storeRunner({
      host,
      helperRead: async () => { throw new Error("Helper timed out after 30000ms."); },
    });
    await expect(runCLI("calendar-cli", ["events"])).rejects.toThrow("Helper timed out");
    await expect(runCLI("calendar-cli", ["create", "--title", "x"])).rejects.toThrow("Helper timed out");
    expect(directCalls).toEqual([{ args: ["auth-status"], timeoutMs: 30_000 }]);
    expect(helperCalls).toEqual([
      { args: ["events"], timeoutMs: 30_000 },
      { args: ["create", "--title", "x"], timeoutMs: 30_000 },
    ]);
  });

  it("keeps a write racing the first availability read direct", async () => {
    const { runCLI, directCalls, helperCalls } = storeRunner();
    await expect(Promise.all([
      runCLI("calendar-cli", ["events"]),
      runCLI("calendar-cli", ["create", "--title", "x"]),
    ])).resolves.toEqual([
      { via: "helper", args: ["events"] },
      { via: "direct", args: ["create", "--title", "x"] },
    ]);
    expect(directCalls.map((c) => c.args)).toEqual([["auth-status"], ["create", "--title", "x"]]);
    expect(helperCalls.map((c) => c.args)).toEqual([["auth-status"], ["events"]]);
  });

  it("gives the prompt window to the first helper launch when a read and a write race", async () => {
    const { runCLI, helperCalls } = storeRunner({ host: { authorization: "notDetermined" } });
    await Promise.all([runCLI("calendar-cli", ["events"]), runCLI("calendar-cli", ["create", "--title", "x"])]);
    // Both calls await the same route with no store probe, so they launch in call order
    // and the first raises the dialog.
    expect(helperCalls.map((c) => c.args[0])).toEqual(["events", "create"]);
    expect(helperCalls.map((c) => c.timeoutMs)).toEqual([120_000, 30_000]);
  });

  it.each(["reminder-cli", "contacts-cli"])("keeps authorized %s direct with no store field", async (cli) => {
    // Upstream's rule for the other CLIs: authorized goes direct.
    binDir = mkdtempSync(join(tmpdir(), "apple-pim-other-cli-"));
    writeFileSync(join(binDir, cli), "#!/bin/sh\n");
    chmodSync(join(binDir, cli), 0o755);
    const directCalls = [];
    const { runCLI } = createCLIRunner(binDir, {}, {
      helperExists: () => true,
      runDirectImpl: async (cliPath, args) => {
        directCalls.push(args);
        return args[0] === "auth-status" ? { authorization: "authorized" } : { items: [] };
      },
      runViaHelperImpl: async () => { throw new Error(`${cli} read attempted through helper`); },
    });
    await expect(runCLI(cli, ["list"])).resolves.toEqual({ items: [] });
    expect(directCalls).toEqual([["auth-status"], ["list"]]);
  });

});
