import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join, resolve, sep } from "node:path";

function configPath() {
  return process.env.APPLE_PIM_MAIL_ATTACHMENTS_CONFIG
    || `${homedir()}/.config/apple-pim/mail-attachments.json`;
}

const DEFAULT_DENIED_BASENAMES = new Set([
  ".netrc", ".pgpass", ".env", ".envrc",
  "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa",
  "authorized_keys", "known_hosts",
  "credentials",
]);

const DEFAULT_DENIED_DIR_COMPONENTS = new Set([
  ".ssh", ".aws", ".gnupg", ".kube", ".docker",
  ".secrets", ".secrets-macbook-pro", ".chezmoi",
  "Keychains",
]);

const DEFAULT_DENIED_BASENAME_REGEX = [
  /\.pem$/i, /\.key$/i, /\.p12$/i, /\.pfx$/i,
  /^\.secrets/, /secret/i, /password/i, /credential/i, /token/i,
  /keychain-access/i,
];

function expandHome(p) {
  if (typeof p !== "string") throw new TypeError("Attachment path must be a string");
  if (p.startsWith("~/")) return homedir() + p.slice(1);
  if (p === "~") return homedir();
  return p;
}

function loadPolicy() {
  if (!existsSync(configPath())) return { enabled: false };
  let raw;
  try {
    raw = readFileSync(configPath(), "utf8");
  } catch (err) {
    throw new Error(`Cannot read mail attachments policy at ${configPath()}: ${err.message}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new Error(`Invalid JSON in ${configPath()}: ${err.message}`);
  }
  return {
    enabled: parsed.enabled === true,
    allowedRoots: Array.isArray(parsed.allowedRoots) ? parsed.allowedRoots.map(expandHome).map((r) => resolve(r)) : [],
    extraDeniedBasenames: Array.isArray(parsed.deniedBasenames) ? parsed.deniedBasenames : [],
    extraDeniedDirComponents: Array.isArray(parsed.deniedDirComponents) ? parsed.deniedDirComponents : [],
  };
}

function canonicalizeRoot(root) {
  try {
    return realpathSync(root);
  } catch {
    return resolve(root);
  }
}

function isWithinRoot(canonicalPath, root) {
  const canonRoot = canonicalizeRoot(root);
  if (canonicalPath === canonRoot) return true;
  return canonicalPath.startsWith(canonRoot + sep);
}

function failsHardDenylist(canonicalPath, policy) {
  const parts = canonicalPath.split(sep);
  const basename = parts[parts.length - 1];
  if (DEFAULT_DENIED_BASENAMES.has(basename)) return `denylisted filename: ${basename}`;
  if (policy.extraDeniedBasenames?.includes(basename)) return `denylisted filename: ${basename}`;
  for (const re of DEFAULT_DENIED_BASENAME_REGEX) {
    if (re.test(basename)) return `denylisted filename pattern: ${basename}`;
  }
  for (const comp of parts.slice(0, -1)) {
    if (DEFAULT_DENIED_DIR_COMPONENTS.has(comp)) return `denylisted directory: ${comp}`;
    if (policy.extraDeniedDirComponents?.includes(comp)) return `denylisted directory: ${comp}`;
  }
  return null;
}

export function validateAttachment(rawPath, { policy = loadPolicy() } = {}) {
  if (!policy.enabled) {
    throw new Error(
      `Mail attachments are disabled by default to prevent local-file exfiltration. To enable, create ${configPath()} with {"enabled": true, "allowedRoots": ["~/Downloads"]}. See plugin docs for details.`,
    );
  }
  if (!policy.allowedRoots || policy.allowedRoots.length === 0) {
    throw new Error(
      `Mail attachments policy at ${configPath()} must list at least one entry in "allowedRoots".`,
    );
  }
  const expanded = expandHome(rawPath);
  if (!existsSync(expanded)) {
    throw new Error(`Attachment file not found: ${expanded}`);
  }
  let canonical;
  try {
    canonical = realpathSync(expanded);
  } catch (err) {
    throw new Error(`Cannot resolve attachment path ${expanded}: ${err.message}`);
  }
  let st;
  try {
    st = statSync(canonical);
  } catch (err) {
    throw new Error(`Cannot stat attachment ${canonical}: ${err.message}`);
  }
  if (!st.isFile()) {
    throw new Error(`Attachment must be a regular file: ${canonical}`);
  }
  const inAllowedRoot = policy.allowedRoots.some((root) => isWithinRoot(canonical, root));
  if (!inAllowedRoot) {
    throw new Error(
      `Attachment ${canonical} is outside allowedRoots (${policy.allowedRoots.join(", ")}). Refusing to attach.`,
    );
  }
  const denyReason = failsHardDenylist(canonical, policy);
  if (denyReason) {
    throw new Error(`Attachment refused (${denyReason}): ${canonical}`);
  }
  return canonical;
}

export function validateAttachments(paths, opts = {}) {
  const policy = opts.policy ?? loadPolicy();
  const list = Array.isArray(paths) ? paths : [paths];
  return list.map((p) => validateAttachment(p, { policy }));
}

// --- Attachment WRITE destination confinement (save_attachment destDir) ---
//
// Outbound attach (above) is default-deny. The save-to-disk destination is the
// inverse case: it defaults to system temp and is allowed anywhere under the
// home directory or temp, but must never target credential stores or
// login-persistence locations. This mirrors the Swift `validateDestDir` (the
// authoritative boundary in MailCLI.swift) so the confinement is also enforced
// — and visible — at the handler before the CLI is ever spawned.
const DENIED_DEST_COMPONENTS = new Set([
  ".ssh", ".aws", ".gnupg", ".kube", ".docker",
  ".secrets", ".chezmoi", "Keychains",
  "LaunchAgents", "LaunchDaemons",
]);

/**
 * Canonicalize a path that may not exist yet by resolving symlinks on its
 * deepest existing ancestor, then re-appending the not-yet-created tail. Mirrors
 * the Swift `canonicalizeIntendedPath`, and prevents a symlink inside home (e.g.
 * `~/safe-link` → `/etc`) from slipping past the boundary check the way a purely
 * lexical `resolve()` would.
 */
function canonicalizeIntendedPath(absPath) {
  let existing = absPath;
  const tail = [];
  while (!existsSync(existing)) {
    const parent = dirname(existing);
    if (parent === existing) break; // reached root
    tail.unshift(basename(existing));
    existing = parent;
  }
  let canonical;
  try {
    canonical = realpathSync(existing);
  } catch {
    canonical = existing;
  }
  for (const comp of tail) canonical = join(canonical, comp);
  return canonical;
}

/**
 * Validate a caller-supplied save_attachment destination directory.
 *
 * Confines the write to the home directory or system temp and rejects sensitive
 * subpaths (even inside home). Returns the canonical (symlink-resolved) path on
 * success; throws on a disallowed target.
 *
 * @param {string} rawDir - The caller-supplied destDir.
 * @returns {string} The canonicalized destination directory.
 */
export function validateDestDir(rawDir) {
  if (typeof rawDir !== "string" || rawDir.length === 0) {
    throw new TypeError("destDir must be a non-empty string");
  }
  const expanded = expandHome(rawDir);
  // Resolve symlinks on the deepest existing ancestor so a symlinked component
  // cannot escape the home/temp boundary (lexical resolve() alone would not).
  const resolved = canonicalizeIntendedPath(resolve(expanded));

  // Canonicalize the home root; canonicalize temp roots generously since the
  // Swift CLI is the authoritative boundary and macOS temp has several aliases.
  const home = canonicalizeRoot(homedir());
  const tmpRoots = [canonicalizeRoot(tmpdir()), "/tmp", "/private/tmp", "/var/folders", "/private/var/folders"];

  const inHome = resolved === home || resolved.startsWith(home + sep);
  const inTmp = tmpRoots.some((r) => resolved === r || resolved.startsWith(r + sep));
  if (!inHome && !inTmp) {
    throw new Error(
      `destDir must be within your home directory or system temp directory, got: ${resolved}`,
    );
  }

  for (const comp of resolved.split(sep)) {
    if (DENIED_DEST_COMPONENTS.has(comp)) {
      throw new Error(`destDir may not target the protected location "${comp}": ${resolved}`);
    }
  }
  const appleConfig = `${home}${sep}.config${sep}apple-pim`;
  if (resolved === appleConfig || resolved.startsWith(appleConfig + sep)) {
    throw new Error(`destDir may not target the apple-pim config directory: ${resolved}`);
  }
  return resolved;
}

export const _internals = { configPath, loadPolicy, expandHome };
