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

/** One thread the agent originated, as recorded at send time. */
export type AgentThreadRecord = {
  /** Message-IDs the agent generated in this thread. Never populated from inbound mail. */
  sentMessageIds: readonly string[];
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
  /** The agent-generated Message-ID the claim resolved to, when it resolved. */
  matchedMessageId?: string;
};

function normalizeId(raw: string | null | undefined): string {
  return raw?.trim().replace(/^<|>$/g, "").toLowerCase() ?? "";
}

function normalizeAddress(raw: string | null | undefined): string {
  return raw?.trim().toLowerCase() ?? "";
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
  let sawIdMatch: string | undefined;
  for (const record of records) {
    const matchedId = record.sentMessageIds
      .map(normalizeId)
      .find((sentId) => sentId && claimed.has(sentId));
    if (!matchedId) {
      continue;
    }
    sawIdMatch ??= matchedId;
    const addressed = record.addressedRecipients.some(
      (recipient) => normalizeAddress(recipient) === sender,
    );
    if (addressed) {
      return {
        permitted: true,
        reason: "thread_originated_by_agent",
        matchedMessageId: matchedId,
      };
    }
  }

  if (!sawIdMatch) {
    return { permitted: false, reason: "claimed_parent_not_sent_by_agent" };
  }

  // The claim named a real agent message, but this sender was never addressed in any thread
  // it belongs to. Forging In-Reply-To gains nothing unless you were already a participant.
  return { permitted: false, reason: "sender_not_addressed_in_thread", matchedMessageId: sawIdMatch };
}
