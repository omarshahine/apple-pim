import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { foldReply, MAX_THREADS, ThreadRecords, type ThreadRecordStore } from "./thread-store.ts";
import { decideThreadReply, type AgentThreadRecord } from "./thread.ts";

function fakeStore() {
  const data = new Map<string, AgentThreadRecord[]>();
  const store: ThreadRecordStore = {
    lookup: async (key) => data.get(key),
    register: async (key, value) => {
      data.set(key, value);
    },
  };
  return { store, data };
}

describe("foldReply", () => {
  it("records the inbound anchor and the recipient", () => {
    const [record] = foldReply([], {
      inboundMessageId: "<m1@example.com>",
      recipients: ["Operator@example.com"],
    });
    assert.deepEqual(record?.inboundAnchorIds, ["m1@example.com"]);
    assert.deepEqual(record?.addressedRecipients, ["operator@example.com"]);
    // Mail.app reports no id, so there is nothing to claim here and it does not pretend.
    assert.deepEqual(record?.sentMessageIds, []);
  });

  it("keeps the agent's own Message-ID when the transport reports one", () => {
    const [record] = foldReply([], {
      inboundMessageId: "m1@example.com",
      sentMessageId: "<agent-1@lobster.example>",
      recipients: ["operator@example.com"],
    });
    assert.deepEqual(record?.sentMessageIds, ["agent-1@lobster.example"]);
  });

  // Without this a long exchange writes one record per turn and evicts every other thread.
  it("merges a second reply in the same thread instead of appending", () => {
    let records = foldReply([], {
      inboundMessageId: "m1@example.com",
      sentMessageId: "agent-1@lobster.example",
      recipients: ["operator@example.com"],
    });
    records = foldReply(records, {
      inboundMessageId: "m1@example.com",
      sentMessageId: "agent-2@lobster.example",
      recipients: ["family@example.com"],
    });
    assert.equal(records.length, 1);
    assert.deepEqual(records[0]?.sentMessageIds, [
      "agent-1@lobster.example",
      "agent-2@lobster.example",
    ]);
    assert.deepEqual(records[0]?.addressedRecipients, ["operator@example.com", "family@example.com"]);
  });

  it("recognizes the same thread through the agent's own id when the anchor differs", () => {
    const first = foldReply([], {
      inboundMessageId: "m1@example.com",
      sentMessageId: "agent-1@lobster.example",
      recipients: ["operator@example.com"],
    });
    // Next turn: a new inbound message, but the same agent id already on record.
    const merged = foldReply(first, {
      inboundMessageId: "m2@example.com",
      sentMessageId: "agent-1@lobster.example",
      recipients: ["operator@example.com"],
    });
    assert.equal(merged.length, 1);
    assert.deepEqual(merged[0]?.inboundAnchorIds, ["m1@example.com", "m2@example.com"]);
  });

  it("starts a separate record for an unrelated thread", () => {
    const records = foldReply(
      foldReply([], { inboundMessageId: "m1@example.com", recipients: ["a@example.com"] }),
      { inboundMessageId: "m2@example.com", recipients: ["b@example.com"] },
    );
    assert.equal(records.length, 2);
  });

  it("bounds the set, dropping the least recently active thread", () => {
    let records: AgentThreadRecord[] = [];
    for (let i = 0; i < MAX_THREADS + 5; i += 1) {
      records = foldReply(records, {
        inboundMessageId: `m${i}@example.com`,
        recipients: ["a@example.com"],
      });
    }
    assert.equal(records.length, MAX_THREADS);
    assert.deepEqual(records[0]?.inboundAnchorIds, ["m5@example.com"]);
  });

  it("normalizes brackets and case on both sides", () => {
    const [record] = foldReply([], {
      inboundMessageId: "  <M1@Example.COM>  ",
      recipients: ["  Operator@example.com "],
    });
    assert.deepEqual(record?.inboundAnchorIds, ["m1@example.com"]);
    assert.deepEqual(record?.addressedRecipients, ["operator@example.com"]);
  });
});

describe("ThreadRecords", () => {
  it("starts empty, which denies every claim", async () => {
    const { store } = fakeStore();
    const records = new ThreadRecords(store, "apple-mail:default");
    await records.hydrate();
    assert.deepEqual(records.all(), []);
    assert.equal(
      decideThreadReply({ inReplyTo: "anything@example.com", senderAddress: "a@b.com" }, records.all())
        .permitted,
      false,
    );
  });

  it("survives a restart", async () => {
    const { store } = fakeStore();
    const first = new ThreadRecords(store, "apple-mail:default");
    await first.hydrate();
    await first.record({ inboundMessageId: "m1@example.com", recipients: ["operator@example.com"] });

    const second = new ThreadRecords(store, "apple-mail:default");
    await second.hydrate();
    assert.equal(
      decideThreadReply(
        { references: ["<m1@example.com>"], senderAddress: "operator@example.com" },
        second.all(),
      ).permitted,
      true,
    );
  });

  it("keeps accounts apart", async () => {
    const { store } = fakeStore();
    const a = new ThreadRecords(store, "apple-mail:work");
    await a.hydrate();
    await a.record({ inboundMessageId: "m1@example.com", recipients: ["operator@example.com"] });

    const b = new ThreadRecords(store, "apple-mail:personal");
    await b.hydrate();
    assert.deepEqual(b.all(), []);
  });
});

// The end-to-end shape of the rule: reply to someone, and their answer becomes permitted.
// This is what the record set exists to make true, and what an empty one made impossible.
describe("the loop the store closes", () => {
  it("permits a correspondent's answer only after the agent replied to them", async () => {
    const { store } = fakeStore();
    const records = new ThreadRecords(store, "apple-mail:default");
    await records.hydrate();

    const answer = { references: ["m1@example.com"], senderAddress: "correspondent@example.com" };
    assert.equal(decideThreadReply(answer, records.all()).permitted, false, "before replying");

    await records.record({
      inboundMessageId: "m1@example.com",
      recipients: ["correspondent@example.com"],
    });
    const after = decideThreadReply(answer, records.all());
    assert.equal(after.permitted, true, "after replying");
    assert.equal(after.matchedAnchor, "inbound_anchor");
  });

  it("does not extend that permission to a bystander who learned the anchor", async () => {
    const { store } = fakeStore();
    const records = new ThreadRecords(store, "apple-mail:default");
    await records.hydrate();
    await records.record({
      inboundMessageId: "m1@example.com",
      recipients: ["correspondent@example.com"],
    });

    // Same claimed thread, different sender. Anchors select a thread; they do not grant entry.
    const decision = decideThreadReply(
      { references: ["m1@example.com"], senderAddress: "bystander@example.com" },
      records.all(),
    );
    assert.equal(decision.permitted, false);
    assert.equal(decision.reason, "sender_not_addressed_in_thread");
  });
});
