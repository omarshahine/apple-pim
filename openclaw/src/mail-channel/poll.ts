/**
 * The poll loop that drives inbound mail.
 *
 * This is what replaces the retired Mail.app rule. Polling instead of being pushed keeps
 * the filter inside the channel, where policy belongs, rather than upstream in a mail rule
 * that decided what the agent was even allowed to see.
 *
 * The cursor lives in the plugin keyed store (SQLite-backed), not a sidecar file, so it
 * survives gateway restarts without adding a parallel state path.
 */

import {
  classifyMessage,
  selectNewMessages,
  type ClassifiedMessage,
  type ClassifyOptions,
  type InboundDeps,
  type MailboxMessage,
  type PollCursor,
} from "./inbound.ts";

/** The subset of the plugin keyed store this needs. Narrow so tests can fake it. */
export type CursorStore = {
  lookup(key: string): Promise<PollCursor | undefined>;
  register(key: string, value: PollCursor): Promise<void>;
};

export type PollOptions = {
  mailbox: string;
  limit: number;
  /**
   * Ceiling when widening the page to reach back to the cursor. Bounds a burst of mail
   * from turning one cycle into an unbounded scan of the mailbox.
   */
  maxLimit?: number;
  /** Store key, so several accounts can poll independently. */
  cursorKey: string;
  classify: ClassifyOptions;
};

export type PollCycleResult = {
  classified: ClassifiedMessage[];
  /** Cursor to persist once delivery succeeds. Deliberately not persisted here. */
  cursor: PollCursor;
  /** True when the page ceiling was hit with mail still unread behind it. */
  truncated: boolean;
};

const DEFAULT_MAX_LIMIT = 500;

/**
 * Lists far enough back to reach the previous cursor.
 *
 * Listing is newest-first with a limit, so if more than `limit` messages arrive between
 * cycles the page stops short of the cursor and everything behind it would be skipped
 * forever once the watermark advanced. This widens the page until it reaches back past the
 * cursor, the page is no longer full, or the ceiling is hit.
 *
 * With no cursor yet the page is taken as-is: a first run starts from now rather than
 * ingesting the entire mailbox history.
 */
async function listBackToCursor(
  deps: InboundDeps,
  options: PollOptions,
  previousWatermark: string | undefined,
): Promise<{ messages: MailboxMessage[]; truncated: boolean }> {
  const ceiling = options.maxLimit ?? DEFAULT_MAX_LIMIT;
  let limit = options.limit;
  let messages = await deps.listMessages({ mailbox: options.mailbox, limit });

  if (!previousWatermark) {
    return { messages, truncated: false };
  }

  while (messages.length >= limit && limit < ceiling) {
    const dates = messages.map((m) => m.dateReceived).filter(Boolean) as string[];
    const oldest = dates.sort()[0];
    if (oldest && oldest <= previousWatermark) {
      // The page now spans the cursor, so nothing is hiding behind it.
      return { messages, truncated: false };
    }
    limit = Math.min(limit * 4, ceiling);
    messages = await deps.listMessages({ mailbox: options.mailbox, limit });
  }

  const dates = messages.map((m) => m.dateReceived).filter(Boolean) as string[];
  const oldest = dates.sort()[0];
  const stillShort = messages.length >= limit && !!oldest && oldest > previousWatermark;
  return { messages, truncated: stillShort };
}

/**
 * Runs one poll cycle: list, filter to unseen, classify each.
 *
 * The cursor is returned, **not persisted**. Advancing it is the caller's job and must
 * happen only after the batch has actually been delivered, because a cursor that moves
 * ahead of delivery turns any delivery failure into permanently skipped mail.
 */
export async function runPollCycle(
  deps: InboundDeps,
  options: PollOptions,
  store: CursorStore,
): Promise<PollCycleResult> {
  const previous = (await store.lookup(options.cursorKey)) ?? {};
  const { messages, truncated } = await listBackToCursor(deps, options, previous.lastDateReceived);
  const { fresh, cursor } = selectNewMessages(messages, previous);

  const classified: ClassifiedMessage[] = [];
  for (const message of fresh) {
    classified.push(await classifyMessage(message, deps, options.classify));
  }

  return { classified, cursor, truncated };
}

export type PollLoopDeps = {
  /** Called with the messages a cycle admitted. Dropped messages never reach it. */
  onAdmitted: (messages: ClassifiedMessage[]) => Promise<void> | void;
  /**
   * Called with the messages a cycle refused, before the cursor moves past them.
   *
   * A dropped message is never reclassified, so this is the only moment the decision
   * exists. The channel uses it to quarantine the id against the mail tool, which is what
   * stops an envelope-only prompt from becoming a way to fetch bodies the policy rejected.
   */
  onDropped?: (messages: ClassifiedMessage[]) => Promise<void> | void;
  /** Reports a cycle that threw. The loop continues regardless. */
  onError?: (error: unknown) => void;
  /** Reports that the page ceiling was hit with unread mail still behind it. */
  onTruncated?: (params: { mailbox: string; limit: number }) => void;
  /**
   * Whether the agent may run at all this cycle. Returns a refusal when the circuit breaker
   * is open, which holds the cursor rather than discarding the batch: a burst is deferred,
   * never lost.
   */
  checkBudget?: () => { allowed: boolean; window?: string; retryAtMs?: number };
  /** Reports a cycle skipped because the breaker was open. */
  onThrottled?: (params: { window?: string; retryAtMs?: number; pending: number }) => void;
  /** Injected so tests do not wait in real time. */
  sleep?: (ms: number, signal: AbortSignal) => Promise<void>;
};

function defaultSleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    // Unblock immediately on shutdown instead of holding the gateway for a full interval.
    signal.addEventListener("abort", () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
  });
}

/**
 * Polls until aborted.
 *
 * Cycles never overlap: the next interval starts after the previous cycle settles, so a
 * slow mailbox cannot stack concurrent scans that would race on the same cursor.
 *
 * A failing cycle is reported and skipped rather than ending the loop. Mail is a
 * background source; one bad poll should not silently stop the channel until someone
 * notices no mail has arrived for a day.
 */
export async function runPollLoop(
  deps: InboundDeps & PollLoopDeps,
  options: PollOptions & { intervalMs: number },
  store: CursorStore,
  signal: AbortSignal,
): Promise<void> {
  const sleep = deps.sleep ?? defaultSleep;
  while (!signal.aborted) {
    try {
      const { classified, cursor, truncated } = await runPollCycle(deps, options, store);
      if (truncated) {
        deps.onTruncated?.({ mailbox: options.mailbox, limit: options.maxLimit ?? DEFAULT_MAX_LIMIT });
      }
      const dropped = classified.filter((entry) => entry.decision.admission === "drop");
      if (dropped.length > 0) {
        // Ahead of delivery and ahead of the cursor: a refusal that is not recorded before
        // the cursor advances is a refusal nothing can act on afterwards.
        await deps.onDropped?.(dropped);
      }
      const admitted = classified.filter((entry) => entry.decision.admission !== "drop");
      // The breaker is consulted only when there is something to spend budget on, so a quiet
      // mailbox never reports itself throttled.
      const budget = admitted.length > 0 ? (deps.checkBudget?.() ?? { allowed: true }) : { allowed: true };
      if (!budget.allowed) {
        // Hold the cursor. Reclassifying this page next cycle costs an auth-check per
        // message, which is the right price for not losing an operator's mail to a burst
        // of newsletters.
        deps.onThrottled?.({
          window: budget.window,
          retryAtMs: budget.retryAtMs,
          pending: admitted.length,
        });
        if (!signal.aborted) {
          await sleep(options.intervalMs, signal);
        }
        continue;
      }
      if (admitted.length > 0) {
        // Deliver first. If this throws, the cursor is left untouched and the batch is
        // retried next cycle rather than silently skipped.
        await deps.onAdmitted(admitted);
      }
      // Reporting truncation is not enough. The cursor derives from a newest-first
      // partial page, so persisting it would bury the older mail still behind the
      // ceiling. Holding it reprocesses this page next cycle, which is duplicates
      // instead of loss, and truncation keeps being reported until the backlog drains
      // or the operator raises maxLimit.
      //
      // Deliberately not `continue`: that would skip the sleep below and spin the loop.
      if (!truncated) {
        await store.register(options.cursorKey, cursor);
      }
    } catch (error) {
      deps.onError?.(error);
    }
    if (signal.aborted) {
      return;
    }
    await sleep(options.intervalMs, signal);
  }
}
