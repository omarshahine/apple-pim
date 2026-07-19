import { join } from "path";
import {
  accessSync,
  constants,
  existsSync,
  lstatSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  rmSync,
} from "fs";
import { homedir, tmpdir } from "os";
import { spawnProcess } from "./safe-shell.js";

/**
 * Probe candidate binary directories and classify each one.
 *
 * Distinguishes the failure modes that `existsSync` alone conflates —
 * most importantly a DANGLING SYMLINK (the repo the link points into was
 * moved, renamed, or cleaned), which `existsSync` reports as "missing"
 * because it follows the link. That conflation once sent debugging down
 * the wrong path entirely: the resolver silently fell through to an
 * unbuilt plugin-cache directory and the error blamed *that* path.
 *
 * @param {string[]} extraLocations - Additional directories to check first.
 * @returns {Array<{dir: string, status: "ok"|"missing"|"dangling-symlink"|"not-executable", target: string|null}>}
 */
export function probeSwiftBinDirs(extraLocations = []) {
  const locations = [
    ...extraLocations,
    // ~/.local/bin (setup.sh --install target)
    join(homedir(), ".local", "bin"),
  ];

  return locations.map((dir) => {
    const cliPath = join(dir, "calendar-cli");
    let status = "missing";
    let target = null;
    try {
      const lst = lstatSync(cliPath); // does NOT follow symlinks
      if (lst.isSymbolicLink()) {
        try {
          target = readlinkSync(cliPath);
        } catch {}
        try {
          accessSync(cliPath, constants.X_OK); // follows the link
          status = "ok";
        } catch {
          status = "dangling-symlink";
        }
      } else {
        try {
          accessSync(cliPath, constants.X_OK);
          status = "ok";
        } catch {
          status = "not-executable";
        }
      }
    } catch {
      status = "missing";
    }
    return { dir, status, target };
  });
}

/** Last failed probe, kept so call-time errors can show what was actually checked. */
let lastFailedProbe = null;

/**
 * Render a probe result as an actionable multi-line diagnosis.
 * @param {ReturnType<typeof probeSwiftBinDirs>} probe
 * @returns {string}
 */
export function describeBinDirProblem(probe) {
  const lines = ["Swift CLI binaries not found. Locations checked:"];
  for (const { dir, status, target } of probe) {
    if (status === "dangling-symlink") {
      lines.push(
        `  - ${dir}: BROKEN SYMLINK -> ${target} (target no longer exists — was the source repo moved, renamed, or cleaned?)`,
      );
    } else if (status === "not-executable") {
      lines.push(`  - ${dir}: present but not executable`);
    } else {
      lines.push(`  - ${dir}: ${status}`);
    }
  }
  lines.push(
    "Fix: run setup.sh --install from the apple-pim repo (copies binaries into ~/.local/bin),",
    "or run scripts/doctor.sh for a full diagnosis.",
  );
  return lines.join("\n");
}

/**
 * Locate Swift CLI binaries by checking multiple locations in order.
 * Skips dangling symlinks and non-executable entries instead of
 * accepting them. When nothing valid is found, still returns the first
 * candidate (callers spawn lazily), but records the probe so the
 * eventual call-time error reports every location checked rather than
 * just the fallback path.
 *
 * @param {string[]} extraLocations - Additional directories to check first.
 * @returns {string} Path to the directory containing CLI binaries.
 */
export function findSwiftBinDir(extraLocations = []) {
  const probe = probeSwiftBinDirs(extraLocations);
  const ok = probe.find((p) => p.status === "ok");
  if (ok) {
    lastFailedProbe = null;
    return ok.dir;
  }
  lastFailedProbe = probe;
  return probe[0].dir;
}

/**
 * Helper to calculate relative date string from days offset.
 * @param {number} daysOffset - Number of days to offset from today.
 * @returns {string} Date in YYYY-MM-DD format.
 */
export function relativeDateString(daysOffset) {
  const date = new Date();
  date.setDate(date.getDate() + daysOffset);
  return date.toISOString().split("T")[0];
}

/** Default timeout for CLI execution (30 seconds). */
const DEFAULT_TIMEOUT_MS = 30_000;

/**
 * Timeout for a helper call that may show a macOS permission dialog.
 * A human has to find and click the prompt; 30s is routinely too short
 * and a timed-out first grant leaves the helper wedged (see reaping).
 */
const PROMPT_TIMEOUT_MS = 120_000;

/** CLIs that go through Calendar / Reminders / Contacts TCC services. */
const HELPER_ELIGIBLE_CLIS = new Set([
  "calendar-cli",
  "reminder-cli",
  "contacts-cli",
]);

/** Resolve the helper .app path (overridable for testing / non-default installs). */
function helperAppPath() {
  return (
    process.env.APPLE_PIM_HELPER_APP ||
    join(homedir(), "Applications", "PIMHelper.app")
  );
}

/** Spawn a system binary and collect stdout; never rejects. */
function runQuick(cmd, args) {
  return new Promise((resolve) => {
    const proc = spawnProcess(cmd, args, {
      env: { PATH: "/usr/bin:/bin" },
    });
    let out = "";
    proc.stdout?.on("data", (d) => (out += d.toString()));
    proc.on("close", (code) => resolve({ code, out }));
    proc.on("error", () => resolve({ code: -1, out: "" }));
  });
}

/** Parse `ps -o etime=` output ([[dd-]hh:]mm:ss) into seconds. */
function parseEtimeSeconds(etime) {
  const trimmed = etime.trim();
  if (!trimmed) return null;
  let days = 0;
  let rest = trimmed;
  const dashIdx = rest.indexOf("-");
  if (dashIdx !== -1) {
    days = parseInt(rest.slice(0, dashIdx), 10) || 0;
    rest = rest.slice(dashIdx + 1);
  }
  const parts = rest.split(":").map((p) => parseInt(p, 10) || 0);
  while (parts.length < 3) parts.unshift(0);
  const [hh, mm, ss] = parts;
  return days * 86400 + hh * 3600 + mm * 60 + ss;
}

/**
 * Find resident pim-helper dispatcher processes for the installed helper.
 * @returns {Promise<Array<{pid: number, ageSeconds: number|null}>>}
 */
async function findHelperProcesses() {
  // Match on the dispatcher script path inside the helper bundle so we
  // never touch unrelated processes.
  const marker = "PIMHelper.app/Contents/MacOS/pim-helper";
  const { out } = await runQuick("/usr/bin/pgrep", ["-f", marker]);
  const pids = out
    .split("\n")
    .map((l) => parseInt(l.trim(), 10))
    .filter((n) => Number.isFinite(n) && n > 0);

  const procs = [];
  for (const pid of pids) {
    const { out: etime } = await runQuick("/bin/ps", ["-o", "etime=", "-p", String(pid)]);
    procs.push({ pid, ageSeconds: parseEtimeSeconds(etime) });
  }
  return procs;
}

/**
 * Reap wedged helper instances before launching a new one.
 *
 * PIMHelper.app is single-instance: if a previous invocation hung (the
 * classic case is a first-run TCC dialog nobody answered), every later
 * `open -W` collides with the resident instance and fails with the
 * opaque Launch Services error -1712. A helper older than the call
 * timeout can no longer be serving anyone — kill it so the system
 * self-heals instead of requiring manual pgrep/kill archaeology.
 */
async function reapStaleHelpers(timeoutMs) {
  const staleAfterSeconds = Math.ceil(timeoutMs / 1000) + 5;
  const procs = await findHelperProcesses();
  let reaped = 0;
  for (const { pid, ageSeconds } of procs) {
    if (ageSeconds !== null && ageSeconds > staleAfterSeconds) {
      try {
        process.kill(pid, "SIGTERM");
        reaped += 1;
      } catch {}
    }
  }
  if (reaped > 0) {
    // Give SIGTERM a moment; escalate to SIGKILL for anything that ignored it.
    await new Promise((r) => setTimeout(r, 500));
    for (const { pid, ageSeconds } of await findHelperProcesses()) {
      if (ageSeconds !== null && ageSeconds > staleAfterSeconds) {
        try {
          process.kill(pid, "SIGKILL");
        } catch {}
      }
    }
  }
  return reaped;
}

/**
 * Serialize helper invocations within this process. The helper app is
 * single-instance, so two concurrent `open -W` calls would collide (the
 * second surfaces as -1712). Chaining them costs little — helper calls
 * are short — and removes the whole failure mode in-process.
 */
let helperChain = Promise.resolve();

/**
 * Run a CLI through PIMHelper.app via Launch Services.
 *
 * `open -W -a PIMHelper.app --args <cli> <out> <err> <args...>` causes
 * launchd to start the .app as its own responsible process for TCC. The
 * helper dispatcher script then forks the named CLI with its stdout and
 * stderr redirected to the caller-provided files, which we read back here.
 *
 * Why files: `open -W` does not stream the launched app's stdout back to
 * the caller. The helper writes them to temp files; we mkdtemp a scratch
 * directory per call so multiple concurrent runs cannot collide.
 */
function runViaHelper(cli, args, env, timeoutMs, binDir) {
  const invoke = () => launchHelper(cli, args, env, timeoutMs, binDir);
  const chained = helperChain.then(invoke, invoke);
  // Keep the chain alive regardless of this call's outcome.
  helperChain = chained.then(
    () => undefined,
    () => undefined,
  );
  return chained;
}

async function launchHelper(cli, args, env, timeoutMs, binDir) {
  await reapStaleHelpers(timeoutMs);

  return new Promise((resolve, reject) => {
    const scratch = mkdtempSync(join(tmpdir(), "pim-helper-"));
    const outFile = join(scratch, "out");
    const errFile = join(scratch, "err");

    const cleanup = () => {
      try {
        rmSync(scratch, { recursive: true, force: true });
      } catch {}
    };

    // open -W blocks until the helper exits; --args forwards everything
    // after to the helper's argv. The helper itself enforces the
    // <cli> <out> <err> <args...> contract.
    const openArgs = [
      "-W",
      "-a",
      helperAppPath(),
      "--args",
      cli,
      outFile,
      errFile,
      ...args,
    ];

    // The helper inherits this env so it can locate the CLI binaries.
    // Critical: APPLE_PIM_BIN_DIR must point at the install dir, since the
    // helper's own working directory is unrelated to the repo.
    const helperEnv = { ...env, APPLE_PIM_BIN_DIR: binDir };

    const proc = spawnProcess("/usr/bin/open", openArgs, { env: helperEnv });

    let openStderr = "";
    let killed = false;

    const timer = setTimeout(() => {
      killed = true;
      proc.kill("SIGTERM");
      cleanup();
      reject(
        new Error(
          `Helper timed out after ${timeoutMs}ms. If a macOS permission ` +
            `dialog is on screen, answer it and retry — the grant persists.`,
        ),
      );
    }, timeoutMs);

    proc.stderr.on("data", (data) => {
      openStderr += data.toString();
    });

    proc.on("close", (code) => {
      clearTimeout(timer);
      if (killed) return;

      // `open -W` is supposed to forward the launched app's exit code, but
      // there are reports of it returning 0 even when the app exited
      // non-zero on older macOS. Treat empty stdout WITH non-empty stderr
      // as failure regardless of `code`, so a misconfigured helper (e.g.
      // CLI binary missing from APPLE_PIM_BIN_DIR) surfaces an error
      // instead of silently resolving to `{ success: true, output: "" }`.
      let stdout = "";
      let stderr = "";
      try {
        stdout = readFileSync(outFile, "utf8");
      } catch {}
      try {
        stderr = readFileSync(errFile, "utf8");
      } catch {}
      cleanup();

      const isFailure = code !== 0 || (stdout === "" && stderr !== "");
      if (isFailure) {
        let msg = stderr || openStderr || `Helper exited with code ${code}`;
        // Launch Services -1712 (errAETimeout) almost always means a
        // previous helper instance is wedged and the single-instance app
        // refused a second launch. Translate the opaque code.
        if (msg.includes("-1712")) {
          msg =
            "PIMHelper.app did not respond (Launch Services error -1712). " +
            "A previous helper instance is likely stuck — usually on an " +
            "unanswered permission dialog. It has been scheduled for " +
            "cleanup; retry this call. If it persists, run scripts/doctor.sh.";
        }
        reject(new Error(msg));
        return;
      }
      try {
        resolve(JSON.parse(stdout));
      } catch {
        resolve({ success: true, output: stdout });
      }
    });

    proc.on("error", (err) => {
      clearTimeout(timer);
      if (killed) return;
      cleanup();
      reject(new Error(`Failed to launch helper: ${err.message}`));
    });
  });
}

/**
 * Factory: creates a runCLI function bound to a specific binary directory.
 *
 * The returned runCLI auto-detects whether to route through PIMHelper.app:
 * on first call to each Calendar / Reminders / Contacts CLI it runs
 * `auth-status` directly. If the result is `notDetermined` or `denied`
 * AND the helper is installed, all subsequent calls to that CLI are
 * routed through `open -W -a PIMHelper.app`. The decision is cached per
 * runner instance so the probe runs at most once per CLI.
 *
 * When the probe saw `notDetermined`, the FIRST helper call for that CLI
 * gets an extended timeout: it will raise the macOS permission dialog,
 * and a human needs time to click it.
 *
 * @param {string} binDir - Directory containing the Swift CLI binaries.
 * @param {Object} envOverrides - Extra env vars to pass to every spawn call.
 * @param {{ timeoutMs?: number }} options - Options (e.g. timeout).
 * @returns {{ runCLI: (cli: string, args: string[]) => Promise<object> }}
 */
export function createCLIRunner(binDir, envOverrides = {}, { timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  // Per-CLI routing decision. Stores a Promise<{route, mayPrompt}> rather
  // than the resolved value so concurrent first calls for the same CLI
  // share a single probe instead of each launching a redundant
  // `auth-status` subprocess.
  const route = new Map();

  function childEnv() {
    const env = {};
    if (process.env.PATH) env.PATH = process.env.PATH;
    if (process.env.HOME) env.HOME = process.env.HOME;
    if (process.env.USER) env.USER = process.env.USER;
    if (process.env.LANG) env.LANG = process.env.LANG;
    if (process.env.TMPDIR) env.TMPDIR = process.env.TMPDIR;
    Object.assign(env, envOverrides);
    return env;
  }

  /** Throw a rich, probe-aware error when the CLI binary is unusable. */
  function assertCLIUsable(cli) {
    const cliPath = join(binDir, cli);
    try {
      accessSync(cliPath, constants.X_OK);
      return cliPath;
    } catch {}

    // Distinguish a dangling symlink from a genuinely absent binary so the
    // error names the actual problem (and the actual link target).
    let detail = `not found at ${cliPath}`;
    try {
      const lst = lstatSync(cliPath);
      if (lst.isSymbolicLink()) {
        let target = "?";
        try {
          target = readlinkSync(cliPath);
        } catch {}
        detail =
          `${cliPath} is a broken symlink -> ${target} ` +
          `(target missing — source repo moved, renamed, or cleaned?)`;
      } else {
        detail = `${cliPath} exists but is not executable`;
      }
    } catch {}

    const probeNote = lastFailedProbe
      ? `\n${describeBinDirProblem(lastFailedProbe)}`
      : `\nFix: run setup.sh --install from the apple-pim repo, or scripts/doctor.sh to diagnose.`;
    throw new Error(`${cli}: ${detail}${probeNote}`);
  }

  async function probeRoute(cli) {
    if (!HELPER_ELIGIBLE_CLIS.has(cli)) return { route: "direct", mayPrompt: false };
    if (!existsSync(helperAppPath())) return { route: "direct", mayPrompt: false };
    // Probe directly. If TCC says notDetermined or denied for this process
    // tree, the helper is our only path to access.
    const cliPath = join(binDir, cli);
    try {
      const result = await runDirect(cliPath, ["auth-status"], childEnv(), timeoutMs);
      const auth = result?.authorization;
      if (auth === "notDetermined") {
        // First helper call will raise the macOS permission dialog.
        return { route: "helper", mayPrompt: true };
      }
      if (auth === "denied") {
        return { route: "helper", mayPrompt: false };
      }
      return { route: "direct", mayPrompt: false };
    } catch {
      // If even auth-status fails directly, the helper is the safer bet.
      return { route: "helper", mayPrompt: false };
    }
  }

  async function runCLI(cli, args) {
    assertCLIUsable(cli);

    if (!route.has(cli)) {
      route.set(cli, probeRoute(cli));
    }
    const decision = await route.get(cli);

    if (decision.route === "helper") {
      // Extended window exactly once: the call that raises the TCC dialog.
      const callTimeout = decision.mayPrompt
        ? Math.max(timeoutMs, PROMPT_TIMEOUT_MS)
        : timeoutMs;
      decision.mayPrompt = false;
      return runViaHelper(cli, args, childEnv(), callTimeout, binDir);
    }
    return runDirect(join(binDir, cli), args, childEnv(), timeoutMs);
  }

  return { runCLI };
}

/**
 * Run a CLI directly as a child of the current process. Stdout is parsed as
 * JSON on success; stderr is the rejection message on failure. This is the
 * fast path used by everything that does not need the TCC bridge.
 */
function runDirect(cliPath, args, env, timeoutMs) {
  return new Promise((resolve, reject) => {
    const proc = spawnProcess(cliPath, args, { env });

    let stdout = "";
    let stderr = "";
    let killed = false;

    const timer = setTimeout(() => {
      killed = true;
      proc.kill("SIGTERM");
      reject(new Error(`CLI timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    proc.stdout.on("data", (data) => {
      stdout += data.toString();
    });
    proc.stderr.on("data", (data) => {
      stderr += data.toString();
    });

    proc.on("close", (code) => {
      clearTimeout(timer);
      if (killed) return;
      if (code === 0) {
        try {
          resolve(JSON.parse(stdout));
        } catch {
          resolve({ success: true, output: stdout });
        }
      } else {
        reject(new Error(stderr || `CLI exited with code ${code}`));
      }
    });

    proc.on("error", (err) => {
      clearTimeout(timer);
      if (killed) return;
      reject(new Error(`Failed to run CLI: ${err.message}`));
    });
  });
}
