/**
 * Inbound polling and classification for the Apple Mail channel.
 *
 * All I/O is injected, so the whole path from "a message appeared" to "here is its
 * admission decision" is testable without a mailbox, a gateway, or Mail.app running.
 *
 * The channel polls rather than waiting to be pushed. That removes the dependency on a
 * mail-client rule staying installed, and it keeps the filter in the channel where policy
 * belongs instead of upstream where it would decide what the agent is allowed to see.
 */

import {
  defineStableChannelIngressIdentity,
  resolveChannelMessageIngress,
} from "openclaw/plugin-sdk/channel-ingress-runtime";
import {
  mailAuthToIdentifierStrengths,
  type IdentifierAuthentication,
  type MailAuthCheckResult,
  type MailIdentifierStrengths,
} from "../mail-auth/strength.ts";
import { decideIngress, type IngressDecision } from "./policy.ts";
import { decideThreadReply, type AgentThreadRecord } from "./thread.ts";

/**
 * Identity contract this channel presents to the ingress kernel.
 *
 * Entry-side `verified` states that an email address exactly names its holder; what any
 * *message* proved arrives per message on the subject side, so the kernel's
 * min(entry, subject) resolves to exactly the strength `mail-cli auth-check` established.
 */
const MAIL_INGRESS_IDENTITY = defineStableChannelIngressIdentity({
  key: "email",
  normalize: (value: string) => value.trim().toLowerCase(),
  sensitivity: "pii",
  authentication: "verified",
});

/** One row as listed by `mail-cli messages`. */
export type MailboxMessage = {
  messageId: string;
  sender: string;
  subject?: string;
  dateReceived?: string;
  isRead?: boolean;
  isJunk?: boolean;
  /**
   * Reported by `mail-cli messages`, so the agent learns attachments exist without anything
   * being fetched. Deciding to open one is the model's call, like the body.
   */
  attachmentCount?: number;
};

/** Thread headers, fetched only when a message might be a reply. */
export type MessageThreadHeaders = {
  inReplyTo?: string | null;
  references?: readonly string[];
};

export type InboundDeps = {
  /**
   * Lists candidate messages.
   *
   * With `since`, returns the *oldest* messages at or after that timestamp; without it, the
   * newest. The poll loop always passes its cursor, so it pages forward through the backlog
   * rather than repeatedly grabbing whatever just arrived.
   */
  listMessages: (params: {
    mailbox: string;
    limit: number;
    since?: string;
  }) => Promise<MailboxMessage[]>;
  /** Runs `mail-cli auth-check` for one message. */
  authCheck: (messageId: string) => Promise<MailAuthCheckResult>;
  /** Reads References / In-Reply-To for one message. */
  readThreadHeaders?: (messageId: string) => Promise<MessageThreadHeaders>;
};

/**
 * Watermark plus the ids seen at that instant.
 *
 * A timestamp alone is not enough: two messages can share a `dateReceived` to the second,
 * and a strictly-after comparison would skip one of them forever while a
 * greater-or-equal comparison would reprocess the other on every poll.
 */
export type PollCursor = {
  lastDateReceived?: string;
  seenAtWatermark?: readonly string[];
  /**
   * Ids of messages that arrived without a `dateReceived`. They cannot be placed against
   * the watermark, so they need their own dedupe set or they are re-classified on every
   * poll forever. Bounded, because an unbounded set in a cursor that gets persisted every
   * cycle is a slow leak.
   */
  seenUndated?: readonly string[];
};

/** How many undated ids to retain. Undated mail is rare; this is a safety valve. */
const MAX_SEEN_UNDATED = 200;

export type SelectResult = {
  fresh: MailboxMessage[];
  cursor: PollCursor;
};

/** Extracts the address from `Name <a@b>` or a bare address. */
export function senderAddress(raw: string): string {
  const angled = /<([^>]+)>/.exec(raw);
  const value = angled?.[1] ?? raw;
  return value.trim().toLowerCase();
}

/**
 * Picks messages not yet processed and returns the cursor to persist.
 *
 * Junk is skipped here rather than in policy: a message the operator's own mail rules
 * already classified as junk was never addressed to the agent in any meaningful sense, and
 * running authentication over it wastes work on the highest-volume category of mail.
 */
export function selectNewMessages(
  messages: readonly MailboxMessage[],
  cursor: PollCursor,
): SelectResult {
  const seen = new Set(cursor.seenAtWatermark ?? []);
  const seenUndated = new Set(cursor.seenUndated ?? []);
  const candidates = messages.filter((message) => {
    if (message.isJunk) {
      return false;
    }
    if (!message.dateReceived) {
      // No timestamp: the watermark cannot place this message, so it gets its own set.
      return !seenUndated.has(message.messageId);
    }
    if (!cursor.lastDateReceived) {
      // Cold cursor: id identity is all we have.
      return !seen.has(message.messageId);
    }
    if (message.dateReceived > cursor.lastDateReceived) {
      return true;
    }
    if (message.dateReceived < cursor.lastDateReceived) {
      return false;
    }
    return !seen.has(message.messageId);
  });

  const dates = [...messages].map((message) => message.dateReceived).filter(Boolean) as string[];
  const highest = dates.length > 0 ? dates.sort().at(-1) : cursor.lastDateReceived;
  const atWatermark = messages
    .filter((message) => message.dateReceived && message.dateReceived === highest)
    .map((message) => message.messageId);

  const undatedIds = messages.filter((message) => !message.dateReceived).map((m) => m.messageId);

  return {
    fresh: candidates,
    cursor: {
      lastDateReceived: highest,
      seenUndated: [...new Set([...(cursor.seenUndated ?? []), ...undatedIds])].slice(
        -MAX_SEEN_UNDATED,
      ),
      // Carry forward prior ids when the watermark did not move, so a poll that returns
      // nothing new cannot erase the dedupe set and cause a replay on the next one.
      seenAtWatermark:
        highest && highest === cursor.lastDateReceived
          ? [...new Set([...(cursor.seenAtWatermark ?? []), ...atWatermark])]
          : atWatermark,
    },
  };
}

export type ClassifiedMessage = {
  message: MailboxMessage;
  address: string;
  decision: IngressDecision;
  /**
   * The kernel's own reason code for the ingress outcome, carried for receipts and
   * diagnostics. The channel-level `decision.reason` stays the product vocabulary.
   */
  kernelReasonCode: string;
  /**
   * Which conversation this message belongs to, for session scoping.
   *
   * The anchor the agent already recorded for the thread when the claim resolves to one,
   * so every later message in that exchange shares a session. Otherwise the message's own
   * id, which makes it the root of a thread of its own. A newsletter therefore gets a
   * session nobody else joins, and a reply joins the session its parent started.
   */
  threadKey: string;
};

export type ClassifyOptions = {
  /** Minimum strength an identifier needs before it may authorize. */
  minIdentifierAuthentication: IdentifierAuthentication;
  /**
   * Configured inbound allowlist. Membership is derived per message rather than passed
   * as a boolean: the caller does not know the sender address until this function has
   * parsed it, so asking the caller to precompute it invites passing a constant.
   */
  allowFrom?: readonly string[];
  /** Addresses the agent sends as, for the loop guard. */
  selfAddresses?: readonly string[];
  /** Threads the agent originated, for the reply rule. */
  threadRecords?: Iterable<AgentThreadRecord>;
};

/**
 * Runs one message through authentication, strength mapping, and admission.
 *
 * Thread headers are read only when records exist to match against, so the common case of
 * an agent that has sent nothing does no extra I/O.
 */
export async function classifyMessage(
  message: MailboxMessage,
  deps: InboundDeps,
  options: ClassifyOptions,
): Promise<ClassifiedMessage> {
  const address = senderAddress(message.sender);
  const allowlisted = (options.allowFrom ?? []).some(
    (entry) => entry.trim().toLowerCase() === address,
  );
  const selfAddressed = (options.selfAddresses ?? []).some(
    (entry) => entry.trim().toLowerCase() === address,
  );
  const auth = await deps.authCheck(message.messageId);
  const strengths = mailAuthToIdentifierStrengths(auth);

  let threadPermitted = false;
  let threadKey = message.messageId;
  const records = options.threadRecords ? [...options.threadRecords] : [];
  if (records.length > 0 && deps.readThreadHeaders) {
    const headers = await deps.readThreadHeaders(message.messageId);
    const thread = decideThreadReply(
      { inReplyTo: headers.inReplyTo, references: headers.references, senderAddress: address },
      records,
    );
    threadPermitted = thread.permitted;
    // Only a *permitted* thread claim sets the session key. `decideThreadReply` also returns
    // the matched id when it denies, and adopting that would let an authenticated stranger
    // who quotes a leaked Message-ID be filed into the session of the person the agent was
    // actually talking to, reading their history. Denying the reply while honouring the
    // claim for session scoping hands over exactly what the denial was protecting.
    if (thread.permitted && thread.matchedMessageId) {
      threadKey = thread.matchedMessageId;
    }
  }

  const resolved = await resolveMailIngress({
    address,
    strengths,
    allowFrom: options.allowFrom ?? [],
    allowlisted,
    selfAddressed,
    threadPermitted,
    minIdentifierAuthentication: options.minIdentifierAuthentication,
    conversationId: threadKey,
  });

  return { message, address, threadKey, ...resolved };
}

export type MailIngressParams = {
  /** Sender address, already normalized. */
  address: string;
  strengths: MailIdentifierStrengths;
  allowFrom: readonly string[];
  allowlisted: boolean;
  selfAddressed: boolean;
  threadPermitted: boolean;
  minIdentifierAuthentication: IdentifierAuthentication;
  /** Conversation the kernel scopes this resolution to; the thread key in practice. */
  conversationId: string;
};

/**
 * The channel's single admission path: the ingress kernel decides allowlist plus
 * authentication, then channel policy layers the loop guard and observe escalation.
 *
 * Exported so the scenario suite proves the same wiring `classifyMessage` runs, rather
 * than a parallel reimplementation that could drift.
 */
export async function resolveMailIngress(
  params: MailIngressParams,
): Promise<{ decision: IngressDecision; kernelReasonCode: string }> {
  // Thread permission enters the kernel as an injected allowlist entry: the agent already
  // chose to contact this person when it started the thread, so the *allowlist* is waived,
  // while the injected entry's subject-side strength is still gated like any other. The
  // authentication half of the thread rule therefore runs in the kernel, not here.
  const effectiveAllowFrom =
    params.threadPermitted && !params.allowlisted
      ? [...params.allowFrom, params.address]
      : [...params.allowFrom];

  const kernel = await resolveChannelMessageIngress({
    channelId: "apple-mail",
    accountId: "default",
    identity: MAIL_INGRESS_IDENTITY,
    subject: { stableId: params.address, authentication: { email: params.strengths.address } },
    conversation: { kind: "direct", id: params.conversationId },
    event: { kind: "message", authMode: "inbound", mayPair: false },
    policy: {
      dmPolicy: "allowlist",
      groupPolicy: "disabled",
      minIdentifierAuthentication: params.minIdentifierAuthentication,
    },
    allowFrom: effectiveAllowFrom,
  });

  return {
    kernelReasonCode: kernel.ingress.reasonCode,
    decision: decideIngress({
      kernelAdmitted: kernel.ingress.admission === "dispatch",
      domainVerified: params.strengths.domain === "verified",
      allowlisted: params.allowlisted,
      selfAddressed: params.selfAddressed,
      threadPermitted: params.threadPermitted,
    }),
  };
}
