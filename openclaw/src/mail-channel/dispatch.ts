/**
 * Hands admitted mail to the agent and delivers its reply.
 *
 * Two policies meet here and must not be confused. Admission already decided the message
 * may reach the agent. Replying is a *send*, so it goes through the egress policy
 * independently: being allowed to read someone does not make you allowed to write to them.
 *
 * `observe` messages are given to the agent for context but their reply is suppressed,
 * which is what makes "read an authenticated stranger, do not reply to them" real rather
 * than aspirational.
 */

import type { OpenClawConfig } from "openclaw/plugin-sdk/config-contracts";
import type { ClassifiedMessage } from "./inbound.ts";
import { decideEgress, type EgressDecision } from "./policy.ts";

/** Sends one reply. Injected so dispatch is testable without a mailbox. */
export type ReplySender = (params: {
  messageId: string;
  to: string;
  body: string;
}) => Promise<void> | void;

/**
 * The reply pipeline, narrowed to what this module uses.
 *
 * Typed against the SDK's exported `dispatchReplyWithBufferedBlockDispatcher` rather than
 * reached through `ctx.channelRuntime`, whose surface is `{ [key: string]: unknown }`.
 */
export type ReplyDispatcher = (params: {
  ctx: { Body?: string; From?: string; To?: string; SessionKey?: string };
  cfg: OpenClawConfig;
  // `deliver` must return a promise: the SDK awaits it to know when a block settled.
  dispatcherOptions: { deliver: (payload: { text?: string }) => Promise<unknown> };
}) => Promise<unknown>;

export type DispatchDeps = {
  dispatchReply: ReplyDispatcher;
  sendReply: ReplySender;
  onSuppressed?: (params: { address: string; reason: string }) => void;
};

export type DispatchOptions = {
  cfg: OpenClawConfig;
  /** Addresses belonging to the operator. Always a permitted reply recipient. */
  operatorAddresses: readonly string[];
  /** Recipients the agent may originate mail to. */
  egressAllowlist: readonly string[];
  /** Addresses the agent sends as, for the loop guard. */
  selfAddresses: readonly string[];
  /** Channel + account, so replies to different accounts do not share a session. */
  sessionPrefix: string;
};

/** Decides whether the agent's reply to this sender may actually be sent. */
export function decideReplyDelivery(
  message: ClassifiedMessage,
  options: DispatchOptions,
): EgressDecision {
  return decideEgress({
    recipients: [message.address],
    operatorAddresses: options.operatorAddresses,
    egressAllowlist: options.egressAllowlist,
    selfAddresses: options.selfAddresses,
    // A reply to inbound mail is not the agent continuing a thread it started, so the
    // thread grant does not apply. It has to stand on the operator or the allowlist.
    threadPermitted: false,
    operatorInstructed: false,
  });
}

/**
 * Runs one admitted message through the agent.
 *
 * Delivery is decided **before** the agent runs, not after. Generating a reply the policy
 * will refuse to send wastes a model call and, worse, invites someone later to "just send
 * it" because the text already exists.
 */
export async function dispatchAdmittedMessage(
  message: ClassifiedMessage,
  deps: DispatchDeps,
  options: DispatchOptions,
): Promise<{ replied: boolean; reason: string }> {
  const observeOnly = message.decision.admission === "observe";
  const egress = decideReplyDelivery(message, options);
  const mayReply = !observeOnly && egress.permitted.length > 0;

  if (!mayReply) {
    const reason = observeOnly ? "observe_only" : (egress.denied[0]?.reason ?? "not_permitted");
    deps.onSuppressed?.({ address: message.address, reason });
  }

  await deps.dispatchReply({
    ctx: {
      Body: message.message.subject
        ? `Subject: ${message.message.subject}`
        : undefined,
      From: message.address,
      To: options.operatorAddresses[0],
      // One session per sender per account: mail threads outlive any single exchange,
      // and collapsing senders into one session would let one correspondent read another.
      SessionKey: `${options.sessionPrefix}:${message.address}`,
    },
    cfg: options.cfg,
    dispatcherOptions: {
      deliver: async (payload) => {
        if (!mayReply) {
          return;
        }
        const text = payload.text?.trim();
        if (!text) {
          return;
        }
        await deps.sendReply({
          messageId: message.message.messageId,
          to: message.address,
          body: text,
        });
      },
    },
  });

  return {
    replied: mayReply,
    reason: mayReply ? (egress.reasons[0] ?? "permitted") : "suppressed",
  };
}
