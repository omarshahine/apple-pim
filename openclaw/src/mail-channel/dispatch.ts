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
  /**
   * Message-ID the reply carried, when the transport reports one. `mail-cli smtp-send`
   * mints and returns it; Mail.app assigns one internally and reports nothing, so this is
   * optional rather than a lie.
   */
}) => Promise<{ sentMessageId?: string } | void> | { sentMessageId?: string } | void;

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
  /**
   * Fetches the message body. Read here rather than during classification so a dropped
   * message never costs a body fetch, and so the body is only ever loaded for mail the
   * agent is actually going to see.
   */
  readBody?: (messageId: string) => Promise<string | undefined>;
  onSuppressed?: (params: { address: string; reason: string }) => void;
  /**
   * Records that the agent replied in this thread, which is what lets a later reply from
   * this correspondent be permitted under the thread rule.
   *
   * Called only after a reply was actually sent. Recording on permission rather than on
   * delivery would grant thread standing for a message that never left.
   */
  recordThread?: (reply: {
    inboundMessageId: string;
    sentMessageId?: string;
    recipients: readonly string[];
  }) => Promise<void> | void;
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

/**
 * Builds the prompt body.
 *
 * The subject and body are attacker-authored for any sender the operator has not vetted,
 * so they are presented as quoted message content rather than as bare instructions.
 */
function buildPrompt(subject: string | undefined, body: string | undefined): string {
  const parts: string[] = [];
  if (subject) {
    parts.push(`Subject: ${subject}`);
  }
  if (body?.trim()) {
    parts.push(body.trim());
  }
  return parts.join("\n\n");
}

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
  const body = await deps.readBody?.(message.message.messageId);
  let sentCount = 0;
  const egress = decideReplyDelivery(message, options);
  const mayReply = !observeOnly && egress.permitted.length > 0;

  if (!mayReply) {
    const reason = observeOnly ? "observe_only" : (egress.denied[0]?.reason ?? "not_permitted");
    deps.onSuppressed?.({ address: message.address, reason });
  }

  await deps.dispatchReply({
    ctx: {
      // Subject and body together. Without the body the agent sees a subject line and
      // nothing else, which reads as a real message and is not one.
      Body: buildPrompt(message.message.subject, body),
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
        const sent = await deps.sendReply({
          messageId: message.message.messageId,
          to: message.address,
          body: text,
        });
        sentCount += 1;
        // After delivery, never before: thread standing has to follow a message that
        // actually left, or a suppressed reply would still widen permission.
        await deps.recordThread?.({
          inboundMessageId: message.message.messageId,
          sentMessageId: sent?.sentMessageId,
          recipients: [message.address],
        });
      },
    },
  });

  // Report what happened, not what was allowed. Permission plus an empty model response
  // is "nothing was sent", and a caller logging delivery must not be told otherwise.
  return {
    replied: sentCount > 0,
    reason: !mayReply ? "suppressed" : sentCount > 0 ? (egress.reasons[0] ?? "permitted") : "empty_reply",
  };
}
