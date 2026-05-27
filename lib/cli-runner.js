import { join } from "path";
import { existsSync, mkdtempSync, readFileSync, unlinkSync, rmdirSync } from "fs";
import { homedir, tmpdir } from "os";
import { spawnProcess } from "./safe-shell.js";

/**
 * Locate Swift CLI binaries by checking multiple locations in order.
 * @param {string[]} extraLocations - Additional directories to check first.
 * @returns {string} Path to the directory containing CLI binaries.
 */
export function findSwiftBinDir(extraLocations = []) {
  const locations = [
    ...extraLocations,
    // ~/.local/bin (setup.sh --install target)
    join(homedir(), ".local", "bin"),
  ];

  for (const loc of locations) {
    if (existsSync(join(loc, "calendar-cli"))) {
      return loc;
    }
  }

  // Return first location as default (will fail with helpful error)
  return locations[0];
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
  return new Promise((resolve, reject) => {
    const scratch = mkdtempSync(join(tmpdir(), "pim-helper-"));
    const outFile = join(scratch, "out");
    const errFile = join(scratch, "err");

    const cleanup = () => {
      for (const f of [outFile, errFile]) {
        try {
          unlinkSync(f);
        } catch {}
      }
      try {
        rmdirSync(scratch);
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
      reject(new Error(`Helper timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    proc.stderr.on("data", (data) => {
      openStderr += data.toString();
    });

    proc.on("close", (code) => {
      clearTimeout(timer);
      if (killed) return;

      // `open -W` exits with the launched app's exit code on macOS. Either
      // way the helper has already written out / err.
      let stdout = "";
      let stderr = "";
      try {
        stdout = readFileSync(outFile, "utf8");
      } catch {}
      try {
        stderr = readFileSync(errFile, "utf8");
      } catch {}
      cleanup();

      if (code === 0) {
        try {
          resolve(JSON.parse(stdout));
        } catch {
          resolve({ success: true, output: stdout });
        }
      } else {
        const msg = stderr || openStderr || `Helper exited with code ${code}`;
        reject(new Error(msg));
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
 * @param {string} binDir - Directory containing the Swift CLI binaries.
 * @param {Object} envOverrides - Extra env vars to pass to every spawn call.
 * @param {{ timeoutMs?: number }} options - Options (e.g. timeout).
 * @returns {{ runCLI: (cli: string, args: string[]) => Promise<object> }}
 */
export function createCLIRunner(binDir, envOverrides = {}, { timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  // Per-CLI routing decision: undefined = unprobed, "direct" or "helper".
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

  async function probeRoute(cli) {
    if (!HELPER_ELIGIBLE_CLIS.has(cli)) {
      route.set(cli, "direct");
      return "direct";
    }
    if (!existsSync(helperAppPath())) {
      route.set(cli, "direct");
      return "direct";
    }
    // Probe directly. If TCC says notDetermined or denied for this process
    // tree, the helper is our only path to access.
    const cliPath = join(binDir, cli);
    try {
      const result = await runDirect(cliPath, ["auth-status"], childEnv(), timeoutMs);
      const auth = result?.authorization;
      const useHelper = auth === "notDetermined" || auth === "denied";
      const decision = useHelper ? "helper" : "direct";
      route.set(cli, decision);
      return decision;
    } catch {
      // If even auth-status fails directly, the helper is the safer bet.
      route.set(cli, "helper");
      return "helper";
    }
  }

  async function runCLI(cli, args) {
    let decision = route.get(cli);
    if (decision === undefined) {
      decision = await probeRoute(cli);
    }

    if (decision === "helper") {
      return runViaHelper(cli, args, childEnv(), timeoutMs, binDir);
    }
    return runDirect(join(binDir, cli), args, childEnv(), timeoutMs);
  }

  return { runCLI };
}
