/**
 * The gate that keeps envelope-only prompting from becoming a bypass.
 *
 * The channel hands the agent an id, so the tool must honor two of the channel's decisions:
 * a dropped message must not be read, and an observe message must not be answered. Both live
 * in the shared SQLite store keyed by id, so the gate binds the tool across processes and
 * never expires under eviction.
 */

import { describe, it, before, beforeEach, after } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  assertMailReadable,
  assertMailRepliable,
  recordRefused,
  recordReplyBlocked,
  quarantineReason,
  replyBlockReason,
  filterQuarantinedResults,
  resetMailAdmission,
  closeMailAdmissionForTest,
  setSqliteLoaderForTest,
} from "../../lib/mail-quarantine.js";
import { runPollLoop } from "./poll.ts";

// Point the module at a throwaway state dir. The module opens its database lazily on first
// call — never at import — so setting this at module-eval time, before any test body runs, is
// enough. `node --test` runs each file in its own process, so it affects only this suite.
const tmp = mkdtempSync(path.join(os.tmpdir(), "apple-pim-quarantine-"));
process.env.OPENCLAW_STATE_DIR = tmp;

before(() => resetMailAdmission());
beforeEach(() => resetMailAdmission());
after(() => {
  closeMailAdmissionForTest();
  rmSync(tmp, { recursive: true, force: true });
});

// The second bypass, symmetric to the first. The channel suppresses its own reply to an
// unvetted sender, so the sender must not receive one through `apple_pim_mail` either.
describe("reply blocks", () => {
  it("lets an ordinary message be answered", () => {
    assert.doesNotThrow(() => assertMailRepliable("anything@example.com", "reply to"));
  });

  it("refuses to answer an observe-only message, naming why", () => {
    recordReplyBlocked("<stranger@example.com>", "authenticated_but_not_allowlisted");
    assert.throws(
      () => assertMailRepliable("stranger@example.com", "reply to"),
      /admitted it for reading only \(authenticated_but_not_allowlisted\)/,
    );
  });

  it("keeps that message readable, because observe means readable", () => {
    // Blocking the reply must not blind the agent to mail it is supposed to read for context.
    recordReplyBlocked("stranger@example.com", "authenticated_but_not_allowlisted");
    assert.doesNotThrow(() => assertMailReadable("stranger@example.com", "read"));
  });

  it("matches regardless of brackets, case, or padding", () => {
    recordReplyBlocked("<Stranger@Example.COM>", "observe_only");
    for (const v of ["stranger@example.com", "<stranger@example.com>", "  STRANGER@Example.com "]) {
      assert.throws(() => assertMailRepliable(v, "reply to"), v);
    }
  });

  it("keeps the two decisions apart", () => {
    // A dropped message is unreadable; an observe message is readable but unanswerable.
    // Collapsing them would either leak the first or muzzle the second.
    recordRefused("dropped@example.com", "unauthenticated_sender");
    recordReplyBlocked("observed@example.com", "observe_only");
    assert.throws(() => assertMailReadable("dropped@example.com", "read"));
    assert.doesNotThrow(() => assertMailRepliable("dropped@example.com", "reply to"));
    assert.doesNotThrow(() => assertMailReadable("observed@example.com", "read"));
    assert.throws(() => assertMailRepliable("observed@example.com", "reply to"));
  });
});

describe("mail quarantine", () => {
  it("lets an unlisted message through untouched", () => {
    assert.doesNotThrow(() => assertMailReadable("anything@example.com", "read"));
  });

  it("refuses a message the channel dropped, naming why", () => {
    recordRefused("<spoof@example.com>", "unauthenticated_sender");
    assert.throws(
      () => assertMailReadable("spoof@example.com", "read"),
      /did not admit it \(unauthenticated_sender\)/,
    );
  });

  it("refuses attachments from it too", () => {
    recordRefused("spoof@example.com", "identifier_authentication_too_weak");
    assert.throws(
      () => assertMailReadable("spoof@example.com", "save an attachment from"),
      /Refusing to save an attachment from/,
    );
  });

  it("matches regardless of brackets, case, or padding", () => {
    recordRefused("<Spoof@Example.COM>", "unauthenticated_sender");
    for (const variant of ["spoof@example.com", "<spoof@example.com>", "  SPOOF@EXAMPLE.com "]) {
      assert.equal(quarantineReason(variant), "unauthenticated_sender", variant);
    }
  });

  it("ignores an empty id rather than quarantining everything", () => {
    recordRefused("", "unauthenticated_sender");
    recordRefused("   ", "unauthenticated_sender");
    assert.doesNotThrow(() => assertMailReadable("", "read"));
    assert.equal(quarantineReason(""), undefined);
  });
});

// Greptile #1 and #2 on PR #97. The whole reason the gate is SQLite-backed: it must survive
// the process that made the decision (a dropped message is never reclassified, and the tool
// may run elsewhere), and it must not expire under a bounded cache.
describe("durability", () => {
  it("survives losing the connection, because the decision is on disk", () => {
    recordRefused("kept@example.com", "unauthenticated_sender");
    recordReplyBlocked("readonly@example.com", "observe_only");
    // Drop the handle the way a process exit would; the next call reopens the same file.
    closeMailAdmissionForTest();
    assert.throws(() => assertMailReadable("kept@example.com", "read"));
    assert.throws(() => assertMailRepliable("readonly@example.com", "reply to"));
  });

  it("does not evict: many recorded blocks all still bind", () => {
    // The old in-memory set capped at 2000 and evicted the oldest, silently un-blocking a
    // read-only sender once observe volume passed the cap. Per-id rows have no such ceiling.
    for (let i = 0; i < 2500; i += 1) {
      recordReplyBlocked(`obs-${i}@example.com`, "observe_only");
    }
    assert.throws(() => assertMailRepliable("obs-0@example.com", "reply to"), /reading only/);
    assert.throws(() => assertMailRepliable("obs-2499@example.com", "reply to"), /reading only/);
  });

  it("re-recording a decision updates its reason rather than duplicating", () => {
    recordReplyBlocked("x@example.com", "observe_only");
    recordReplyBlocked("x@example.com", "authenticated_but_not_allowlisted");
    assert.equal(replyBlockReason("x@example.com"), "authenticated_but_not_allowlisted");
  });
});

// Blocking `get` alone left `search --field content` as a content oracle: the agent probes
// for a phrase and learns from the hit whether a refused message contains it, without reading
// a body. Listings leak the envelope the same way.
describe("filterQuarantinedResults", () => {
  const payload = () => ({
    count: 3,
    messages: [
      { messageId: "ok1", sender: "a@example.com", subject: "hello" },
      { messageId: "spoofed", sender: "b@evil.example", subject: "secret phrase" },
      { messageId: "ok2", sender: "c@example.com", subject: "hi" },
    ],
  });

  it("passes results through untouched when nothing is quarantined", () => {
    assert.deepEqual(filterQuarantinedResults(payload()), payload());
  });

  it("withholds a quarantined row and corrects the count", () => {
    recordRefused("spoofed", "unauthenticated_sender");
    const filtered = filterQuarantinedResults(payload());
    assert.deepEqual(
      filtered.messages.map((m: { messageId: string }) => m.messageId),
      ["ok1", "ok2"],
    );
    assert.equal(filtered.count, 2, "count must match what was returned");
  });

  it("reports the withheld count when asked", () => {
    recordRefused("spoofed", "unauthenticated_sender");
    assert.equal(
      filterQuarantinedResults(payload(), { reportWithheld: true }).withheldByChannelPolicy,
      1,
    );
  });

  // The count is itself an oracle for a search. "1 withheld" for `--field content
  // "secret phrase"` confirms the phrase is in refused mail without returning it.
  it("stays silent about the count by default, since a query-dependent count leaks", () => {
    recordRefused("spoofed", "unauthenticated_sender");
    const filtered = filterQuarantinedResults(payload());
    assert.equal(filtered.withheldByChannelPolicy, undefined);
    assert.equal(filtered.messages.length, 2);
    assert.equal(filtered.count, 2);
  });

  it("leaves a non-listing payload alone", () => {
    for (const shape of [undefined, null, {}, { success: true }, "text"]) {
      assert.doesNotThrow(() => filterQuarantinedResults(shape));
    }
    assert.deepEqual(filterQuarantinedResults({ success: true }), { success: true });
  });
});

// The loop has to report refusals before the cursor moves, because afterwards the decision
// no longer exists anywhere.
describe("the poll loop reports what it dropped", () => {
  it("reports a real drop before the batch is delivered", async () => {
    const order: string[] = [];
    const controller = new AbortController();

    await runPollLoop(
      {
        listMessages: async () => [
          { messageId: "spoofed", sender: "b@example.com", dateReceived: "2026-07-29T10:01:00Z" },
        ],
        // No provenance: everything falls to `mutable` and drops.
        authCheck: async () => ({ verdict: "unknown" }),
        onAdmitted: async () => {
          order.push("admitted");
        },
        onDropped: async (m) => {
          order.push(`dropped:${m[0]?.decision.reason}`);
        },
        sleep: async () => controller.abort(),
      },
      {
        mailbox: "INBOX",
        limit: 10,
        cursorKey: "k",
        intervalMs: 1,
        classify: { minIdentifierAuthentication: "asserted" },
      },
      { lookup: async () => undefined, register: async () => {} },
      controller.signal,
    );

    assert.deepEqual(order, ["dropped:unauthenticated_sender"]);
  });
});

// The gate reads `node:sqlite`, which does not exist before Node 22.13 — and
// `mcp-server/build.mjs` targets `node18`, so the standalone MCP server is allowed to run
// there. What the channel decided still has to bind it, because the decisions are rows on
// disk written by a different process on a different runtime, not process state.
describe("runtimes without node:sqlite", () => {
  const noSqlite = () => {
    throw new Error("Cannot find module 'node:sqlite'");
  };

  after(() => setSqliteLoaderForTest());

  it("denies reads when decisions exist that it cannot read", () => {
    // The channel's process wrote the store on a newer Node; this one cannot open it.
    recordRefused("<spoofed@example.com>", "unauthenticated_sender");
    closeMailAdmissionForTest();
    setSqliteLoaderForTest(noSqlite);

    assert.throws(
      () => assertMailReadable("anything@example.com", "read"),
      /no node:sqlite.*Node >= 22\.13/s,
      "a runtime that cannot read the store must not wave every message through",
    );
    assert.throws(() => assertMailRepliable("anything@example.com", "reply to"), /no node:sqlite/);
  });

  it("withholds every row from a listing rather than returning unscreened mail", () => {
    recordRefused("<spoofed@example.com>", "unauthenticated_sender");
    closeMailAdmissionForTest();
    setSqliteLoaderForTest(noSqlite);

    const filtered = filterQuarantinedResults(
      { count: 2, messages: [{ messageId: "a@example.com" }, { messageId: "b@example.com" }] },
      { reportWithheld: true },
    );
    assert.deepEqual(filtered.messages, []);
    assert.equal(filtered.withheldByChannelPolicy, 2);
  });

  it("still permits when no store exists, because no decision was ever made", () => {
    // The channel-less case the degrade-open path is for: `store.ts` hard-requires
    // `node:sqlite`, so a runtime without it never ran a channel. Breaking every read here
    // would be a regression with no security benefit.
    setSqliteLoaderForTest(noSqlite);
    process.env.OPENCLAW_STATE_DIR = path.join(tmp, "never-written");

    assert.doesNotThrow(() => assertMailReadable("anything@example.com", "read"));
    assert.doesNotThrow(() => assertMailRepliable("anything@example.com", "reply to"));

    process.env.OPENCLAW_STATE_DIR = tmp;
  });

  it("re-checks the store instead of latching open at first touch", () => {
    // A long-lived MCP server can start before the channel has written anything. Caching
    // "nothing to enforce" then would keep the gate open for the rest of its life.
    process.env.OPENCLAW_STATE_DIR = path.join(tmp, "written-later");
    setSqliteLoaderForTest(noSqlite);
    assert.doesNotThrow(() => assertMailReadable("anything@example.com", "read"));

    // The channel comes up and records a decision, as it would on a newer Node.
    setSqliteLoaderForTest();
    recordRefused("<spoofed@example.com>", "unauthenticated_sender");
    closeMailAdmissionForTest();
    setSqliteLoaderForTest(noSqlite);

    assert.throws(() => assertMailReadable("anything@example.com", "read"), /no node:sqlite/);
    process.env.OPENCLAW_STATE_DIR = tmp;
  });
});
