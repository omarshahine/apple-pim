import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { runPollCycle, runPollLoop, type CursorStore, type PollOptions } from "./poll.ts";
import type { InboundDeps, MailboxMessage, PollCursor } from "./inbound.ts";
import type { MailAuthCheckResult } from "../mail-auth/strength.ts";

const VERIFIED: MailAuthCheckResult = {
  verdict: "verified",
  sender: "operator@example.com",
  checks: {
    dkim: { result: "pass", signingDomain: "example.com", match: true },
    spf: { result: "pass", mailFrom: "operator@example.com", aligned: true, match: true },
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
  return { messageId: id, sender: "Operator <operator@example.com>", dateReceived: date };
}

const OPTIONS: PollOptions = {
  mailbox: "INBOX",
  limit: 25,
  cursorKey: "apple-mail:default",
  classify: {
    allowFrom: ["operator@example.com"],
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
  // Greptile P1: listing newest-first meant a flood of new mail could push an older
  // unprocessed message past the row limit permanently. The page now starts at the cursor
  // and walks forward, so the backlog's oldest end is always what gets read.
  it("pages forward from the cursor rather than grabbing the newest page", async () => {
    const store = memoryStore();
    await store.register(OPTIONS.cursorKey, { lastDateReceived: "2026-07-28T09:00:00.000Z" });
    let sinceSeen: string | undefined;
    const d: InboundDeps = {
      listMessages: async ({ since, limit }) => {
        sinceSeen = since;
        return [msg("old", "2026-07-28T09:30:00.000Z")].slice(0, limit);
      },
      authCheck: async () => VERIFIED,
    };
    await runPollCycle(d, { ...OPTIONS, limit: 2 }, store);
    assert.equal(sinceSeen, "2026-07-28T09:00:00.000Z", "the cursor bounds the listing");
  });

  it("takes the newest page on a cold start, not the whole mailbox history", async () => {
    let sinceSeen: string | undefined = "unset";
    const d: InboundDeps = {
      listMessages: async ({ since }) => {
        sinceSeen = since;
        return [];
      },
      authCheck: async () => VERIFIED,
    };
    const r = await runPollCycle(d, OPTIONS, memoryStore());
    assert.equal(sinceSeen, undefined, "no cursor means no --since, so the CLI's newest page");
    assert.equal(r.truncated, false, "and a cold start is never truncated");
  });

  // A flood cannot bury older mail now: the flood is *newer*, so it sorts behind the
  // backlog and simply waits its turn.
  it("reads the oldest unprocessed mail even when newer mail floods in", async () => {
    const store = memoryStore();
    await store.register(OPTIONS.cursorKey, { lastDateReceived: "2026-07-28T09:00:00.000Z" });
    const pending = msg("legitimate", "2026-07-28T09:30:00.000Z");
    const flood = Array.from({ length: 500 }, (_, i) => msg(`spam${i}`, "2026-07-28T23:00:00.000Z"));
    const d: InboundDeps = {
      // The engine returns oldest-first when `since` is set, which is the contract the
      // CLI now implements.
      listMessages: async ({ limit }) => [pending, ...flood].slice(0, limit),
      authCheck: async () => VERIFIED,
    };
    const r = await runPollCycle(d, { ...OPTIONS, limit: 2 }, store);
    assert.equal(
      r.classified[0]?.message.messageId,
      "legitimate",
      "the pending message is read first, not buried under the flood",
    );
    assert.equal(r.truncated, true, "and the rest is reported as still pending");
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

  // Holding the cursor here was an earlier fix and it was wrong, as Codex pointed out.
  // Listing is newest-first, so a held cursor re-lists and redelivers the same newest page
  // every cycle and *still* never reaches the older mail, because the page can only grow
  // back from now. Advancing turns unbounded duplicate delivery plus loss into loss, once,
  // reported loudly.
  it("advances the cursor on a truncated cycle, bounding loss instead of looping", async () => {
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
    assert.notDeepEqual(
      store.values.get(OPTIONS.cursorKey),
      before,
      "cursor must move, or this page is redelivered forever and the backlog is still lost",
    );
    assert.equal(
      store.values.get(OPTIONS.cursorKey)?.lastDateReceived,
      "2026-07-28T11:00:00.000Z",
    );
  });

  // A truncated cycle must still sleep. An earlier version used `continue`, which skipped
  // the sleep and spun a tight infinite loop; the only symptom was a hanging test run.
  it("reports truncation and still advances, without spinning the loop", async () => {
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
    assert.notDeepEqual(
      store.values.get(OPTIONS.cursorKey),
      seeded,
      "the cursor advances; truncation is reported, not held",
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

// The breaker has to defer, not discard. Holding the cursor costs a re-classification next
// cycle; advancing it would lose an operator's mail to a burst of newsletters.
describe("circuit breaker", () => {
  const message = {
    messageId: "m1",
    sender: "operator@example.com",
    dateReceived: "2026-07-29T10:00:00Z",
  };

  function loopDeps(allowed: boolean) {
    const registered: unknown[] = [];
    const admitted: string[] = [];
    const throttled: { pending: number }[] = [];
    const controller = new AbortController();
    return {
      registered,
      admitted,
      throttled,
      controller,
      run: () =>
        runPollLoop(
          {
            listMessages: async () => [message],
            authCheck: async () => ({
              verdict: "verified" as const,
              sender: "operator@example.com",
              checks: {
                dkim: { result: "pass", signingDomain: "example.com", match: true },
                spf: { result: "pass", mailFrom: "operator@example.com", aligned: true, match: true },
              },
            }),
            onAdmitted: async (m) => {
              admitted.push(...m.map((e) => e.message.messageId));
            },
            checkBudget: () => ({ allowed, window: "hour", retryAtMs: 1 }),
            onThrottled: (p) => throttled.push(p),
            sleep: async () => controller.abort(),
          },
          {
            mailbox: "INBOX",
            limit: 10,
            cursorKey: "k",
            intervalMs: 1,
            classify: { minIdentifierAuthentication: "asserted" },
          },
          {
            lookup: async () => undefined,
            register: async (_k, v) => {
              registered.push(v);
            },
          },
          controller.signal,
        ),
    };
  }

  it("delivers and advances the cursor when the breaker is closed", async () => {
    const t = loopDeps(true);
    await t.run();
    assert.deepEqual(t.admitted, ["m1"]);
    assert.equal(t.registered.length, 1, "cursor persisted");
    assert.deepEqual(t.throttled, []);
  });

  it("holds the cursor and delivers nothing when the breaker is open", async () => {
    const t = loopDeps(false);
    await t.run();
    assert.deepEqual(t.admitted, [], "no agent run");
    assert.deepEqual(t.registered, [], "cursor held, so the batch is retried not lost");
    assert.deepEqual(t.throttled, [{ window: "hour", retryAtMs: 1, pending: 1 }]);
  });

  it("does not report throttling when there is nothing to deliver", async () => {
    const controller = new AbortController();
    const throttled: unknown[] = [];
    await runPollLoop(
      {
        listMessages: async () => [],
        authCheck: async () => ({ verdict: "verified" as const }),
        onAdmitted: async () => {},
        checkBudget: () => ({ allowed: false, window: "hour" }),
        onThrottled: (p) => throttled.push(p),
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
    assert.deepEqual(throttled, []);
  });
});

// Codex, second pass: holding the whole cursor on a partial batch replayed everything
// already delivered, and could starve the undelivered tail forever if the batch kept
// exceeding the budget. Oldest-first dispatch makes a partial cursor expressible.
describe("partial delivery", () => {
  function boundedSignal(cycles: number) {
    const controller = new AbortController();
    let seen = 0;
    return {
      signal: controller.signal,
      sleep: async () => {
        seen += 1;
        if (seen >= cycles) {
          controller.abort();
        }
      },
    };
  }

  it("hands messages to the delivery callback oldest first", async () => {
    const { signal, sleep } = boundedSignal(1);
    const seen: string[] = [];
    await runPollLoop(
      {
        listMessages: async () => [
          msg("newest", "2026-07-28T12:00:00.000Z"),
          msg("oldest", "2026-07-28T10:00:00.000Z"),
          msg("middle", "2026-07-28T11:00:00.000Z"),
        ],
        authCheck: async () => VERIFIED,
        onAdmitted: (messages) => {
          seen.push(...messages.map((m) => m.message.messageId));
        },
        sleep,
      },
      { ...OPTIONS, intervalMs: 1 },
      memoryStore(),
      signal,
    );
    assert.deepEqual(seen, ["oldest", "middle", "newest"]);
  });

  it("advances the cursor through the delivered prefix only", async () => {
    const store = memoryStore();
    const { signal, sleep } = boundedSignal(1);
    await runPollLoop(
      {
        listMessages: async () => [
          msg("a", "2026-07-28T10:00:00.000Z"),
          msg("b", "2026-07-28T11:00:00.000Z"),
          msg("c", "2026-07-28T12:00:00.000Z"),
        ],
        authCheck: async () => VERIFIED,
        // Budget runs out after two.
        onAdmitted: () => ({ completed: 2 }),
        sleep,
      },
      { ...OPTIONS, intervalMs: 1 },
      store,
      signal,
    );
    const cursor = store.values.get(OPTIONS.cursorKey);
    assert.equal(
      cursor?.lastDateReceived,
      "2026-07-28T11:00:00.000Z",
      "cursor sits at the last delivered message, not the last listed one",
    );
  });

  it("redelivers neither the prefix nor loses the suffix across cycles", async () => {
    const store = memoryStore();
    const { signal, sleep } = boundedSignal(2);
    const delivered: string[] = [];
    let cycle = 0;
    await runPollLoop(
      {
        listMessages: async () => [
          msg("a", "2026-07-28T10:00:00.000Z"),
          msg("b", "2026-07-28T11:00:00.000Z"),
          msg("c", "2026-07-28T12:00:00.000Z"),
        ],
        authCheck: async () => VERIFIED,
        onAdmitted: (messages) => {
          cycle += 1;
          const budget = cycle === 1 ? 2 : messages.length;
          delivered.push(...messages.slice(0, budget).map((m) => m.message.messageId));
          return { completed: budget };
        },
        sleep,
      },
      { ...OPTIONS, intervalMs: 1 },
      store,
      signal,
    );
    assert.deepEqual(delivered, ["a", "b", "c"], "each message delivered exactly once");
  });
});

// Codex, third pass: cursorThrough built a cursor from the delivered slice alone. A prefix
// of only undated messages then produced no watermark at all, resetting the cursor to cold
// and redelivering every dated message in the mailbox.
describe("partial cursor merges with the previous one", () => {
  function boundedSignal(cycles: number) {
    const controller = new AbortController();
    let seen = 0;
    return {
      signal: controller.signal,
      sleep: async () => {
        seen += 1;
        if (seen >= cycles) {
          controller.abort();
        }
      },
    };
  }

  async function runOnce(store: ReturnType<typeof memoryStore>, messages: MailboxMessage[], completed: number) {
    const { signal, sleep } = boundedSignal(1);
    await runPollLoop(
      {
        listMessages: async () => messages,
        authCheck: async () => VERIFIED,
        onAdmitted: () => ({ completed }),
        sleep,
      },
      { ...OPTIONS, intervalMs: 1 },
      store,
      signal,
    );
    return store.values.get(OPTIONS.cursorKey);
  }

  it("keeps the existing watermark when the delivered prefix is undated", async () => {
    const store = memoryStore();
    await store.register(OPTIONS.cursorKey, { lastDateReceived: "2026-07-28T09:00:00.000Z" });
    const undated = { messageId: "u1", sender: "a@example.com" } as MailboxMessage;
    const cursor = await runOnce(store, [undated, msg("dated", "2026-07-28T12:00:00.000Z")], 1);
    assert.equal(
      cursor?.lastDateReceived,
      "2026-07-28T09:00:00.000Z",
      "watermark must not be erased by an undated-only prefix",
    );
    assert.deepEqual(cursor?.seenUndated, ["u1"]);
  });

  it("never moves the watermark backwards", async () => {
    const store = memoryStore();
    await store.register(OPTIONS.cursorKey, { lastDateReceived: "2026-07-28T15:00:00.000Z" });
    const cursor = await runOnce(store, [msg("old", "2026-07-28T16:00:00.000Z")], 0);
    assert.equal(cursor?.lastDateReceived, "2026-07-28T15:00:00.000Z");
  });

  it("carries prior undated ids forward", async () => {
    const store = memoryStore();
    await store.register(OPTIONS.cursorKey, {
      lastDateReceived: "2026-07-28T09:00:00.000Z",
      seenUndated: ["older-undated"],
    });
    const undated = { messageId: "u2", sender: "a@example.com" } as MailboxMessage;
    const cursor = await runOnce(store, [undated, msg("d", "2026-07-28T12:00:00.000Z")], 1);
    assert.deepEqual(cursor?.seenUndated, ["older-undated", "u2"]);
  });
});
