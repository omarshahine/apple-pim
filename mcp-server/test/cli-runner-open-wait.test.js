import { afterEach, describe, expect, it } from "vitest";
import { spawn } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { awaitDispatcherExit, isOpenWaitFailure, launchHelper } from "../../lib/cli-runner.js";

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

// End to end through launchHelper with a stand-in for /usr/bin/open. The fake parses the
// real `-W -a <app> --args <cli> <out> <err> ...` argv, starts a detached dispatcher whose
// argv carries <out> (as the real one does), and returns at once with the stderr and exit
// code chosen by FAKE_OPEN_RC / FAKE_OPEN_ERR. The dispatcher writes FAKE_PAYLOAD only after
// a delay, so every case below has `open` returning BEFORE the helper has finished. The
// dispatcher must not inherit the fake's stdio: launchd starts the real one, so it never
// holds open's pipes, and if it did, node's "close" would wait for it and hide the race.
onMac("launchHelper when open -W cannot wait", () => {
  const KEVENT =
    "Unable to block on applications (initial call to kevent() failed: No such process)";
  let dir;
  let fakeOpen;

  afterEach(() => {
    if (dir) rmSync(dir, { recursive: true, force: true });
    dir = undefined;
  });

  function setup() {
    dir = mkdtempSync(join(tmpdir(), "pim-fake-open-"));
    fakeOpen = join(dir, "open");
    writeFileSync(
      fakeOpen,
      [
        "#!/bin/zsh",
        "while [[ $1 != --args ]]; do shift; done; shift",
        'out="$2"; err="$3"',
        "/bin/zsh -c 'sleep 0.4; print -rn -- \"$FAKE_PAYLOAD\" > \"$1\"' dispatcher \"$out\" </dev/null >/dev/null 2>&1 &!",
        'print -r -- "$FAKE_OPEN_ERR" >&2',
        'exit "$FAKE_OPEN_RC"',
        "",
      ].join("\n"),
    );
    chmodSync(fakeOpen, 0o755);
  }

  const run = (env) =>
    launchHelper("contacts-cli", ["auth-status"], { PATH: "/usr/bin:/bin", ...env }, 10_000, dir, {
      openBin: fakeOpen,
    });

  it("resolves the helper's output when open exits 1 (the smoke-test failure)", async () => {
    setup();
    await expect(
      run({ FAKE_OPEN_RC: "1", FAKE_OPEN_ERR: KEVENT, FAKE_PAYLOAD: '{"authorization":"authorized"}' }),
    ).resolves.toEqual({ authorization: "authorized" });
  });

  it("waits for the output when open exits 0 before the helper finishes", async () => {
    setup();
    await expect(
      run({
        FAKE_OPEN_RC: "0",
        FAKE_OPEN_ERR: "Unable to block on application (GetProcessPID() returned 18446744073709551016)",
        FAKE_PAYLOAD: '{"authorization":"authorized"}',
      }),
    ).resolves.toEqual({ authorization: "authorized" });
  });

  it("rejects a completed success:false payload, since the exit code is gone", async () => {
    setup();
    await expect(
      run({
        FAKE_OPEN_RC: "1",
        FAKE_OPEN_ERR: KEVENT,
        FAKE_PAYLOAD: '{"success":false,"error":"SMTP auth failed"}',
      }),
    ).rejects.toThrow("SMTP auth failed");
  });

  it("still fails a real launch error", async () => {
    setup();
    await expect(
      run({
        FAKE_OPEN_RC: "1",
        FAKE_OPEN_ERR: "LSOpenURLsWithRole() failed with error -1712",
        FAKE_PAYLOAD: '{"authorization":"authorized"}',
      }),
    ).rejects.toThrow("-1712");
  });
});
