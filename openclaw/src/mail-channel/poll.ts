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
  /** Store key, so several accounts can poll independently. */
  cursorKey: string;
  classify: ClassifyOptions;
};

export type PollCycleResult = {
  classified: ClassifiedMessage[];
  cursor: PollCursor;
};

/**
 * Runs one poll cycle: list, filter to unseen, classify each, persist the cursor.
 *
 * The cursor is written **after** classification, not before. A crash mid-cycle therefore
 * reprocesses messages rather than losing them. For mail that is the right trade: a
 * duplicate is visible and recoverable, a silently dropped message is neither.
 */
export async function runPollCycle(
  deps: InboundDeps,
  options: PollOptions,
  store: CursorStore,
): Promise<PollCycleResult> {
  const previous = (await store.lookup(options.cursorKey)) ?? {};
  const messages = await deps.listMessages({ mailbox: options.mailbox, limit: options.limit });
  const { fresh, cursor } = selectNewMessages(messages, previous);

  const classified: ClassifiedMessage[] = [];
  for (const message of fresh) {
    classified.push(await classifyMessage(message, deps, options.classify));
  }

  await store.register(options.cursorKey, cursor);
  return { classified, cursor };
}

export type PollLoopDeps = {
  /** Called with the messages a cycle admitted. Dropped messages never reach it. */
  onAdmitted: (messages: ClassifiedMessage[]) => Promise<void> | void;
  /** Reports a cycle that threw. The loop continues regardless. */
  onError?: (error: unknown) => void;
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
      const { classified } = await runPollCycle(deps, options, store);
      const admitted = classified.filter((entry) => entry.decision.admission !== "drop");
      if (admitted.length > 0) {
        await deps.onAdmitted(admitted);
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
