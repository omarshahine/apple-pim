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

import type { IdentifierAuthentication, MailIdentifierStrengths } from "../mail-auth/strength.ts";
import { meetsMinimum } from "../mail-auth/strength.ts";

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
  strengths: MailIdentifierStrengths;
  /** Sender address, already normalized. */
  senderAddress: string;
  /** True when the sender matches an inbound allowlist entry or the operator. */
  allowlisted: boolean;
  /** Minimum strength an identifier needs before it may authorize. */
  minIdentifierAuthentication: IdentifierAuthentication;
  /** True when this message came from an address the agent itself sends as. */
  selfAddressed: boolean;
  /** Result of the thread rule, when the message claims thread membership. */
  threadPermitted: boolean;
};

/**
 * Decides admission for one inbound message.
 *
 * Order matters and is deliberate:
 *   1. loop guard, before any policy can grant anything
 *   2. thread permission, which is narrower than the allowlist and independent of it
 *   3. allowlist plus sufficient address strength
 *   4. authenticated-but-unknown, which is readable and nothing more
 *   5. everything else
 */
export function decideIngress(input: IngressInput): IngressDecision {
  // I13. An agent that can send and read mail can answer itself.
  if (input.selfAddressed) {
    return { admission: "drop", reason: "self_addressed" };
  }

  const addressStrongEnough = meetsMinimum(
    input.strengths.address,
    input.minIdentifierAuthentication,
  );

  // I9. Thread permission waives the *allowlist*, because the agent already chose to
  // contact this person when it started the thread. It does not waive *authentication*.
  // decideThreadReply matches on the sender address, and an unauthenticated address is a
  // claim: anyone who learns a participant's address and an agent Message-ID could
  // otherwise spoof their way into a dispatch.
  if (input.threadPermitted) {
    return addressStrongEnough
      ? { admission: "dispatch", reason: "thread_originated_by_agent" }
      : { admission: "drop", reason: "identifier_authentication_too_weak" };
  }

  // I1, I4.
  if (input.allowlisted && addressStrongEnough) {
    return { admission: "dispatch", reason: "allowlisted_and_authenticated" };
  }

  // I2. An allowlisted sender whose message did not authenticate is dropped, not escalated.
  // The operator is not exempt: making an exception for the most valuable identity in the
  // system would invert the model the rest of this file rests on.
  if (input.allowlisted) {
    return { admission: "drop", reason: "identifier_authentication_too_weak" };
  }

  // I5, I11. The transport proved a domain; nothing proved this human may direct an agent.
  if (input.strengths.domain === "verified") {
    return { admission: "observe", reason: "authenticated_but_not_allowlisted" };
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
