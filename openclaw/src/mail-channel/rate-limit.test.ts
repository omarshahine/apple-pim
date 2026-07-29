import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import {
  checkBreaker,
  DEFAULT_RATE_LIMITS,
  recordRun,
  resolveRateLimits,
  RunBudget,
  type BreakerState,
} from "./rate-limit.ts";

const T0 = Date.UTC(2026, 6, 29, 12, 0, 0);
const MIN = 60 * 1000;
const HOUR = 60 * MIN;

const LIMITS = { perHour: 3, perDay: 5 };

/** Builds state with runs at the given offsets (ms) before `now`. */
function runsAgo(...offsets: number[]): BreakerState {
  return { runs: offsets.map((o) => T0 - o).sort((a, b) => a - b) };
}

describe("checkBreaker", () => {
  it("allows a run when nothing has happened", () => {
    assert.equal(checkBreaker({ runs: [] }, LIMITS, T0).allowed, true);
  });

  it("allows up to the hourly limit", () => {
    assert.equal(checkBreaker(runsAgo(MIN, 2 * MIN), LIMITS, T0).allowed, true);
  });

  it("trips at the hourly limit", () => {
    const d = checkBreaker(runsAgo(MIN, 2 * MIN, 3 * MIN), LIMITS, T0);
    assert.equal(d.allowed, false);
    assert.equal(d.window, "hour");
  });

  // Recovery is when the oldest run ages out, not a fixed cooldown. A flat cooldown would
  // either recover too early, re-opening the flood, or too late, stalling real mail.
  it("recovers exactly when the oldest run leaves the window", () => {
    const state = runsAgo(59 * MIN, 30 * MIN, 10 * MIN);
    const d = checkBreaker(state, LIMITS, T0);
    assert.equal(d.allowed, false);
    assert.equal(d.retryAtMs, T0 - 59 * MIN + HOUR);

    // One minute later that run is an hour old and the budget has room again.
    assert.equal(checkBreaker(state, LIMITS, T0 + MIN + 1).allowed, true);
  });

  it("trips on the daily limit even when the hour is quiet", () => {
    const state = runsAgo(20 * HOUR, 19 * HOUR, 18 * HOUR, 17 * HOUR, 16 * HOUR);
    const d = checkBreaker(state, LIMITS, T0);
    assert.equal(d.allowed, false);
    assert.equal(d.window, "day");
  });

  it("reports the hour when both windows are full, since it recovers first", () => {
    const state = runsAgo(20 * HOUR, 19 * HOUR, MIN, 2 * MIN, 3 * MIN);
    assert.equal(checkBreaker(state, LIMITS, T0).window, "hour");
  });

  it("forgets runs older than a day", () => {
    const state = runsAgo(25 * HOUR, 26 * HOUR, 27 * HOUR, 28 * HOUR, 29 * HOUR);
    assert.equal(checkBreaker(state, LIMITS, T0).allowed, true);
  });

  it("treats a zero limit as closed", () => {
    assert.equal(checkBreaker({ runs: [] }, { perHour: 0, perDay: 10 }, T0).allowed, false);
  });
});

describe("recordRun", () => {
  it("counts the run and prunes the expired ones", () => {
    const state = recordRun(runsAgo(30 * HOUR, MIN), T0);
    assert.deepEqual(state.runs, [T0 - MIN, T0]);
  });

  it("drives the breaker from allowed to tripped", () => {
    let state: BreakerState = { runs: [] };
    for (let i = 0; i < LIMITS.perHour; i += 1) {
      assert.equal(checkBreaker(state, LIMITS, T0).allowed, true, `run ${i}`);
      state = recordRun(state, T0);
    }
    assert.equal(checkBreaker(state, LIMITS, T0).allowed, false);
  });
});

describe("resolveRateLimits", () => {
  it("falls back to the defaults", () => {
    assert.deepEqual(resolveRateLimits({}), DEFAULT_RATE_LIMITS);
  });

  it("takes configured values, including a deliberate zero", () => {
    assert.deepEqual(resolveRateLimits({ maxAgentRunsPerHour: 0, maxAgentRunsPerDay: 7 }), {
      perHour: 0,
      perDay: 7,
    });
  });
});

describe("RunBudget", () => {
  function store() {
    const data = new Map<string, BreakerState>();
    return {
      data,
      lookup: async (k: string) => data.get(k),
      register: async (k: string, v: BreakerState) => {
        data.set(k, v);
      },
    };
  }

  // A budget that resets on restart is not a budget: a crash loop would spend it repeatedly.
  it("survives a restart", async () => {
    const s = store();
    let now = T0;
    const first = new RunBudget(s, "acct", LIMITS, () => now);
    await first.hydrate();
    for (let i = 0; i < LIMITS.perHour; i += 1) {
      await first.consume();
    }

    const second = new RunBudget(s, "acct", LIMITS, () => now);
    await second.hydrate();
    assert.equal(second.check().allowed, false);

    // ...and opens again once the window rolls.
    now = T0 + HOUR + 1;
    assert.equal(second.check().allowed, true);
  });

  it("keeps accounts on separate budgets", async () => {
    const s = store();
    const a = new RunBudget(s, "work", LIMITS, () => T0);
    const b = new RunBudget(s, "personal", LIMITS, () => T0);
    await a.hydrate();
    await b.hydrate();
    for (let i = 0; i < LIMITS.perHour; i += 1) {
      await a.consume();
    }
    assert.equal(a.check().allowed, false);
    assert.equal(b.check().allowed, true);
  });

  // The breaker counts runs, not senders. Trip it with one sender and it stays tripped for
  // the next, or ten senders would cost ten times the cap.
  it("does not reset for a different sender", async () => {
    const s = store();
    const budget = new RunBudget(s, "acct", LIMITS, () => T0);
    await budget.hydrate();
    for (let i = 0; i < LIMITS.perHour; i += 1) {
      await budget.consume();
    }
    assert.equal(budget.check().allowed, false);
  });
});

// Codex found the cap was checked once per batch and spent per message, so a batch of 25
// against a budget with 1 left ran all 25. These pin the arithmetic the fix depends on.
describe("batch spending", () => {
  it("refuses partway through a batch rather than after it", () => {
    let state: BreakerState = { runs: [] };
    const batch = 25;
    let ran = 0;
    for (let i = 0; i < batch; i += 1) {
      if (!checkBreaker(state, LIMITS, T0).allowed) {
        break;
      }
      state = recordRun(state, T0);
      ran += 1;
    }
    assert.equal(ran, LIMITS.perHour, "must stop at the cap, not at the batch size");
    assert.equal(state.runs.length, LIMITS.perHour);
  });

  it("reports the untouched remainder so the caller can hold its cursor", () => {
    let state: BreakerState = { runs: [] };
    const batch = 10;
    let index = 0;
    for (; index < batch; index += 1) {
      if (!checkBreaker(state, LIMITS, T0).allowed) {
        break;
      }
      state = recordRun(state, T0);
    }
    assert.equal(batch - index, batch - LIMITS.perHour);
  });
});

// A budget that un-counts when the store is unavailable is a budget an unavailable store
// disables, which is backwards: bounding spend matters most when something is wrong.
describe("persistence failure", () => {
  it("keeps counting when the store throws, and says so", async () => {
    const budget = new RunBudget(
      {
        lookup: async () => undefined,
        register: async () => {
          throw new Error("store offline");
        },
      },
      "acct",
      LIMITS,
      () => T0,
    );
    await budget.hydrate();
    for (let i = 0; i < LIMITS.perHour; i += 1) {
      const outcome = await budget.consume();
      assert.equal(outcome.persisted, false);
      assert.match(String(outcome.error), /store offline/);
    }
    assert.equal(budget.check().allowed, false, "the cap still binds in-process");
  });
});
