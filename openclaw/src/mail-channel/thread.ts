/**
 * Thread-scoped reply permission.
 *
 * The rule is `isThread && threadOriginatedFromAgent`, but membership cannot be taken from
 * the message: `References` and `In-Reply-To` are sender-controlled headers, exactly like
 * `From`. A sender who learns a Message-ID from an agent-originated thread could otherwise
 * claim membership and earn reply permission, turning the thread rule into a hole in
 * default-deny rather than a narrow exception to it.
 *
 * Both halves of the check therefore read state the agent wrote when it sent, never the
 * inbound message:
 *
 *   1. the claimed parent must be a Message-ID the agent generated
 *   2. the sender must be an address the agent actually addressed in that thread
 *
 * See docs/mail-channel-scenarios.md scenarios I9, I10, I10a and E1, E2.
 */

/** One thread the agent participated in, as recorded at send time. */
export type AgentThreadRecord = {
  /**
   * Message-IDs the agent itself generated. The strong anchor: unguessable, and absent from
   * inbound mail until the agent sends it.
   *
   * Only send paths that report the id they used can populate this. `mail-cli smtp-send`
   * mints its own and returns it; Mail.app assigns one internally and reports nothing, so a
   * reply sent through `mail-cli reply` contributes an inbound anchor and no sent id.
   */
  sentMessageIds?: readonly string[];
  /**
   * Message-IDs of inbound messages the agent replied to.
   *
   * Weaker, and deliberately kept separate rather than blurred into the field above. These
   * are not secret: the original sender knows them, and so does anyone Cc'd or forwarded a
   * copy. They select a thread; they do not grant entry to one. What actually carries the
   * security is `addressedRecipients` below plus sender authentication, which `decideIngress`
   * applies to thread-permitted mail exactly as it does to everything else. An attacker who
   * learns an anchor still has to authenticate as somebody the agent addressed, and at that
   * point they are that participant.
   */
  inboundAnchorIds?: readonly string[];
  /** Addresses the agent actually sent to. Membership is checked against this. */
  addressedRecipients: readonly string[];
};

/** Everything the decision needs from an inbound message. */
export type InboundThreadClaim = {
  /** `In-Reply-To`, sender-controlled. */
  inReplyTo?: string | null;
  /** `References` chain, sender-controlled. */
  references?: readonly string[];
  /** Envelope/From address of whoever sent this reply. */
  senderAddress: string;
};

export type ThreadDecision = {
  permitted: boolean;
  /** Stable reason code, suitable for audit output. */
  reason:
    | "thread_originated_by_agent"
    | "no_thread_claim"
    | "claimed_parent_not_sent_by_agent"
    | "sender_not_addressed_in_thread";
  /** The recorded Message-ID the claim resolved to, when it resolved. */
  matchedMessageId?: string;
  /**
   * Which kind of anchor matched. Surfaced so audit can tell a thread proven by the agent's
   * own Message-ID from one resolved through an anchor the sender could also have known.
   */
  matchedAnchor?: "agent_generated" | "inbound_anchor";
};

function normalizeId(raw: string | null | undefined): string {
  return raw?.trim().replace(/^<|>$/g, "").toLowerCase() ?? "";
}

function normalizeAddress(raw: string | null | undefined): string {
  return raw?.trim().toLowerCase() ?? "";
}

/** First recorded id the claim names, tagged with which anchor kind it came from. */
function findClaimed(
  ids: readonly string[] | undefined,
  claimed: ReadonlySet<string>,
  anchor: NonNullable<ThreadDecision["matchedAnchor"]>,
): { id: string; anchor: NonNullable<ThreadDecision["matchedAnchor"]> } | undefined {
  const id = (ids ?? []).map(normalizeId).find((value) => value && claimed.has(value));
  return id ? { id, anchor } : undefined;
}

/**
 * Decides whether the agent may reply to this message under the thread rule.
 *
 * `records` is the agent's own send log, keyed however the caller likes; only its values
 * are read. Passing an empty collection denies everything, which is the correct resting
 * state for an agent that has never sent anything.
 */
export function decideThreadReply(
  claim: InboundThreadClaim,
  records: Iterable<AgentThreadRecord>,
): ThreadDecision {
  const claimed = new Set<string>();
  const inReplyTo = normalizeId(claim.inReplyTo);
  if (inReplyTo) {
    claimed.add(inReplyTo);
  }
  for (const reference of claim.references ?? []) {
    const id = normalizeId(reference);
    if (id) {
      claimed.add(id);
    }
  }

  if (claimed.size === 0) {
    return { permitted: false, reason: "no_thread_claim" };
  }

  const sender = normalizeAddress(claim.senderAddress);

  // A claim only resolves against Message-IDs the agent generated. Anything else is a
  // sender asserting thread membership, which is a claim rather than a credential.
  //
  // A References chain can name IDs from several agent threads, so this searches all
  // records for one that both matches a claimed ID and has this sender addressed. Stopping
  // at the first ID match would deny a legitimate participant whose record happened to sort
  // later, turning a correctness bug into a mysterious permission failure.
  let sawIdMatch: { id: string; anchor: ThreadDecision["matchedAnchor"] } | undefined;
  for (const record of records) {
    // Agent-generated ids are tried first, so a thread that can be proven the strong way is
    // reported that way even when both anchors are on the same record.
    const matched =
      findClaimed(record.sentMessageIds, claimed, "agent_generated") ??
      findClaimed(record.inboundAnchorIds, claimed, "inbound_anchor");
    if (!matched) {
      continue;
    }
    sawIdMatch ??= matched;
    const addressed = record.addressedRecipients.some(
      (recipient) => normalizeAddress(recipient) === sender,
    );
    if (addressed) {
      return {
        permitted: true,
        reason: "thread_originated_by_agent",
        matchedMessageId: matched.id,
        matchedAnchor: matched.anchor,
      };
    }
  }

  if (!sawIdMatch) {
    return { permitted: false, reason: "claimed_parent_not_sent_by_agent" };
  }

  // The claim named a thread the agent knows, but this sender was never addressed in it.
  // Forging In-Reply-To gains nothing unless you were already a participant.
  return {
    permitted: false,
    reason: "sender_not_addressed_in_thread",
    matchedMessageId: sawIdMatch.id,
    matchedAnchor: sawIdMatch.anchor,
  };
}
