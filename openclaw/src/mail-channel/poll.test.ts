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
    allowlisted: true,
    minIdentifierAuthentication: "verified",
    selfAddressed: false,
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
  it("classifies fresh messages and persists the cursor", async () => {
    const store = memoryStore();
    const r = await runPollCycle(deps([[msg("a")]]), OPTIONS, store);
    assert.equal(r.classified.length, 1);
    assert.equal(r.classified[0]?.decision.admission, "dispatch");
    assert.ok(store.values.has(OPTIONS.cursorKey));
  });

  it("does not reprocess across cycles using the persisted cursor", async () => {
    const store = memoryStore();
    const d = deps([[msg("a")], [msg("a")]]);
    await runPollCycle(d, OPTIONS, store);
    const second = await runPollCycle(d, OPTIONS, store);
    assert.deepEqual(second.classified, []);
  });

  it("keeps separate cursors per key, so accounts do not shadow each other", async () => {
    const store = memoryStore();
    await runPollCycle(deps([[msg("a")]]), OPTIONS, store);
    const other = await runPollCycle(deps([[msg("a")]]), { ...OPTIONS, cursorKey: "other" }, store);
    assert.equal(other.classified.length, 1);
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
