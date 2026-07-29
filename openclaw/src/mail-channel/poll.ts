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
 * A cursor covering the previous one plus exactly the messages handed in, for a partially
 * delivered batch.
 *
 * Merged with `previous` rather than built fresh. A prefix consisting only of undated
 * messages has no watermark of its own, and returning one without `lastDateReceived` would
 * reset the cursor to cold and redeliver every dated message in the mailbox. The same
 * applies to `seenUndated`: dropping the inherited ids lets older undated mail replay.
 *
 * Undated messages are recorded by id, because they cannot be placed against a watermark.
 */
function cursorThrough(
  previous: PollCursor,
  delivered: readonly ClassifiedMessage[],
): PollCursor {
  const dates = delivered.map((e) => e.message.dateReceived).filter(Boolean) as string[];
  const deliveredHighest = dates.sort().at(-1);
  // Never move the watermark backwards: a partial batch can only ever add to what the
  // previous cursor already covered.
  const highest =
    deliveredHighest && (!previous.lastDateReceived || deliveredHighest > previous.lastDateReceived)
      ? deliveredHighest
      : previous.lastDateReceived;

  const atWatermark = delivered
    .filter((e) => e.message.dateReceived && e.message.dateReceived === highest)
    .map((e) => e.message.messageId);

  return {
    lastDateReceived: highest,
    // Carry the prior ids forward when the watermark did not move, so a partial batch that
    // adds nothing newer cannot erase the dedupe set for that instant.
    seenAtWatermark:
      highest && highest === previous.lastDateReceived
        ? [...new Set([...(previous.seenAtWatermark ?? []), ...atWatermark])]
        : atWatermark,
    seenUndated: [
      ...new Set([
        ...(previous.seenUndated ?? []),
        ...delivered.filter((e) => !e.message.dateReceived).map((e) => e.message.messageId),
      ]),
    ].slice(-MAX_SEEN_UNDATED_CURSOR),
  };
}

/** Mirrors the bound in `selectNewMessages`, which owns the same field. */
const MAX_SEEN_UNDATED_CURSOR = 200;

/**
 * Lists the oldest unprocessed messages, paging forward from the cursor.
 *
 * This used to list newest-first and widen the page until it reached back past the cursor.
 * That could not work: the page grows backwards from *now*, so once more than `maxLimit`
 * messages sat between the cursor and the present, older mail was unreachable no matter what
 * the loop did. Advancing skipped it, holding redelivered the newest page forever, and
 * either way anyone who could flood the mailbox could push a real message out of reach.
 *
 * Passing the cursor as `--since` inverts it: the page starts at the backlog's oldest end
 * and walks forward, so a flood delays delivery by a cycle or two and never prevents it.
 * Truncation stops being a correctness problem and becomes ordinary paging.
 *
 * With no cursor yet the page is taken as-is, newest-first: a first run starts from now
 * rather than ingesting the entire mailbox history.
 */
async function listBackToCursor(
  deps: InboundDeps,
  options: PollOptions,
  previousWatermark: string | undefined,
): Promise<{ messages: MailboxMessage[]; truncated: boolean }> {
  const limit = options.limit;
  const messages = await deps.listMessages({
    mailbox: options.mailbox,
    limit,
    since: previousWatermark,
  });

  // A full page means there is more behind it. That is now just "more to do next cycle",
  // not mail at risk: the next page starts where this one ended.
  return { messages, truncated: !!previousWatermark && messages.length >= limit };
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
  /**
   * Called with the messages a cycle admitted. Dropped messages never reach it.
   *
   * Receives messages **oldest first**, and may return `{ completed }` to say it stopped
   * early. The cursor then advances through exactly the completed prefix, so the untouched
   * suffix is retried next cycle and the delivered prefix is not.
   *
   * Oldest-first is what makes a partial cursor expressible. Dispatching newest-first would
   * leave the undelivered messages *behind* the watermark, where advancing loses them and
   * holding replays everything already delivered.
   */
  onAdmitted: (
    messages: ClassifiedMessage[],
  ) => Promise<void | { completed: number }> | void | { completed: number };
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
      // Read once per cycle: the partial cursor has to be merged onto what was already
      // persisted, not built from the delivered slice alone.
      const previous = (await store.lookup(options.cursorKey)) ?? {};
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
      let partialCursor: PollCursor | undefined;
      if (admitted.length > 0) {
        // Oldest first, so a partial delivery has a cursor that can describe it.
        const ordered = [...admitted].sort((a, b) =>
          (a.message.dateReceived ?? "").localeCompare(b.message.dateReceived ?? ""),
        );
        // Deliver first. If this throws, the cursor is left untouched and the batch is
        // retried next cycle rather than silently skipped.
        const outcome = await deps.onAdmitted(ordered);
        const completed = outcome?.completed ?? ordered.length;
        if (completed < ordered.length) {
          deps.onThrottled?.({ pending: ordered.length - completed });
          // Advance only through what was delivered. Holding everything would replay the
          // delivered prefix on every retry and, if the batch keeps exceeding the budget,
          // starve the suffix forever.
          partialCursor = cursorThrough(previous, ordered.slice(0, completed));
        }
      }
      // Truncation advances the cursor even though mail behind the ceiling was never
      // examined. Holding it instead looks safer and is worse: listing is newest-first, so
      // a held cursor re-lists the same newest page every cycle, redelivers it every cycle,
      // and still never reaches the older mail, because the page can only ever grow up to
      // `maxLimit` back from *now*. That is unbounded duplicate delivery plus the same loss.
      // Advancing bounds it to loss, once, reported loudly enough for the operator to raise
      // `maxLimit` or narrow the mailbox.
      //
      // A deferred batch is different and is genuinely retryable, so its cursor is held.
      //
      // Deliberately not `continue`: that would skip the sleep below and spin the loop.
      // A partial cursor wins over the full one, and over truncation: it describes exactly
      // what was delivered, which is the only claim safe to persist. When it is absent the
      // full cursor applies, truncated or not, because a fully delivered page has nothing
      // left to retry and holding it would re-list the same newest page forever.
      await store.register(options.cursorKey, partialCursor ?? cursor);
    } catch (error) {
      deps.onError?.(error);
    }
    if (signal.aborted) {
      return;
    }
    await sleep(options.intervalMs, signal);
  }
}
