import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { decideThreadReply, type AgentThreadRecord } from "./thread.ts";

const record: AgentThreadRecord = {
  sentMessageIds: ["<agent-root@lobster.local>", "<agent-2@lobster.local>"],
  addressedRecipients: ["friend@example.com"],
};

describe("thread reply permission", () => {
  it("permits a reply from an addressed participant to an agent-sent message", () => {
    const d = decideThreadReply(
      { inReplyTo: "<agent-root@lobster.local>", senderAddress: "friend@example.com" },
      [record],
    );
    assert.equal(d.permitted, true);
    assert.equal(d.reason, "thread_originated_by_agent");
  });

  it("denies a message with no thread claim at all", () => {
    const d = decideThreadReply({ senderAddress: "friend@example.com" }, [record]);
    assert.equal(d.permitted, false);
    assert.equal(d.reason, "no_thread_claim");
  });

  // The P1 this rule exists to close: References and In-Reply-To are sender-controlled.
  it("denies a forged claim against a Message-ID the agent never sent", () => {
    const d = decideThreadReply(
      { inReplyTo: "<invented-by-attacker@evil.example>", senderAddress: "friend@example.com" },
      [record],
    );
    assert.equal(d.permitted, false);
    assert.equal(d.reason, "claimed_parent_not_sent_by_agent");
  });

  // The subtler half: a real agent Message-ID, leaked to someone never addressed.
  it("denies a real agent Message-ID claimed by a non-participant", () => {
    const d = decideThreadReply(
      { inReplyTo: "<agent-root@lobster.local>", senderAddress: "attacker@evil.example" },
      [record],
    );
    assert.equal(d.permitted, false);
    assert.equal(d.reason, "sender_not_addressed_in_thread");
  });

  it("resolves a claim through the References chain, not just In-Reply-To", () => {
    const d = decideThreadReply(
      {
        references: ["<unrelated@example.com>", "<agent-2@lobster.local>"],
        senderAddress: "friend@example.com",
      },
      [record],
    );
    assert.equal(d.permitted, true);
    assert.equal(d.matchedMessageId, "agent-2@lobster.local");
  });

  it("denies everything when the agent has sent nothing", () => {
    const d = decideThreadReply(
      { inReplyTo: "<agent-root@lobster.local>", senderAddress: "friend@example.com" },
      [],
    );
    assert.equal(d.permitted, false);
  });

  it("normalizes angle brackets and case on both sides", () => {
    const d = decideThreadReply(
      { inReplyTo: "AGENT-ROOT@LOBSTER.LOCAL", senderAddress: "  Friend@Example.com " },
      [record],
    );
    assert.equal(d.permitted, true);
  });

  it("resolves across records instead of stopping at the first ID match", () => {
    // Greptile P2: a References chain can name IDs from several agent threads. Stopping at
    // the first match denied a legitimate participant whose record sorted later.
    const first: AgentThreadRecord = {
      sentMessageIds: ["<agent-a@lobster.local>"],
      addressedRecipients: ["someone-else@example.com"],
    };
    const second: AgentThreadRecord = {
      sentMessageIds: ["<agent-b@lobster.local>"],
      addressedRecipients: ["friend@example.com"],
    };
    const d = decideThreadReply(
      {
        references: ["<agent-a@lobster.local>", "<agent-b@lobster.local>"],
        senderAddress: "friend@example.com",
      },
      [first, second],
    );
    assert.equal(d.permitted, true);
    assert.equal(d.matchedMessageId, "agent-b@lobster.local");
  });

  it("does not let one thread's permission leak into another", () => {
    const other: AgentThreadRecord = {
      sentMessageIds: ["<other-root@lobster.local>"],
      addressedRecipients: ["colleague@example.com"],
    };
    // friend@ is addressed in `record`, not in `other`; claiming other's root must fail.
    const d = decideThreadReply(
      { inReplyTo: "<other-root@lobster.local>", senderAddress: "friend@example.com" },
      [record, other],
    );
    assert.equal(d.permitted, false);
    assert.equal(d.reason, "sender_not_addressed_in_thread");
  });
});
