import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { runPollCycle, runPollLoop, type CursorStore, type PollOptions } from "./poll.ts";
import type { InboundDeps, MailboxMessage, PollCursor } from "./inbound.ts";
import type { MailAuthCheckResult } from "../mail-auth/strength.ts";

const VERIFIED: MailAuthCheckResult = {
  verdict: "verified",
  sender: "omar@shahine.com",
  checks: {
    dkim: { result: "pass", signingDomain: "shahine.com", match: true },
    spf: { result: "pass", mailFrom: "omar@shahine.com", aligned: true, match: true },
  },
};

function memoryStore(): CursorStore & { values: Map<string, PollCursor> } {
  const values = new Map<string, PollCursor>();
  return {
    values,
    lookup: async (key) => values.get(key),
    register: async (key, value) => {
      values.set(key, value);
    },
  };
}

function msg(id: string, date = "2026-07-28T10:00:00.000Z"): MailboxMessage {
  return { messageId: id, sender: "Omar <omar@shahine.com>", dateReceived: date };
}

const OPTIONS: PollOptions = {
  mailbox: "INBOX",
  limit: 25,
  cursorKey: "apple-mail:default",
  classify: {
    allowFrom: ["omar@shahine.com"],
    minIdentifierAuthentication: "verified",
  },
};

function deps(messages: MailboxMessage[][]): InboundDeps & { calls: number } {
  let calls = 0;
  return {
    get calls() {
      return calls;
    },
    listMessages: async () => messages[Math.min(calls++, messages.length - 1)] ?? [],
    authCheck: async () => VERIFIED,
  } as InboundDeps & { calls: number };
}

describe("runPollCycle", () => {
  it("classifies fresh messages and returns a cursor without persisting it", async () => {
    const store = memoryStore();
    const r = await runPollCycle(deps([[msg("a")]]), OPTIONS, store);
    assert.equal(r.classified.length, 1);
    assert.equal(r.classified[0]?.decision.admission, "dispatch");
    // Persisting is the loop's job, gated on delivery.
    assert.equal(store.values.has(OPTIONS.cursorKey), false);
  });

  it("does not reprocess across cycles once the cursor is stored", async () => {
    const store = memoryStore();
    const d = deps([[msg("a")], [msg("a")]]);
    const first = await runPollCycle(d, OPTIONS, store);
    await store.register(OPTIONS.cursorKey, first.cursor);
    const second = await runPollCycle(d, OPTIONS, store);
    assert.deepEqual(second.classified, []);
  });

  it("keeps separate cursors per key, so accounts do not shadow each other", async () => {
    const store = memoryStore();
    const first = await runPollCycle(deps([[msg("a")]]), OPTIONS, store);
    await store.register(OPTIONS.cursorKey, first.cursor);
    const other = await runPollCycle(deps([[msg("a")]]), { ...OPTIONS, cursorKey: "other" }, store);
    assert.equal(other.classified.length, 1);
  });

  // Greptile P1: newest-first paging stops short of the cursor when a burst arrives, and
  // advancing the watermark from that subset would skip the rest permanently.
  it("widens the page to reach back past the cursor", async () => {
    const store = memoryStore();
    await store.register(OPTIONS.cursorKey, { lastDateReceived: "2026-07-28T09:00:00.000Z" });
    const burst = Array.from({ length: 7 }, (_, i) =>
      msg(`b${i}`, `2026-07-28T10:0${i}:00.000Z`),
    );
    let lastLimit = 0;
    const d: InboundDeps = {
      listMessages: async ({ limit }) => {
        lastLimit = limit;
        return burst.slice(-limit);
      },
      authCheck: async () => VERIFIED,
    };
    const r = await runPollCycle(d, { ...OPTIONS, limit: 2, maxLimit: 64 }, store);
    assert.ok(lastLimit > 2, "should have widened past the initial limit");
    assert.equal(r.classified.length, 7);
    assert.equal(r.truncated, false);
  });

  it("flags truncation instead of silently skipping when the ceiling is hit", async () => {
    const store = memoryStore();
    await store.register(OPTIONS.cursorKey, { lastDateReceived: "2026-07-28T09:00:00.000Z" });
    const d: InboundDeps = {
      // Always returns a full page newer than the cursor: the ceiling is reached.
      listMessages: async ({ limit }) =>
        Array.from({ length: limit }, (_, i) => msg(`x${i}`, `2026-07-28T11:00:00.000Z`)),
      authCheck: async () => VERIFIED,
    };
    const r = await runPollCycle(d, { ...OPTIONS, limit: 2, maxLimit: 8 }, store);
    assert.equal(r.truncated, true);
  });

  it("takes the page as-is on a cold cursor rather than scanning history", async () => {
    const store = memoryStore();
    const d: InboundDeps = {
      listMessages: async ({ limit }) => Array.from({ length: limit }, (_, i) => msg(`c${i}`)),
      authCheck: async () => VERIFIED,
    };
    const r = await runPollCycle(d, { ...OPTIONS, limit: 3, maxLimit: 64 }, store);
    assert.equal(r.classified.length, 3);
    assert.equal(r.truncated, false);
  });
});

describe("runPollLoop", () => {
  /** Runs the loop for a fixed number of cycles, then aborts. */
  function boundedSignal(cycles: number) {
    const controller = new AbortController();
    let seen = 0;
    const sleep = async () => {
      seen += 1;
      if (seen >= cycles) {
        controller.abort();
      }
    };
    return { signal: controller.signal, sleep };
  }

  it("hands admitted messages to the consumer and withholds dropped ones", async () => {
    const store = memoryStore();
    const { signal, sleep } = boundedSignal(1);
    const admitted: string[] = [];
    const unauthenticated: MailAuthCheckResult = { verdict: "unknown", sender: "x@example.com" };
    await runPollLoop(
      {
        listMessages: async () => [msg("a"), msg("b")],
        authCheck: async (id) => (id === "a" ? VERIFIED : unauthenticated),
        onAdmitted: (messages) => {
          admitted.push(...messages.map((m) => m.message.messageId));
        },
        sleep,
      },
      { ...OPTIONS, intervalMs: 1 },
      store,
      signal,
    );
    assert.deepEqual(admitted, ["a"]);
  });

  it("does not call the consumer when a cycle admits nothing", async () => {
    const store = memoryStore();
    const { signal, sleep } = boundedSignal(1);
    let called = 0;
    await runPollLoop(
      {
        listMessages: async () => [],
        authCheck: async () => VERIFIED,
        onAdmitted: () => {
          called += 1;
        },
        sleep,
      },
      { ...OPTIONS, intervalMs: 1 },
      store,
      signal,
    );
    assert.equal(called, 0);
  });

  // A background source must not go quiet forever because one poll threw.
  it("survives a failing cycle and keeps polling", async () => {
    const store = memoryStore();
    const { signal, sleep } = boundedSignal(3);
    const errors: unknown[] = [];
    let attempt = 0;
    const admitted: string[] = [];
    await runPollLoop(
      {
        listMessages: async () => {
          attempt += 1;
          if (attempt === 1) {
            throw new Error("mailbox unavailable");
          }
          return [msg("a")];
        },
        authCheck: async () => VERIFIED,
        onAdmitted: (messages) => {
          admitted.push(...messages.map((m) => m.message.messageId));
        },
        onError: (error) => errors.push(error),
        sleep,
      },
      { ...OPTIONS, intervalMs: 1 },
      store,
      signal,
    );
    assert.equal(errors.length, 1);
    assert.deepEqual(admitted, ["a"]);
  });

  // Greptile P1: the cursor used to advance inside the cycle, so a delivery failure
  // permanently skipped that batch.
  it("does not advance the cursor when delivery fails", async () => {
    const store = memoryStore();
    const { signal, sleep } = boundedSignal(1);
    await runPollLoop(
      {
        listMessages: async () => [msg("a")],
        authCheck: async () => VERIFIED,
        onAdmitted: () => {
          throw new Error("dispatch failed");
        },
        onError: () => {},
        sleep,
      },
      { ...OPTIONS, intervalMs: 1 },
      store,
      signal,
    );
    assert.equal(store.values.has(OPTIONS.cursorKey), false);
  });

  it("redelivers the batch on the next cycle after a delivery failure", async () => {
    const store = memoryStore();
    const { signal, sleep } = boundedSignal(2);
    const delivered: string[] = [];
    let attempt = 0;
    await runPollLoop(
      {
        listMessages: async () => [msg("a")],
        authCheck: async () => VERIFIED,
        onAdmitted: (messages) => {
          attempt += 1;
          if (attempt === 1) {
            throw new Error("dispatch failed");
          }
          delivered.push(...messages.map((m) => m.message.messageId));
        },
        onError: () => {},
        sleep,
      },
      { ...OPTIONS, intervalMs: 1 },
      store,
      signal,
    );
    assert.deepEqual(delivered, ["a"]);
  });

  // Greptile P1: reporting truncation was not enough; the cursor still advanced past the
  // mail still sitting behind the ceiling.
  it("does not advance the cursor on a truncated cycle", async () => {
    const store = memoryStore();
    await store.register(OPTIONS.cursorKey, { lastDateReceived: "2026-07-28T09:00:00.000Z" });
    const before = store.values.get(OPTIONS.cursorKey);
    const { signal, sleep } = boundedSignal(1);
    let truncations = 0;
    await runPollLoop(
      {
        listMessages: async ({ limit }) =>
          Array.from({ length: limit }, (_, i) => msg(`x${i}`, "2026-07-28T11:00:00.000Z")),
        authCheck: async () => VERIFIED,
        onAdmitted: () => {},
        onTruncated: () => {
          truncations += 1;
        },
        sleep,
      },
      { ...OPTIONS, limit: 2, maxLimit: 8, intervalMs: 1 },
      store,
      signal,
    );
    assert.equal(truncations, 1);
    assert.deepEqual(store.values.get(OPTIONS.cursorKey), before);
  });

  // A truncated cycle must still sleep. An earlier version used `continue`, which skipped
  // the sleep and spun a tight infinite loop; the only symptom was a hanging test run.
  it("holds the cursor on truncation without spinning the loop", async () => {
    const store = memoryStore();
    // Seed a prior cursor: truncation is only possible once there is a watermark to fall
    // short of. A cold start deliberately takes the page as-is.
    await store.register(OPTIONS.cursorKey, { lastDateReceived: "2026-07-28T09:00:00.000Z" });
    const seeded = store.values.get(OPTIONS.cursorKey);
    const controller = new AbortController();
    let sleeps = 0;
    let cycles = 0;
    await runPollLoop(
      {
        listMessages: async ({ limit }) => {
          cycles += 1;
          if (cycles > 20) {
            throw new Error("loop spun without sleeping");
          }
          // Always a full page newer than the cursor: permanently truncated.
          return Array.from({ length: limit }, (_, i) => msg(`t${i}`, "2026-07-28T11:00:00.000Z"));
        },
        authCheck: async () => VERIFIED,
        onAdmitted: () => {},
        sleep: async () => {
          sleeps += 1;
          if (sleeps >= 2) {
            controller.abort();
          }
        },
      },
      { ...OPTIONS, limit: 2, maxLimit: 8, intervalMs: 1 },
      store,
      controller.signal,
    );
    assert.equal(sleeps, 2, "each truncated cycle must reach the sleep");
    assert.deepEqual(
      store.values.get(OPTIONS.cursorKey),
      seeded,
      "cursor must not advance past a truncated page",
    );
  });

  it("stops immediately when already aborted", async () => {
    const store = memoryStore();
    const controller = new AbortController();
    controller.abort();
    let listed = 0;
    await runPollLoop(
      {
        listMessages: async () => {
          listed += 1;
          return [];
        },
        authCheck: async () => VERIFIED,
        onAdmitted: () => {},
        sleep: async () => {},
      },
      { ...OPTIONS, intervalMs: 1 },
      store,
      controller.signal,
    );
    assert.equal(listed, 0);
  });

  it("does not overlap cycles", async () => {
    const store = memoryStore();
    const { signal, sleep } = boundedSignal(3);
    let inFlight = 0;
    let maxInFlight = 0;
    await runPollLoop(
      {
        listMessages: async () => {
          inFlight += 1;
          maxInFlight = Math.max(maxInFlight, inFlight);
          await new Promise((resolve) => setTimeout(resolve, 1));
          inFlight -= 1;
          return [];
        },
        authCheck: async () => VERIFIED,
        onAdmitted: () => {},
        sleep,
      },
      { ...OPTIONS, intervalMs: 1 },
      store,
      signal,
    );
    assert.equal(maxInFlight, 1);
  });
});
