/**
 * The gate that keeps envelope-only prompting from becoming a bypass.
 *
 * The channel stopped handing the agent message bodies and started handing it ids. That is
 * the right split, but it moves the security boundary onto the tool: `apple_pim_mail` will
 * act on any id it is given. Two decisions the channel made about a message therefore have
 * to bind the tool:
 *
 * - a message the channel **dropped** (spoofed, unauthenticated) must not be *read*
 * - a message the channel admitted **observe-only** must not be *replied to*
 *
 * The two are kept apart because collapsing them would be wrong in both directions: an
 * observe message is readable by design, and a dropped message is not answerable because it
 * is not readable in the first place.
 *
 * ## Why this is SQLite-backed, not an in-memory set
 *
 * An earlier version held these decisions in a bounded, per-account, in-memory map that the
 * channel populated and persisted as a snapshot. Two bypasses fell out of that (Greptile
 * #1, #2 on PR #97):
 *
 * - **Process-local.** `apple_pim_mail` can run in a different process from the channel
 *   (the standalone MCP server). That process never populated the map, so every gate check
 *   saw an empty set and permitted everything.
 * - **Bounded eviction.** Observe mail is the highest-volume category, so the map's 2000-entry
 *   cap was reached in normal use, and evicting the oldest entry silently *un-blocked* a
 *   read-only sender.
 *
 * Both dissolve once the decision lives in the durable store keyed by message id: any
 * process sharing the state directory reads the same rows, and there is no cap to evict past.
 * The channel writes one row per decision; the tool queries by id. No hydration, no snapshot,
 * no in-memory lifetime to get wrong.
 *
 * Plain JS rather than TypeScript so the tool handlers in this directory can import it
 * directly, the same way they import every other helper here.
 */

import { createRequire } from "node:module";
import { existsSync, mkdirSync } from "node:fs";
import os from "node:os";
import path from "node:path";

/** Normalizes so `<id>`, ` id `, and `ID` are the same message. */
function normalize(id) {
  return String(id ?? "")
    .trim()
    .replace(/^<|>$/g, "")
    .toLowerCase();
}

/**
 * The channel's own store, resolved the same way `openclaw/src/mail-channel/store.ts` does,
 * so the tool reads exactly the database the channel wrote. Following `OPENCLAW_STATE_DIR`
 * is what keeps a dev gateway off the operator's real decisions.
 */
function storeDbPath() {
  const stateDir = process.env.OPENCLAW_STATE_DIR?.trim();
  const root = stateDir && stateDir.length > 0 ? stateDir : path.join(os.homedir(), ".openclaw");
  const expanded = root.startsWith("~/") ? path.join(os.homedir(), root.slice(2)) : root;
  return path.join(expanded, "apple-pim", "mail-channel.sqlite");
}

// `undefined` = not opened yet; a handle once opened; `null` = this runtime has no
// `node:sqlite`. A second connection to the same file as the channel's is fine: SQLite
// serializes writers and WAL permits concurrent readers.
let db;

/**
 * Loads `node:sqlite`. Indirected through a binding so a test can simulate a runtime that
 * lacks it; production never reassigns this.
 *
 * Required at runtime rather than imported, so a bundler targeting an older Node cannot
 * rewrite the specifier to a bare `sqlite` and fail at load. Mirrors the guard in `store.ts`.
 */
let loadSqlite = () => createRequire(import.meta.url)("node:sqlite").DatabaseSync;

/**
 * Opens the shared store, or returns null when `node:sqlite` is unavailable.
 *
 * The gate degrades rather than throws in that case, and it is usually safe to: the channel
 * cannot run without the same module (`store.ts` requires it), so a runtime that lacks it
 * never produced any admission decision to enforce. The mail tool is being used there in a
 * channel-less mode where its own caller is the trust boundary. Breaking every read and
 * reply instead — as a hard require would — is strictly worse.
 *
 * That reasoning holds per-process but not per-machine, which is the hole this guard closes
 * (Greptile, PR #103). The decisions are durable rows, not process state: the channel writes
 * them on Node >= 22.13, where `node:sqlite` exists, and the standalone MCP server can be
 * launched later against the same state directory by a Claude Code install running Node 18
 * or 20 — where it does not. `mcp-server/build.mjs` targets `node18` precisely so that is
 * allowed. Waving those reads through would silently undo a decision that demonstrably was
 * made, so when the store file exists the gate denies instead of degrading.
 *
 * Keyed on the file rather than on a Node version check because the file is the direct
 * evidence: no store, no decisions, nothing to bypass, and channel-less users keep working.
 */
function database() {
  if (db !== undefined) {
    return db;
  }
  let DatabaseSync;
  try {
    DatabaseSync = loadSqlite();
  } catch {
    db = null;
    return null;
  }
  const file = storeDbPath();
  mkdirSync(path.dirname(file), { recursive: true });
  const opened = new DatabaseSync(file);
  opened.exec("PRAGMA journal_mode = WAL");
  opened.exec("PRAGMA synchronous = NORMAL");
  // One row per (message, decision). `id` alone is the match key because the gate is handed
  // an id and nothing else, and one mailbox feeds one agent, so a decision by any account
  // must bind every read of that id.
  opened.exec(`
    CREATE TABLE IF NOT EXISTS mail_admission (
      id     TEXT NOT NULL,
      kind   TEXT NOT NULL,
      reason TEXT NOT NULL,
      PRIMARY KEY (id, kind)
    )
  `);
  db = opened;
  return opened;
}

const KIND_REFUSED = "refused";
const KIND_REPLY_BLOCKED = "reply-blocked";

/**
 * Why this runtime cannot honor the channel's decisions, or undefined when it can.
 *
 * Recomputed per lookup rather than cached alongside `db`, because the two facts have
 * different lifetimes. Whether `node:sqlite` loads is fixed for the process; whether the
 * store exists is not. A long-lived MCP server can start before the channel has ever written
 * a decision — caching "nothing to enforce" at that moment would keep the gate open for the
 * rest of its life, exactly when the channel starts producing decisions to enforce. The
 * stat only runs on runtimes that already failed to load `node:sqlite`.
 */
function unenforceableReason() {
  if (database() !== null) {
    return undefined;
  }
  const file = storeDbPath();
  return existsSync(file)
    ? `this runtime has no node:sqlite, so the Apple Mail channel's admission decisions in ` +
        `${file} cannot be read; run the MCP server on Node >= 22.13 to enforce them`
    : undefined;
}

function record(id, kind, reason) {
  const key = normalize(id);
  const conn = database();
  if (!key || !conn) {
    return;
  }
  conn
    .prepare(
      `INSERT INTO mail_admission (id, kind, reason) VALUES (?, ?, ?)
       ON CONFLICT(id, kind) DO UPDATE SET reason = excluded.reason`,
    )
    .run(key, kind, reason);
}

function reasonFor(id, kind) {
  const key = normalize(id);
  const conn = database();
  // Denies uniformly, before the id is even considered: the question "was this message
  // refused?" has no answer here, and every caller treats a reason as a refusal. Applying it
  // to a blank id too keeps `filterQuarantinedResults` from letting rows through on a
  // missing `messageId`.
  const blocked = unenforceableReason();
  if (blocked) {
    return blocked;
  }
  if (!key || !conn) {
    return undefined;
  }
  const row = conn
    .prepare("SELECT reason FROM mail_admission WHERE id = ? AND kind = ?")
    .get(key, kind);
  return row?.reason;
}

/** Records that the channel refused this message. Not readable. */
export function recordRefused(id, reason) {
  record(id, KIND_REFUSED, reason ?? "not_admitted");
}

/** Records that the channel admitted this message for reading only. Not repliable. */
export function recordReplyBlocked(id, reason) {
  record(id, KIND_REPLY_BLOCKED, reason ?? "observe_only");
}

/** The reason this message must not be read, or undefined when it may be. */
export function quarantineReason(id) {
  return reasonFor(id, KIND_REFUSED);
}

/** The reason this message may be read but not answered, or undefined when it may be. */
export function replyBlockReason(id) {
  return reasonFor(id, KIND_REPLY_BLOCKED);
}

/**
 * Throws when the tool is being asked to open a message the channel refused.
 *
 * The error names the reason rather than saying "denied", because the agent can act on the
 * distinction: an unauthenticated sender is a different situation from one whose mailbox
 * simply is not enrolled, and a message that reads as blocked-for-no-reason invites a retry.
 */
export function assertMailReadable(id, action) {
  const reason = quarantineReason(id);
  if (!reason) {
    return;
  }
  throw new Error(
    `Refusing to ${action} message ${id}: the Apple Mail channel did not admit it (${reason}). ` +
      `Its sender failed the channel's authentication policy, so its contents are not trusted ` +
      `input. Reading it here would bypass that decision.`,
  );
}

/**
 * Throws when the tool is being asked to answer a message the channel admitted read-only.
 *
 * Separate from `assertMailReadable` because the answer differs: the body is legitimately
 * readable, so refusing to open it would be wrong. Only the reply is refused, and the error
 * says so, because an agent told merely "denied" will reasonably try another way.
 */
export function assertMailRepliable(id, action) {
  const reason = replyBlockReason(id);
  if (!reason) {
    return;
  }
  throw new Error(
    `Refusing to ${action} message ${id}: the Apple Mail channel admitted it for reading ` +
      `only (${reason}). Its sender is not authorized to receive replies, and answering here ` +
      `would bypass the channel's egress policy. Summarize it instead, or tell the operator.`,
  );
}

/**
 * Removes refused messages from a listing or search result.
 *
 * `reportWithheld` controls whether the response admits that rows were removed. For a
 * listing the answer does not depend on anything the agent chose, so saying "2 withheld" is
 * a useful diagnostic: a quietly short listing is otherwise indistinguishable from an empty
 * mailbox.
 *
 * For a search it must stay silent, because the count is query-dependent and therefore an
 * oracle in its own right. `search --field content "secret phrase"` reporting one withheld
 * row confirms the phrase appears in refused mail without ever returning it, which is the
 * exact leak filtering the rows was meant to close.
 */
export function filterQuarantinedResults(result, { reportWithheld = false } = {}) {
  if (!result || typeof result !== "object" || !Array.isArray(result.messages)) {
    return result;
  }
  const kept = result.messages.filter((m) => !quarantineReason(m?.messageId));
  const withheld = result.messages.length - kept.length;
  if (withheld === 0) {
    return result;
  }
  const filtered = { ...result, messages: kept };
  if (typeof result.count === "number") {
    filtered.count = kept.length;
  }
  if (reportWithheld) {
    filtered.withheldByChannelPolicy = withheld;
  }
  return filtered;
}

/** Test seam. Clears every recorded decision. Not part of the tool surface. */
export function resetMailAdmission() {
  database()?.exec("DELETE FROM mail_admission");
}

/** Test seam. Drops the connection so the next call reopens from disk, proving durability. */
export function closeMailAdmissionForTest() {
  db?.close();
  db = undefined;
}

/**
 * Test seam. Swaps the `node:sqlite` loader so a suite can exercise the runtimes CI cannot
 * itself run on — CI is Node 20, which has no `node:sqlite`, and the fail-closed branch has
 * to be provable on the machines that do. Pass no argument to restore the real loader.
 */
export function setSqliteLoaderForTest(fn) {
  loadSqlite = fn ?? (() => createRequire(import.meta.url)("node:sqlite").DatabaseSync);
  db = undefined;
}
