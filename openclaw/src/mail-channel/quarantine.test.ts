/**
 * The gate that keeps envelope-only prompting from becoming a bypass.
 *
 * The channel stopped handing the agent message bodies and started handing it ids. That is
 * the right split, but it moves the security boundary onto the tool: if `apple_pim_mail`
 * will read any id, then a message the channel dropped as spoofed can still be read by an
 * agent that learns its id.
 */

import { describe, it, beforeEach } from "node:test";
import { strict as assert } from "node:assert";
import {
  assertMailReadable,
  loadQuarantine,
  quarantineMessage,
  quarantineReason,
  quarantineSnapshot,
  filterQuarantinedResults,
  resetQuarantine,
} from "../../lib/mail-quarantine.js";
import { runPollLoop } from "./poll.ts";

beforeEach(() => resetQuarantine());

describe("mail quarantine", () => {
  it("lets an unlisted message through untouched", () => {
    assert.doesNotThrow(() => assertMailReadable("anything@example.com", "read"));
  });

  it("refuses a message the channel dropped, naming why", () => {
    quarantineMessage("acct", "<spoof@example.com>", "unauthenticated_sender");
    assert.throws(
      () => assertMailReadable("spoof@example.com", "read"),
      /did not admit it \(unauthenticated_sender\)/,
    );
  });

  it("refuses attachments from it too", () => {
    quarantineMessage("acct", "spoof@example.com", "identifier_authentication_too_weak");
    assert.throws(
      () => assertMailReadable("spoof@example.com", "save an attachment from"),
      /Refusing to save an attachment from/,
    );
  });

  it("matches regardless of brackets, case, or padding", () => {
    quarantineMessage("acct", "<Spoof@Example.COM>", "unauthenticated_sender");
    for (const variant of ["spoof@example.com", "<spoof@example.com>", "  SPOOF@EXAMPLE.com "]) {
      assert.equal(quarantineReason(variant), "unauthenticated_sender", variant);
    }
  });

  it("ignores an empty id rather than quarantining everything", () => {
    quarantineMessage("acct", "", "unauthenticated_sender");
    quarantineMessage("acct", "   ", "unauthenticated_sender");
    assert.deepEqual(quarantineSnapshot("acct"), []);
    assert.doesNotThrow(() => assertMailReadable("", "read"));
  });

  // A dropped message is never reclassified, because the cursor moves past it. If the set
  // did not survive a restart the refusal would silently expire.
  it("round-trips through storage", () => {
    quarantineMessage("acct", "a@example.com", "unauthenticated_sender");
    quarantineMessage("acct", "b@example.com", "self_addressed");
    const saved = quarantineSnapshot("acct");

    resetQuarantine();
    assert.doesNotThrow(() => assertMailReadable("a@example.com", "read"));

    loadQuarantine("acct", saved);
    assert.throws(() => assertMailReadable("a@example.com", "read"));
    assert.throws(() => assertMailReadable("b@example.com", "read"));
  });

  it("survives an absent stored value", () => {
    assert.doesNotThrow(() => loadQuarantine("acct", undefined));
    assert.deepEqual(quarantineSnapshot("acct"), []);
  });

  // Codex: one shared map meant a second account starting up replaced the first account's
  // set, silently un-quarantining everything it had refused.
  it("keeps accounts separate, and starting one does not clear another", () => {
    quarantineMessage("work", "w@example.com", "unauthenticated_sender");
    quarantineMessage("personal", "p@example.com", "unauthenticated_sender");

    // Personal restarts and rehydrates. Work's refusals must survive.
    loadQuarantine("personal", [["p@example.com", "unauthenticated_sender"]]);
    assert.throws(() => assertMailReadable("w@example.com", "read"));
    assert.throws(() => assertMailReadable("p@example.com", "read"));
    assert.deepEqual(quarantineSnapshot("work"), [["w@example.com", "unauthenticated_sender"]]);
  });

  // The tool is handed an id and nothing else, and both accounts share one mailbox and one
  // agent, so a refusal by either has to bind everywhere.
  it("refuses across accounts, since the tool is not account-scoped", () => {
    quarantineMessage("work", "w@example.com", "unauthenticated_sender");
    assert.equal(quarantineReason("w@example.com"), "unauthenticated_sender");
  });
});

// Codex: blocking `get` alone left `search --field content` as a content oracle. The agent
// probes for a phrase and learns from the hit whether a quarantined message contains it,
// without ever reading a body. Listings leak the envelope the same way.
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
    quarantineMessage("acct", "spoofed", "unauthenticated_sender");
    const filtered = filterQuarantinedResults(payload());
    assert.deepEqual(
      filtered.messages.map((m: { messageId: string }) => m.messageId),
      ["ok1", "ok2"],
    );
    assert.equal(filtered.count, 2, "count must match what was returned");
  });

  // A quietly short listing reads as an empty mailbox, so listings say what was withheld.
  it("reports the withheld count when asked", () => {
    quarantineMessage("acct", "spoofed", "unauthenticated_sender");
    assert.equal(
      filterQuarantinedResults(payload(), { reportWithheld: true }).withheldByChannelPolicy,
      1,
    );
  });

  // Codex, second pass: the count is itself an oracle for a search. "1 withheld" for
  // `--field content "secret phrase"` confirms the phrase is in quarantined mail without
  // returning it, which is the leak filtering the rows was meant to close.
  it("stays silent about the count by default, since a query-dependent count leaks", () => {
    quarantineMessage("acct", "spoofed", "unauthenticated_sender");
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

// The behaviour that actually matters: the loop has to report refusals, and it has to do it
// before the cursor moves, because afterwards the decision no longer exists anywhere.
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
