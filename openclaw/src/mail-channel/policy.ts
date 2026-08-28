/**
 * Admission and egress policy for the Apple Mail channel.
 *
 * Implements the scenarios enumerated in docs/mail-channel-scenarios.md. Kept as pure
 * functions with no I/O so the policy can be tested exhaustively without a gateway, a
 * mailbox, or a running agent.
 *
 * Two rules run through everything here:
 *   - inbound authentication strength grants nothing outbound
 *   - every default is closed
 */

/** What the channel does with an inbound message. */
export type Admission = "dispatch" | "observe" | "drop";

export type IngressReason =
  | "self_addressed"
  | "thread_originated_by_agent"
  | "allowlisted_and_authenticated"
  | "identifier_authentication_too_weak"
  | "authenticated_but_not_allowlisted"
  | "unauthenticated_sender";

export type IngressDecision = {
  admission: Admission;
  reason: IngressReason;
};

export type IngressInput = {
  /**
   * The ingress kernel's admission for this message: allowlist matching and the
   * min(entry, subject) authentication gate, decided together in core
   * (`resolveChannelMessageIngress`). Thread permission is expressed to the kernel as an
   * injected allowlist entry, so a kernel admit already implies sufficient authentication.
   */
  kernelAdmitted: boolean;
  /** True when the transport proved the sender's *domain*; feeds the observe escalation. */
  domainVerified: boolean;
  /** True when the sender matches a configured inbound allowlist entry or the operator. */
  allowlisted: boolean;
  /** True when this message came from an address the agent itself sends as. */
  selfAddressed: boolean;
  /** Result of the thread rule, when the message claims thread membership. */
  threadPermitted: boolean;
};

/**
 * Layers channel product policy over the kernel's admission.
 *
 * The kernel owns "may this sender authorize a run": allowlist ∧ authentication strength.
 * This function owns what the *channel* does around that answer, and order matters:
 *   1. loop guard, before any policy can grant anything
 *   2. the kernel's admit, attributed to the grant that carried it
 *   3. authenticated-but-unknown, which is readable and nothing more
 *   4. everything else
 */
export function decideIngress(input: IngressInput): IngressDecision {
  // I13. An agent that can send and read mail can answer itself.
  if (input.selfAddressed) {
    return { admission: "drop", reason: "self_addressed" };
  }

  // I1, I4, I9. The kernel admitted the sender through an allowlist entry with sufficient
  // per-message strength. Thread permission waives the *allowlist*, never *authentication*:
  // it enters the kernel as an injected entry whose subject-side strength is still gated,
  // so an admit through only that entry is the thread grant in kernel clothing.
  if (input.kernelAdmitted) {
    return input.allowlisted
      ? { admission: "dispatch", reason: "allowlisted_and_authenticated" }
      : { admission: "dispatch", reason: "thread_originated_by_agent" };
  }

  // I5, I11, I4a. The transport proved a domain; nothing proved this human may direct an
  // agent.
  //
  // Deliberately ahead of the allowlist rejection below. A grant that fails to apply has to
  // leave the sender where they were, never below it: an allowlisted sender whose mailbox
  // is not enrolled is the same authenticated-stranger case as I5, not a spoof, and
  // dropping them here would mean adding someone to `allowFrom` *reduced* what the channel
  // does with their mail. That inversion is silent, and it lands on exactly the addresses
  // the operator cared enough to configure.
  if (input.domainVerified) {
    return {
      admission: "observe",
      reason:
        input.allowlisted || input.threadPermitted
          ? "identifier_authentication_too_weak"
          : "authenticated_but_not_allowlisted",
    };
  }

  // I2. An allowlisted sender whose message authenticated nothing is dropped, not escalated.
  // The operator is not exempt: making an exception for the most valuable identity in the
  // system would invert the model the rest of this file rests on.
  if (input.allowlisted || input.threadPermitted) {
    return { admission: "drop", reason: "identifier_authentication_too_weak" };
  }

  // I6, I7, I8.
  return { admission: "drop", reason: "unauthenticated_sender" };
}

export type EgressReason =
  | "self_addressed"
  | "thread_originated_by_agent"
  | "operator_recipient"
  | "operator_instructed"
  | "recipient_allowlisted"
  | "recipient_not_permitted";

export type EgressDecision = {
  /**
   * Recipients the message may be sent to, each with the grant that actually admitted it.
   * Empty means the send is denied entirely.
   */
  permitted: { address: string; reason: EgressReason }[];
  /** Recipients removed from the send, each with why. */
  denied: { address: string; reason: EgressReason }[];
  /**
   * Distinct grants actually used, for audit. Derived from the per-recipient outcomes
   * rather than from the input flags: a send where `threadPermitted` was set but only the
   * operator was admitted must not be recorded as having used the thread grant. Audit is
   * part of the control surface here, so overstating authority is itself a defect.
   */
  reasons: EgressReason[];
};

export type EgressInput = {
  recipients: readonly string[];
  /** Addresses belonging to the operator. Always permitted. */
  operatorAddresses: readonly string[];
  /** Explicit egress allowlist. Separate from the inbound allowlist by design. */
  egressAllowlist: readonly string[];
  /** Addresses the agent sends as. Sending to itself is a loop. */
  selfAddresses: readonly string[];
  /** True when replying inside a thread the agent originated. */
  threadPermitted: boolean;
  /**
   * Addresses the agent actually addressed in that thread. Thread permission extends only
   * to these; it is not a licence to add recipients. Ignored when `threadPermitted` is
   * false. Empty means thread permission grants nothing, which is the safe default.
   */
  threadParticipants?: readonly string[];
  /** True when the operator explicitly asked for this specific send. */
  operatorInstructed: boolean;
};

function lower(values: readonly string[]): Set<string> {
  return new Set(values.map((value) => value.trim().toLowerCase()));
}

/**
 * Decides which recipients an outbound message may go to.
 *
 * Egress is default-deny. Unknown recipients are dropped from the send rather than
 * silently included, so a reply-all narrows instead of leaking (E8).
 */
export function decideEgress(input: EgressInput): EgressDecision {
  const operators = lower(input.operatorAddresses);
  const allowed = lower(input.egressAllowlist);
  const selves = lower(input.selfAddresses);
  // Thread permission is scoped to the people already in the thread. Without this, a
  // reply-all inside a permitted thread could introduce arbitrary new recipients, which
  // would turn a narrow exception into a general send capability.
  const participants = lower(input.threadParticipants ?? []);

  const permitted: { address: string; reason: EgressReason }[] = [];
  const denied: { address: string; reason: EgressReason }[] = [];

  for (const recipient of input.recipients) {
    const address = recipient.trim().toLowerCase();

    // E10. Loop guard outranks every grant below it.
    if (selves.has(address)) {
      denied.push({ address: recipient, reason: "self_addressed" });
      continue;
    }
    // E3.
    if (operators.has(address)) {
      permitted.push({ address: recipient, reason: "operator_recipient" });
      continue;
    }
    // E1. Thread permission covers existing participants only.
    if (input.threadPermitted && participants.has(address)) {
      permitted.push({ address: recipient, reason: "thread_originated_by_agent" });
      continue;
    }
    // E6.
    if (input.operatorInstructed) {
      permitted.push({ address: recipient, reason: "operator_instructed" });
      continue;
    }
    // E4.
    if (allowed.has(address)) {
      permitted.push({ address: recipient, reason: "recipient_allowlisted" });
      continue;
    }
    // E5, E7.
    denied.push({ address: recipient, reason: "recipient_not_permitted" });
  }

  // Report only the grants that actually admitted someone. Reading these off the input
  // flags would credit the thread rule for a send it never authorized.
  const reasons = [...new Set(permitted.map((entry) => entry.reason))];

  return { permitted, denied, reasons };
}
