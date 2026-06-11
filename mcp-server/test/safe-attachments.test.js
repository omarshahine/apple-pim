import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { validateAttachment, validateAttachments, validateDestDir } from "../../lib/safe-attachments.js";

let workdir;
const canon = (p) => realpathSync(p);

function withPolicy(policy) {
  return { policy };
}

beforeEach(() => {
  workdir = mkdtempSync(join(tmpdir(), "pim-att-"));
});

afterEach(() => {
  rmSync(workdir, { recursive: true, force: true });
});

describe("safe-attachments", () => {
  it("default-denies when no policy config exists", () => {
    const file = join(workdir, "ok.txt");
    writeFileSync(file, "hi");
    expect(() => validateAttachment(file, withPolicy({ enabled: false }))).toThrow(
      /disabled by default/i,
    );
  });

  it("rejects when allowlist is empty even if enabled", () => {
    const file = join(workdir, "ok.txt");
    writeFileSync(file, "hi");
    expect(() =>
      validateAttachment(file, withPolicy({ enabled: true, allowedRoots: [] })),
    ).toThrow(/at least one entry/i);
  });

  it("accepts paths inside an allowed root", () => {
    const file = join(workdir, "report.pdf");
    writeFileSync(file, "%PDF");
    const got = validateAttachment(file, withPolicy({ enabled: true, allowedRoots: [workdir] }));
    expect(got).toBe(canon(file));
  });

  it("rejects paths outside the allowed root", () => {
    const inside = mkdtempSync(join(tmpdir(), "pim-att-allow-"));
    const outside = mkdtempSync(join(tmpdir(), "pim-att-deny-"));
    const file = join(outside, "leak.txt");
    writeFileSync(file, "secrets");
    expect(() =>
      validateAttachment(file, withPolicy({ enabled: true, allowedRoots: [inside] })),
    ).toThrow(/outside allowedRoots/i);
    rmSync(inside, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  });

  it("refuses denylisted basenames even when path is inside allowed root", () => {
    const file = join(workdir, "id_rsa");
    writeFileSync(file, "PRIVATE KEY");
    expect(() =>
      validateAttachment(file, withPolicy({ enabled: true, allowedRoots: [workdir] })),
    ).toThrow(/denylisted filename: id_rsa/);
  });

  it("refuses denylisted directory components", () => {
    const sshDir = join(workdir, ".ssh");
    mkdirSync(sshDir);
    const file = join(sshDir, "config");
    writeFileSync(file, "Host *");
    expect(() =>
      validateAttachment(file, withPolicy({ enabled: true, allowedRoots: [workdir] })),
    ).toThrow(/denylisted directory: \.ssh/);
  });

  it("refuses .pem and .key files even with neutral names", () => {
    const pem = join(workdir, "tls.pem");
    const key = join(workdir, "server.key");
    writeFileSync(pem, "x");
    writeFileSync(key, "x");
    expect(() =>
      validateAttachment(pem, withPolicy({ enabled: true, allowedRoots: [workdir] })),
    ).toThrow(/denylisted filename pattern/);
    expect(() =>
      validateAttachment(key, withPolicy({ enabled: true, allowedRoots: [workdir] })),
    ).toThrow(/denylisted filename pattern/);
  });

  it("refuses files containing 'secret' or 'credential' in the name", () => {
    const secretFile = join(workdir, "MY_SECRETS.txt");
    const credFile = join(workdir, "service-credential.json");
    writeFileSync(secretFile, "x");
    writeFileSync(credFile, "x");
    expect(() =>
      validateAttachment(secretFile, withPolicy({ enabled: true, allowedRoots: [workdir] })),
    ).toThrow(/denylisted filename pattern/);
    expect(() =>
      validateAttachment(credFile, withPolicy({ enabled: true, allowedRoots: [workdir] })),
    ).toThrow(/denylisted filename pattern/);
  });

  it("resolves symlinks before checking — symlink in allowed root pointing to denied path is rejected", () => {
    const denyDir = mkdtempSync(join(tmpdir(), "pim-att-target-"));
    const target = join(denyDir, ".ssh-target.txt");
    writeFileSync(target, "secret");
    const link = join(workdir, "innocent.txt");
    symlinkSync(target, link);
    expect(() =>
      validateAttachment(link, withPolicy({ enabled: true, allowedRoots: [workdir] })),
    ).toThrow(/outside allowedRoots/);
    rmSync(denyDir, { recursive: true, force: true });
  });

  it("rejects '..' traversal that escapes the allowed root", () => {
    const inner = join(workdir, "inner");
    mkdirSync(inner);
    const escapeTarget = mkdtempSync(join(tmpdir(), "pim-att-escape-"));
    const file = join(escapeTarget, "leak.txt");
    writeFileSync(file, "x");
    const traversal = join(inner, "..", "..", file.split("/").pop());
    expect(() =>
      validateAttachment(`${inner}/../../${file.split("/").pop()}`, withPolicy({ enabled: true, allowedRoots: [inner] })),
    ).toThrow(/not found|outside allowedRoots/);
    rmSync(escapeTarget, { recursive: true, force: true });
  });

  it("rejects directories — only regular files allowed", () => {
    expect(() =>
      validateAttachment(workdir, withPolicy({ enabled: true, allowedRoots: [workdir] })),
    ).toThrow(/regular file/);
  });

  it("validateAttachments handles arrays and single strings symmetrically", () => {
    const a = join(workdir, "a.pdf");
    const b = join(workdir, "b.pdf");
    writeFileSync(a, "x");
    writeFileSync(b, "x");
    const policy = { enabled: true, allowedRoots: [workdir] };
    expect(validateAttachments(a, { policy })).toEqual([canon(a)]);
    expect(validateAttachments([a, b], { policy })).toEqual([canon(a), canon(b)]);
  });
});

describe("validateDestDir (save_attachment write confinement)", () => {
  // The validator canonicalizes symlinks on the deepest existing ancestor, so
  // expected values are computed against the realpath'd home/temp roots.
  const canonHome = realpathSync(homedir());
  const canonTmp = realpathSync(tmpdir());

  it("accepts a directory under the home directory", () => {
    const dir = join(homedir(), "Downloads", "pim-test");
    expect(validateDestDir(dir)).toBe(join(canonHome, "Downloads", "pim-test"));
  });

  it("expands ~ and accepts the result", () => {
    const got = validateDestDir("~/Downloads");
    expect(got).toBe(join(canonHome, "Downloads"));
  });

  it("accepts a directory under system temp", () => {
    const dir = join(tmpdir(), "pim-att");
    expect(validateDestDir(dir)).toBe(join(canonTmp, "pim-att"));
  });

  it("rejects a path outside home and temp", () => {
    expect(() => validateDestDir("/etc/cron.d")).toThrow(/within your home directory or system temp/i);
  });

  it("resolves symlinks — a symlinked dir escaping home/temp is rejected", () => {
    const dir = mkdtempSync(join(tmpdir(), "pim-dest-"));
    const link = join(dir, "escape");
    symlinkSync("/etc", link); // target is outside home and temp
    expect(() => validateDestDir(link)).toThrow(/within your home directory or system temp/i);
    rmSync(dir, { recursive: true, force: true });
  });

  it("rejects login-persistence directories even inside home", () => {
    expect(() => validateDestDir(join(homedir(), "Library", "LaunchAgents"))).toThrow(
      /protected location "LaunchAgents"/,
    );
  });

  it("rejects credential-store directories even inside home", () => {
    expect(() => validateDestDir(join(homedir(), ".ssh"))).toThrow(/protected location "\.ssh"/);
    expect(() => validateDestDir(join(homedir(), ".aws", "x"))).toThrow(/protected location "\.aws"/);
  });

  it("rejects '..' traversal that escapes home into a protected dir", () => {
    expect(() => validateDestDir(join(homedir(), "Downloads", "..", ".ssh"))).toThrow(
      /protected location "\.ssh"/,
    );
  });

  it("rejects the apple-pim config directory", () => {
    expect(() => validateDestDir(join(homedir(), ".config", "apple-pim"))).toThrow(
      /apple-pim config directory/,
    );
  });

  it("rejects non-string and empty input", () => {
    expect(() => validateDestDir("")).toThrow(/non-empty string/);
    expect(() => validateDestDir(undefined)).toThrow(/non-empty string/);
  });
});
