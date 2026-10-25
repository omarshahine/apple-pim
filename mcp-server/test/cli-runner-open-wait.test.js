import { afterEach, describe, expect, it } from "vitest";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { awaitDispatcherExit, isOpenWaitFailure } from "../../lib/cli-runner.js";

// `open -W` sometimes exits 1 with "Unable to block on applications (initial call to
// kevent() failed: No such process)" while the helper runs to completion. The runner used
// to reject on that exit code, which surfaced in apple_pim_system as a domain with
// permissionStatus "error" even though TCC had it authorized.

describe("isOpenWaitFailure", () => {
  it("accepts both observed wordings", () => {
    expect(
      isOpenWaitFailure(
        "Unable to block on applications (initial call to kevent() failed: No such process)\n",
      ),
    ).toBe(true);
    expect(isOpenWaitFailure("Unable to block on application (GetProcessPID() returned -600)")).toBe(
      true,
    );
  });

  it("rejects real launch failures and mixed output", () => {
    expect(isOpenWaitFailure("")).toBe(false);
    expect(isOpenWaitFailure("LSOpenURLsWithRole() failed with error -1712")).toBe(false);
    expect(
      isOpenWaitFailure(
        "Unable to block on applications (initial call to kevent() failed: No such process)\n" +
          "The application cannot be opened because its executable is missing.",
      ),
    ).toBe(false);
  });
});

describe("awaitDispatcherExit (injected pgrep)", () => {
  const dirs = [];
  afterEach(() => {
    for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
  });
  const scratchDir = () => {
    const d = mkdtempSync(join(tmpdir(), "pim-open-wait-"));
    dirs.push(d);
    return d;
  };

  it("waits while the dispatcher is resident, then returns once it exits", async () => {
    const scratch = scratchDir();
    let calls = 0;
    const pgrep = async () => ({ out: ++calls <= 3 ? "123\n" : "" });
    await awaitDispatcherExit(scratch, join(scratch, "out"), join(scratch, "err"), () => false, {
      pgrep,
      pollMs: 1,
      appearGraceMs: 10_000,
    });
    expect(calls).toBe(4);
  });

  it("returns immediately when output exists and no dispatcher is resident", async () => {
    const scratch = scratchDir();
    writeFileSync(join(scratch, "out"), '{"authorization":"authorized"}');
    let calls = 0;
    const pgrep = async () => (calls++, { out: "" });
    await awaitDispatcherExit(scratch, join(scratch, "out"), join(scratch, "err"), () => false, {
      pgrep,
      pollMs: 1,
      appearGraceMs: 10_000,
    });
    expect(calls).toBe(1);
  });

  it("gives up after the appear grace when nothing ever launched", async () => {
    const scratch = scratchDir();
    const start = Date.now();
    await awaitDispatcherExit(scratch, join(scratch, "out"), join(scratch, "err"), () => false, {
      pgrep: async () => ({ out: "" }),
      pollMs: 5,
      appearGraceMs: 50,
    });
    expect(Date.now() - start).toBeGreaterThanOrEqual(50);
  });

  it("stops when cancelled", async () => {
    const scratch = scratchDir();
    let calls = 0;
    await awaitDispatcherExit(scratch, join(scratch, "out"), join(scratch, "err"), () => calls >= 2, {
      pgrep: async () => (calls++, { out: "1\n" }),
      pollMs: 1,
    });
    expect(calls).toBe(2);
  });
});

const onMac = process.platform === "darwin" ? describe : describe.skip;

onMac("awaitDispatcherExit against a real pgrep", () => {
  it("tracks a process whose argv carries the scratch path", async () => {
    const scratch = mkdtempSync(join(tmpdir(), "pim-open-wait-"));
    try {
      const outFile = join(scratch, "out");
      // Same shape as the dispatcher: argv includes <out>, and it writes output partway
      // through, then keeps running. Returning on "out has content" would be too early.
      const child = spawn(
        "/bin/zsh",
        ["-c", 'print -n partial > "$1"; sleep 0.6; print -n " done" >> "$1"', "pim", outFile],
        { stdio: "ignore" },
      );
      const exited = new Promise((r) => child.on("exit", r));
      await new Promise((r) => setTimeout(r, 100));
      await awaitDispatcherExit(scratch, outFile, join(scratch, "err"), () => false, {
        pollMs: 50,
      });
      // The wait must outlast the partial write and return only after the final one.
      expect(readFileSync(outFile, "utf8")).toBe("partial done");
      await exited;
    } finally {
      rmSync(scratch, { recursive: true, force: true });
    }
  });
});
