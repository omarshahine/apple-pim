/**
 * Durable record of threads the agent has replied in.
 *
 * `decideThreadReply` can only permit what the agent wrote down, so without this the thread
 * rule is inert: every claim resolves against an empty record set and is denied. This is the
 * half that was missing.
 *
 * Held as one bounded array under a single key rather than a key per thread, because the
 * plugin keyed store is a lookup/register KV with no enumeration, and admission needs *all*
 * records to evaluate a References chain that may span several threads.
 */

import type { AgentThreadRecord } from "./thread.ts";

/** The subset of the plugin keyed store this needs. Narrow so tests can fake it. */
export type ThreadRecordStore = {
  lookup(key: string): Promise<AgentThreadRecord[] | undefined>;
  register(key: string, value: AgentThreadRecord[]): Promise<void>;
};

/**
 * Threads retained. Old threads go quiet, and an unbounded array under one key is a slow
 * leak in a value rewritten on every reply. Dropping the oldest costs a stale correspondent
 * one denied reply, which is the safe direction.
 */
export const MAX_THREADS = 200;

export type RecordedReply = {
  /** Message-ID of the inbound message being replied to. */
  inboundMessageId: string;
  /** Message-ID the agent's own reply carried, when the send path reported one. */
  sentMessageId?: string;
  /** Everyone the reply was addressed to. */
  recipients: readonly string[];
};

function normalizeId(raw: string): string {
  return raw.trim().replace(/^<|>$/g, "").toLowerCase();
}

/**
 * Folds one reply into the record set.
 *
 * Pure, so the merge semantics are testable without a store. Replying twice in the same
 * thread merges into the existing record instead of appending a second one; otherwise a long
 * exchange would evict every other thread from the bound above.
 */
export function foldReply(
  records: readonly AgentThreadRecord[],
  reply: RecordedReply,
): AgentThreadRecord[] {
  const anchor = normalizeId(reply.inboundMessageId);
  const sent = reply.sentMessageId ? normalizeId(reply.sentMessageId) : undefined;
  const recipients = reply.recipients.map((r) => r.trim().toLowerCase()).filter(Boolean);

  // A thread is the same thread when it already carries this anchor or this sent id, which
  // is how a multi-turn exchange collapses onto one record.
  const index = records.findIndex(
    (record) =>
      (record.inboundAnchorIds ?? []).some((id) => normalizeId(id) === anchor) ||
      (sent !== undefined && (record.sentMessageIds ?? []).some((id) => normalizeId(id) === sent)),
  );

  const existing = index >= 0 ? records[index]! : undefined;
  const merged: AgentThreadRecord = {
    sentMessageIds: [
      ...new Set([...(existing?.sentMessageIds ?? []), ...(sent ? [sent] : [])]),
    ],
    inboundAnchorIds: [...new Set([...(existing?.inboundAnchorIds ?? []), anchor])],
    addressedRecipients: [...new Set([...(existing?.addressedRecipients ?? []), ...recipients])],
  };

  const rest = index >= 0 ? records.filter((_, i) => i !== index) : [...records];
  // Newest last, so the trim below drops the least recently active thread.
  return [...rest, merged].slice(-MAX_THREADS);
}

/**
 * Process-local view over the durable store.
 *
 * Admission consults the records on every classified message, so they are held in memory and
 * the store is written only when a reply adds something. Reading them back per message would
 * be a database round trip inside the poll loop for a value only this process changes.
 */
export class ThreadRecords {
  // Explicit fields, not constructor parameter properties: Node runs this repo's TypeScript
  // in strip-only mode, which cannot erase them.
  readonly #store: ThreadRecordStore;
  readonly #key: string;
  #records: AgentThreadRecord[] = [];

  constructor(store: ThreadRecordStore, key: string) {
    this.#store = store;
    this.#key = key;
  }

  /** Loads the durable set. Call once, at account start. */
  async hydrate(): Promise<void> {
    this.#records = [...((await this.#store.lookup(this.#key)) ?? [])];
  }

  /** Everything admission should match claims against. */
  all(): readonly AgentThreadRecord[] {
    return this.#records;
  }

  /**
   * Records a reply and persists it.
   *
   * Throws if the store does. The caller decides what that means: the mail has already gone
   * out by this point, so failing the dispatch would misreport a delivered message, while
   * dropping the record silently costs the correspondent a denied reply later.
   */
  async record(reply: RecordedReply): Promise<void> {
    this.#records = foldReply(this.#records, reply);
    await this.#store.register(this.#key, this.#records);
  }
}
