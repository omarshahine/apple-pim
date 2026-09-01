import { afterEach, describe, expect, it } from "vitest";
import { spawn } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HELPER_PROC_MARKER, findHelperProcesses } from "../../lib/cli-runner.js";

// reapStaleHelpers() SIGKILLs whatever this pattern matches, so the pattern is the whole
// safety boundary and a JS regex mirroring it would not test it. BSD pgrep -f applies its
// own extended-regex engine to the joined argv, so these tests spawn processes with the real
// argv shapes and run the real /usr/bin/pgrep.
//
// Membership, never set equality: a developer machine may well have a genuine PIMHelper
// resident, and the test must not care.

const isMacOS = process.platform === "darwin";
const onMac = isMacOS ? describe : describe.skip;

/** Sleeper whose argv[1] is `scriptPath` and whose remaining argv is `args`. */
function spawnWithArgv(scriptPath, args = []) {
  writeFileSync(scriptPath, "sleep 120\n");
  const child = spawn("/bin/zsh", [scriptPath, ...args], { stdio: "ignore" });
  child.unref();
  return child;
}

function pgrepPids(pattern) {
  return new Promise((resolve) => {
    const proc = spawn("/usr/bin/pgrep", ["-f", pattern], { stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    proc.stdout.on("data", (d) => (out += d.toString()));
    // pgrep exits 1 on no match, which is an answer, not an error.
    proc.on("close", () =>
      resolve(
        out
          .split("\n")
          .map((line) => parseInt(line.trim(), 10))
          .filter((n) => Number.isFinite(n) && n > 0),
      ),
    );
    proc.on("error", () => resolve([]));
  });
}

onMac("HELPER_PROC_MARKER against a real pgrep", () => {
  /** @type {{children: import("node:child_process").ChildProcess[], dirs: string[]}} */
  const spawned = { children: [], dirs: [] };

  afterEach(() => {
    for (const child of spawned.children) {
      try {
        child.kill("SIGKILL");
      } catch {}
    }
    for (const dir of spawned.dirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    spawned.children = [];
    spawned.dirs = [];
  });

  /** Build a fake bundle tree and return the paths the two layouts run as. */
  function fakeBundle() {
    const root = mkdtempSync(join(tmpdir(), "pimhelper-proc-"));
    spawned.dirs.push(root);
    const app = join(root, "PIMHelper.app");
    mkdirSync(join(app, "Contents", "MacOS"), { recursive: true });
    mkdirSync(join(app, "Contents", "Resources"), { recursive: true });
    return {
      app,
      // What helper/launcher.c actually execv()s: its own directory plus
      // "/../Resources/pim-helper.sh", never normalized. The literal ".." is the reason the
      // old marker missed.
      launcherLayout: join(app, "Contents", "MacOS", "..", "Resources", "pim-helper.sh"),
      // Bundles installed before the launcher change, still in the wild.
      preLauncherLayout: join(app, "Contents", "MacOS", "pim-helper"),
    };
  }

  it("matches the launcher layout, whose path the old literal missed", async () => {
    const bundle = fakeBundle();
    expect(bundle.launcherLayout).not.toContain("Contents/MacOS/pim-helper");

    const child = spawnWithArgv(bundle.launcherLayout);
    spawned.children.push(child);

    expect(await pgrepPids(HELPER_PROC_MARKER)).toContain(child.pid);
  });

  it("still matches pre-launcher bundles", async () => {
    const bundle = fakeBundle();
    const child = spawnWithArgv(bundle.preLauncherLayout);
    spawned.children.push(child);

    expect(await pgrepPids(HELPER_PROC_MARKER)).toContain(child.pid);
  });

  // The one that makes the widening safe. reapStaleHelpers() escalates to SIGKILL, so a
  // pattern that caught the `open -W -a ... PIMHelper.app --args <cli> <out> <err>` parent
  // would abort live calls instead of clearing wedged ones.
  it("does not match the `open` parent, which names the bundle but never enters it", async () => {
    const bundle = fakeBundle();
    const decoy = join(bundle.app, "Contents", "Resources", "not-the-helper.sh");
    const child = spawnWithArgv(decoy, [
      "-W",
      "-a",
      bundle.app,
      "--args",
      "calendar-cli",
      "/tmp/out",
      "/tmp/err",
      "list",
    ]);
    spawned.children.push(child);

    // The decoy carries the whole `open` argv, and the bundle path, and "Contents/" -- it is
    // excluded on the one thing that actually distinguishes the parent: nothing in its argv
    // reads as a pim-helper inside the bundle.
    const matched = await pgrepPids(HELPER_PROC_MARKER);
    expect(matched).not.toContain(child.pid);
    // Proves the decoy is genuinely running and merely unmatched, so a spawn failure cannot
    // pass this test by accident.
    expect(await pgrepPids("not-the-helper\\.sh")).toContain(child.pid);
  });

  it("findHelperProcesses reports the launcher-layout process with an age", async () => {
    const bundle = fakeBundle();
    const child = spawnWithArgv(bundle.launcherLayout);
    spawned.children.push(child);

    const found = await findHelperProcesses();
    const mine = found.find((proc) => proc.pid === child.pid);
    expect(mine, "findHelperProcesses() saw the resident dispatcher").toBeDefined();
    // reapStaleHelpers() skips anything whose age is null, so a found-but-ageless process
    // would still be unreapable.
    expect(mine.ageSeconds).toBeTypeOf("number");
  });
});
