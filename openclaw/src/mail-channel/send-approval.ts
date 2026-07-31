/**
 * The gate that governs agent-originated mail (`apple_pim_mail action:"send"`).
 *
 * The reply path is already contained: an `observe`-only sender cannot be answered, because
 * the channel writes that decision to the shared admission store and the tool honors it. But
 * `send` originates a fresh message to arbitrary recipients with no message id, so nothing
 * tied it to the channel's egress policy. That left an asymmetry (issue #98): an agent that
 * read an `observe` sender's mail could still email that sender — or anyone — through `send`.
 *
 * This module closes it by running the same `decideEgress` the reply path uses, so send and
 * reply cannot disagree about who the agent may originate mail to. It is pure: it maps an
 * egress decision to one of three outcomes and leaves delivery, approval, and I/O to the
 * `before_tool_call` hook that consumes it.
 *
 *   - `allow`   — every recipient is the operator or on the egress allowlist. Send proceeds.
 *   - `loop`    — a recipient is one of the agent's own addresses. Hard-denied: emailing
 *                 itself is a loop, not an approval question.
 *   - `approve` — a recipient is off the allowlist. The operator is asked first, over their
 *                 regular channel, and the send fails closed on deny or timeout.
 */

import type { OpenClawConfig } from "openclaw/plugin-sdk/config-contracts";
import { decideEgress } from "./policy.ts";

const CHANNEL_ID = "apple-mail";

export type SendEgressPolicy = {
  operatorAddresses: string[];
  egressAllowlist: string[];
  selfAddresses: string[];
};

type ChannelBlock = { accounts?: Record<string, Partial<SendEgressPolicy>> } & Partial<SendEgressPolicy>;

const dedupe = (values: readonly unknown[]): string[] => [...new Set(values.map((value) => String(value)))];
const lower = (values: readonly unknown[]): string[] => values.map((value) => String(value).trim().toLowerCase());

/**
 * Reads the egress policy out of `channels.apple-mail`, scoped to the sender account, or
 * returns undefined when the channel is not configured.
 *
 * Undefined means the send tool is being used without the Apple Mail channel governing this
 * install, so it stays ungoverned exactly as it was before the channel existed — the channel
 * is what introduces outbound containment, and its absence is not a policy of its own.
 *
 * The allowlist and operator set are scoped to one sender identity, never unioned across
 * accounts: `send` exposes `from`, so unioning would let a recipient allowlisted for one
 * account authorize a send as any other account. `from` is matched against each account's self
 * addresses (accounts inherit the top-level block). A single-account install (the norm) reads
 * the top-level block directly. A multi-account send whose sender cannot be attributed fails
 * closed to an empty allowlist — every recipient then needs approval.
 *
 * The loop guard is the one exception: self addresses are unioned across every account, because
 * a send to any managed identity's own address is a loop no matter which account it claims to
 * be from, and that must hold even when the sender is unattributable.
 */
export function resolveSendEgressPolicy(cfg: OpenClawConfig, from?: string): SendEgressPolicy | undefined {
  const channels = (cfg as { channels?: Record<string, unknown> }).channels ?? {};
  const channel = channels[CHANNEL_ID] as ChannelBlock | undefined;
  if (!channel) {
    return undefined;
  }
  const accounts = channel.accounts ?? {};
  const accountIds = Object.keys(accounts);
  const allSelf = dedupe(
    [channel.selfAddresses ?? [], ...Object.values(accounts).map((account) => account?.selfAddresses ?? [])].flat(),
  );
  // An account block overrides the top-level block field-by-field, matching how the channel
  // resolves an account (`{ ...channel, ...account }`). Self addresses are always the union.
  const scoped = (account: Partial<SendEgressPolicy> | undefined): SendEgressPolicy => ({
    operatorAddresses: dedupe(account?.operatorAddresses ?? channel.operatorAddresses ?? []),
    egressAllowlist: dedupe(account?.egressAllowlist ?? channel.egressAllowlist ?? []),
    selfAddresses: allSelf,
  });

  const failClosed: SendEgressPolicy = { operatorAddresses: [], egressAllowlist: [], selfAddresses: allSelf };
  const fromAddr = from ? String(from).trim().toLowerCase() : "";

  // A supplied `from` must name a managed self identity in every config shape, top-level or
  // multi-account. A `from` we do not own is a send claiming an identity outside the channel,
  // so it inherits no allowlist and falls to approval — the same fail-closed stance as an
  // unattributable named-account send. Only the loop guard survives.
  if (fromAddr && !lower(allSelf).includes(fromAddr)) {
    return failClosed;
  }

  // Single-account install: the top-level block is the whole policy (its `from`, if any, is a
  // managed identity per the check above).
  if (accountIds.length === 0) {
    return scoped(undefined);
  }

  // Multi-account: attribute the send to exactly one identity so one account's allowlist cannot
  // authorize a send as another.
  if (fromAddr) {
    // Unique match only. An address shared across accounts — commonly because several inherit
    // the top-level `selfAddresses` — is ambiguous, and picking whichever appears first would
    // silently grant one account's allowlist to a send claiming that shared identity.
    const matches = accountIds.filter((id) =>
      lower(accounts[id]?.selfAddresses ?? channel.selfAddresses ?? []).includes(fromAddr),
    );
    if (matches.length === 1) {
      return scoped(accounts[matches[0]]);
    }
  } else if (accountIds.length === 1) {
    // A single named account is the only possible sender, so no `from` is needed to attribute it.
    return scoped(accounts[accountIds[0]]);
  } else if (accounts.default) {
    // No `from` addresses the default account, mirroring the channel's own `accountId ?? "default"`.
    return scoped(accounts.default);
  }
  // Ambiguous or absent sender across multiple accounts: fail closed, but keep the loop guard.
  return failClosed;
}

/** Collects every recipient a send addresses, across `to`, `cc`, and `bcc`. */
export function collectSendRecipients(params: Record<string, unknown>): string[] {
  const recipients: string[] = [];
  for (const key of ["to", "cc", "bcc"] as const) {
    const value = params[key];
    if (typeof value === "string") {
      recipients.push(value);
    } else if (Array.isArray(value)) {
      for (const address of value) {
        if (typeof address === "string") {
          recipients.push(address);
        }
      }
    }
  }
  return recipients;
}

export type SendClassification =
  | { kind: "allow" }
  | { kind: "loop"; addresses: string[] }
  | { kind: "approve"; unlisted: string[] };

/**
 * Classifies a send against the egress policy.
 *
 * Delegates the per-recipient matching to `decideEgress` so this and the reply path share one
 * policy. A fresh send is neither inside a thread the agent originated nor proof the operator
 * asked for this specific message, so both of those grants are false: the only silent
 * approvals are the operator and the explicit egress allowlist.
 */
export function classifySend(params: {
  recipients: readonly string[];
  policy: SendEgressPolicy;
}): SendClassification {
  const { recipients, policy } = params;
  // Nothing to govern; the tool handler's own required-recipient validation speaks instead.
  if (recipients.length === 0) {
    return { kind: "allow" };
  }
  const decision = decideEgress({
    recipients,
    operatorAddresses: policy.operatorAddresses,
    egressAllowlist: policy.egressAllowlist,
    selfAddresses: policy.selfAddresses,
    threadPermitted: false,
    operatorInstructed: false,
  });
  // The loop guard outranks approval: no operator decision can make emailing the agent's own
  // address anything but a loop, so it is denied outright rather than surfaced for approval.
  const loop = decision.denied
    .filter((entry) => entry.reason === "self_addressed")
    .map((entry) => entry.address);
  if (loop.length > 0) {
    return { kind: "loop", addresses: loop };
  }
  const unlisted = decision.denied
    .filter((entry) => entry.reason === "recipient_not_permitted")
    .map((entry) => entry.address);
  if (unlisted.length > 0) {
    return { kind: "approve", unlisted };
  }
  return { kind: "allow" };
}

/**
 * The full send-gate decision from raw tool params and the resolved policy.
 *
 * Folds in the dry-run skip so a validation-only send is never gated: `withAgentDX` returns a
 * preview and skips the CLI for any truthy `dryRun`, so there is no send to govern and asking
 * for approval would block a preview for the whole timeout. The truthy check mirrors
 * `withAgentDX` exactly, keeping the skip and the no-send in lockstep. Callers still gate on
 * tool name and `action:"send"` before reaching here.
 */
export function evaluateSend(params: Record<string, unknown>, policy: SendEgressPolicy): SendClassification {
  if (params.dryRun) {
    return { kind: "allow" };
  }
  return classifySend({ recipients: collectSendRecipients(params), policy });
}

/** Prompt text naming the unlisted recipients and the subject, for the operator who approves. */
export function describeSendApproval(unlisted: readonly string[], subject: string): string {
  const who = unlisted.join(", ");
  const what = subject.trim().length > 0 ? subject.trim() : "(no subject)";
  return (
    `Lobster wants to send an email to ${who}, which is not on your egress allowlist. ` +
    `Subject: "${what}". Approve only if you meant for the agent to originate this message.`
  );
}
