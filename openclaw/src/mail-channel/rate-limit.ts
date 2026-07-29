/**
 * Circuit breaker on agent runs.
 *
 * Default-deny bounds *who* may drive the agent. It does not bound *how much*. One
 * permitted correspondent, a mailing list that starts looping, or a bug in a mail rule can
 * all produce unbounded model calls from an entirely authorized sender, and every control
 * elsewhere in this channel will correctly wave each one through.
 *
 * So this counts runs rather than judging them. It is deliberately not a policy about
 * senders: a breaker that trips per sender would let ten senders cost ten times as much,
 * which is the failure it exists to prevent.
 *
 * When the breaker is open the poll loop holds its cursor rather than discarding the
 * backlog, so a burst is deferred and not lost. That means the same mail is reclassified
 * next cycle, which costs an auth-check per message and is the right trade: authentication
 * is cheap, and losing an operator's mail because a newsletter flooded the mailbox is not a
 * recoverable error.
 */

/** Runs allowed per window. Both apply; the tighter one binds. */
export type RateLimits = {
  perHour: number;
  perDay: number;
};

/**
 * Conservative rather than generous. A mail channel that legitimately needs more than a few
 * dozen agent runs an hour is either very busy or misconfigured, and the operator should
 * find out which by seeing the breaker trip rather than by seeing a bill.
 */
export const DEFAULT_RATE_LIMITS: RateLimits = { perHour: 30, perDay: 200 };

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

/** Run timestamps, newest last. Persisted so a restart cannot reset the budget. */
export type BreakerState = {
  runs: readonly number[];
};

export type BreakerDecision = {
  allowed: boolean;
  /** Populated when refused, so the log says which limit bound and when it recovers. */
  window?: "hour" | "day";
  retryAtMs?: number;
};

/** Drops timestamps older than a day, which is the longest window anything here needs. */
function prune(runs: readonly number[], nowMs: number): number[] {
  const cutoff = nowMs - DAY_MS;
  return runs.filter((at) => at > cutoff);
}

/**
 * Decides whether one more agent run is permitted, without recording it.
 *
 * Split from `record` so a caller can check before doing expensive work and still only
 * count runs that actually happened.
 */
export function checkBreaker(
  state: BreakerState,
  limits: RateLimits,
  nowMs: number,
): BreakerDecision {
  const runs = prune(state.runs, nowMs);
  const inHour = runs.filter((at) => at > nowMs - HOUR_MS);

  if (inHour.length >= limits.perHour) {
    // Recovery is when the oldest run in the window ages out, not a fixed cooldown: that is
    // the moment the count actually drops below the limit.
    return { allowed: false, window: "hour", retryAtMs: (inHour[0] ?? nowMs) + HOUR_MS };
  }
  if (runs.length >= limits.perDay) {
    return { allowed: false, window: "day", retryAtMs: (runs[0] ?? nowMs) + DAY_MS };
  }
  return { allowed: true };
}

/** Returns the state with this run counted. Pure, so the caller owns persistence. */
export function recordRun(state: BreakerState, nowMs: number): BreakerState {
  return { runs: [...prune(state.runs, nowMs), nowMs] };
}

/** Reads limits off channel config, falling back to the defaults. */
export function resolveRateLimits(config: {
  maxAgentRunsPerHour?: number;
  maxAgentRunsPerDay?: number;
}): RateLimits {
  return {
    perHour: config.maxAgentRunsPerHour ?? DEFAULT_RATE_LIMITS.perHour,
    perDay: config.maxAgentRunsPerDay ?? DEFAULT_RATE_LIMITS.perDay,
  };
}

/** The subset of the plugin keyed store this needs. */
export type BreakerStore = {
  lookup(key: string): Promise<BreakerState | undefined>;
  register(key: string, value: BreakerState): Promise<void>;
};

/**
 * Process-local view over the durable budget.
 *
 * Held in memory and written on each run, because the count changes only here and reading
 * it back per message would be a round trip inside the poll loop.
 */
export class RunBudget {
  readonly #store: BreakerStore;
  readonly #key: string;
  readonly #limits: RateLimits;
  readonly #now: () => number;
  #state: BreakerState = { runs: [] };

  constructor(
    store: BreakerStore,
    key: string,
    limits: RateLimits,
    now: () => number = () => Date.now(),
  ) {
    this.#store = store;
    this.#key = key;
    this.#limits = limits;
    this.#now = now;
  }

  async hydrate(): Promise<void> {
    this.#state = (await this.#store.lookup(this.#key)) ?? { runs: [] };
  }

  check(): BreakerDecision {
    return checkBreaker(this.#state, this.#limits, this.#now());
  }

  /**
   * Counts one run.
   *
   * The in-memory count is authoritative and is never rolled back on a persistence failure.
   * A budget that un-counts when the store is unavailable is a budget an unavailable store
   * disables, which is exactly backwards: the whole point is to bound spend when something
   * has gone wrong. Persistence failure costs durability across a restart, not the cap.
   */
  async consume(): Promise<{ persisted: boolean; error?: unknown }> {
    this.#state = recordRun(this.#state, this.#now());
    try {
      await this.#store.register(this.#key, this.#state);
      return { persisted: true };
    } catch (error) {
      return { persisted: false, error };
    }
  }
}
