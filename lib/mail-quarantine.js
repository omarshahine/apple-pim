/**
 * Messages the Apple Mail channel refused to admit, and which the mail tool must therefore
 * also refuse to surface.
 *
 * The channel stopped sending message bodies to the agent and started sending envelopes
 * with a message id, so the agent fetches a body only when it decides one is worth reading.
 * That moved the decision to the right place, and it moved the gate to the wrong one:
 * `apple_pim_mail` will read any id handed to it. A message the channel dropped as spoofed
 * or unauthenticated still has an id, and an agent that learns it (from a References chain,
 * a quoted reply, a listing of the mailbox) could read the body the channel just refused to
 * deliver. Lazy fetch without this is a bypass, not an optimization.
 *
 * "Refuse to surface" is stronger than "refuse to open", and it has to be. Blocking only
 * `get` leaves `search --field content` as a content oracle: the agent probes for a phrase
 * and learns from the hit whether a quarantined message contains it, without ever reading a
 * body. Listings leak the envelope the same way. So quarantined ids are filtered out of
 * results as well as blocked on direct access.
 *
 * Entries are keyed per account. One shared map meant a second account starting up replaced
 * the first account's set, silently un-quarantining everything it had refused.
 *
 * Plain JS rather than TypeScript so the tool handlers in this directory can import it
 * directly, the same way they import every other helper here.
 */

/**
 * Bounded per account, because this is a rejection cache and an unbounded one is a leak.
 * Dropping the oldest entry re-exposes a message the channel already refused, so the bound
 * is generous relative to how much mail a poll cycle can drop.
 */
const MAX_QUARANTINED = 2000;

/** account key -> (normalized id -> reason). Insertion-ordered, so the oldest is evictable. */
const byAccount = new Map();

/** Normalizes so `<id>`, ` id `, and `ID` are the same message. */
function normalize(id) {
  return String(id ?? "")
    .trim()
    .replace(/^<|>$/g, "")
    .toLowerCase();
}

function accountMap(account) {
  const key = String(account ?? "default");
  let map = byAccount.get(key);
  if (!map) {
    map = new Map();
    byAccount.set(key, map);
  }
  return map;
}

/** Records that the channel refused this message. */
export function quarantineMessage(account, id, reason) {
  const key = normalize(id);
  if (!key) {
    return;
  }
  const map = accountMap(account);
  // Re-inserting moves it to the end, so an id the channel keeps rejecting stays fresh.
  map.delete(key);
  map.set(key, reason ?? "not_admitted");
  while (map.size > MAX_QUARANTINED) {
    map.delete(map.keys().next().value);
  }
}

/** Replaces one account's set, for hydrating from durable storage at channel start. */
export function loadQuarantine(account, entries) {
  byAccount.set(String(account ?? "default"), new Map());
  for (const [id, reason] of entries ?? []) {
    quarantineMessage(account, id, reason);
  }
}

/** One account's contents, for persisting. */
export function quarantineSnapshot(account) {
  return [...accountMap(account).entries()];
}

/**
 * The reason this message was refused, or undefined when it was not.
 *
 * Searches every account, because the mail tool is not account-scoped: it is handed an id
 * and nothing else. A message refused by any account must not be readable through any
 * other, since they share one mailbox and one agent.
 */
export function quarantineReason(id) {
  const key = normalize(id);
  if (!key) {
    return undefined;
  }
  for (const map of byAccount.values()) {
    const reason = map.get(key);
    if (reason) {
      return reason;
    }
  }
  return undefined;
}

/**
 * Throws when the tool is being asked to open a message the channel refused.
 *
 * The error names the reason rather than saying "denied", because the agent can act on the
 * distinction: an unauthenticated sender is a different situation from one whose mailbox
 * simply is not enrolled, and a message that reads as blocked-for-no-reason invites a retry.
 */
export function assertMailReadable(id, action) {
  const reason = quarantineReason(id);
  if (!reason) {
    return;
  }
  throw new Error(
    `Refusing to ${action} message ${id}: the Apple Mail channel did not admit it (${reason}). ` +
      `Its sender failed the channel's authentication policy, so its contents are not trusted ` +
      `input. Reading it here would bypass that decision.`,
  );
}

/**
 * Removes quarantined messages from a listing or search result.
 *
 * `reportWithheld` controls whether the response admits that rows were removed. For a
 * listing the answer does not depend on anything the agent chose, so saying "2 withheld" is
 * a useful diagnostic: a quietly short listing is otherwise indistinguishable from an empty
 * mailbox.
 *
 * For a search it must stay silent, because the count is query-dependent and therefore an
 * oracle in its own right. `search --field content "secret phrase"` reporting one withheld
 * row confirms the phrase appears in quarantined mail without ever returning it, which is
 * the exact leak filtering the rows was meant to close.
 */
export function filterQuarantinedResults(result, { reportWithheld = false } = {}) {
  if (!result || typeof result !== "object" || !Array.isArray(result.messages)) {
    return result;
  }
  const kept = result.messages.filter((m) => !quarantineReason(m?.messageId));
  const withheld = result.messages.length - kept.length;
  if (withheld === 0) {
    return result;
  }
  const filtered = { ...result, messages: kept };
  if (typeof result.count === "number") {
    filtered.count = kept.length;
  }
  if (reportWithheld) {
    filtered.withheldByChannelPolicy = withheld;
  }
  return filtered;
}

/** Test seam. Not part of the tool surface. */
export function resetQuarantine() {
  byAccount.clear();
}
