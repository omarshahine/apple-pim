/**
 * Real `mail-cli`-backed implementations of the inbound dependencies.
 *
 * Everything here shells out; everything above it is pure. That split is why the policy,
 * cursor, and loop can be tested exhaustively without a mailbox.
 *
 * All calls use `--engine sqlite`, which reads the Envelope Index and the emlx files on
 * disk. That is what lets the channel run without Mail.app being open, which matters
 * because Mail.app does not stay running unattended.
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { MailAuthCheckResult } from "../mail-auth/strength.ts";
import type { InboundDeps, MailboxMessage, MessageThreadHeaders } from "./inbound.ts";
import type { ReplySender } from "./dispatch.ts";
import type { ConfigCheckInput } from "./config-check.ts";

const run = promisify(execFile);

/**
 * Every command this module runs identifies accounts by UUID, never by display name.
 *
 * The two engines use different namespaces: JXA reports the account's display name (for
 * example `iCloud`) while SQLite reports its UUID, and handing SQLite a display name fails
 * with "Account not found". Reads go through `--engine sqlite`, and replies now go through
 * `smtp-send`, which is account-agnostic, so no caller here needs the display name. It
 * survives in config only for keying `trustedAuthservIds`, which is a different concern.
 */
export type MailCliOptions = {
  /** Directory holding the Swift CLIs. Falls back to whatever is on PATH. */
  binDir?: string;
  /** Path to trusted-senders.json, which carries expectedDkimDomains and authserv-ids. */
  trustedSendersPath?: string;
  /**
   * SQLite account UUID, from `mail-cli accounts --engine sqlite`.
   *
   * Scopes reads to one account. Without it a mailbox name matches in every configured
   * account, so a multi-account Mail.app would feed one account's policy with another
   * account's mail. Optional because a single-account install cannot be harmed by the
   * broader query, and `checkChannelConfig` reports the risk when it is absent.
   */
  accountId?: string;
  /**
   * Envelope sender for replies, normally the channel's own address.
   *
   * `smtp-send` falls back to `smtp.username` from mail-cli's own config when this is
   * absent, so it is optional; passing it keeps the address the channel replies from tied
   * to the account it reads, rather than to whatever the CLI happens to be configured with.
   */
  fromAddress?: string;
  /** Per-call timeout. A hung CLI must not stall the poll loop forever. */
  timeoutMs?: number;
};

const DEFAULT_TIMEOUT_MS = 60_000;

function binary(options: MailCliOptions): string {
  return options.binDir ? path.join(options.binDir, "mail-cli") : "mail-cli";
}

async function runJson<T>(options: MailCliOptions, args: string[]): Promise<T> {
  const { stdout } = await run(binary(options), args, {
    timeout: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    maxBuffer: 32 * 1024 * 1024,
  });
  return JSON.parse(stdout) as T;
}

/** Mirrors mail-cli's own default, so both sides read the same file when none is configured. */
const DEFAULT_TRUSTED_SENDERS = "~/.config/apple-pim/trusted-senders.json";

/** Expands a leading `~`, which mail-cli does natively and Node does not. */
export function expandHome(input: string): string {
  return input.startsWith("~/") ? path.join(os.homedir(), input.slice(2)) : input;
}

/**
 * Reads `trusted-senders.json` for the startup configuration checks.
 *
 * Returns the pieces `checkChannelConfig` reads, leaving `trustedSenders` undefined when the
 * file is missing or unparseable. That is not smoothed over: an absent file means nothing
 * can authenticate, which is a finding rather than a default.
 */
export async function readTrustedSenders(
  trustedSendersPath?: string,
): Promise<Pick<ConfigCheckInput, "trustedSenders" | "trustedAuthservIds">> {
  const resolved = expandHome(trustedSendersPath ?? DEFAULT_TRUSTED_SENDERS);
  try {
    const parsed = JSON.parse(await readFile(resolved, "utf8")) as {
      trustedSenders?: ConfigCheckInput["trustedSenders"];
      trustedAuthservIds?: ConfigCheckInput["trustedAuthservIds"];
    };
    return {
      // A file whose `trustedSenders` is not an array is as unusable as a missing one.
      trustedSenders: Array.isArray(parsed.trustedSenders) ? parsed.trustedSenders : undefined,
      trustedAuthservIds: parsed.trustedAuthservIds,
    };
  } catch {
    return { trustedSenders: undefined, trustedAuthservIds: undefined };
  }
}

/** Builds the inbound dependency set backed by the real CLI. */
export function createMailCliDeps(options: MailCliOptions): InboundDeps {
  // SQLite keys accounts by UUID, so only accountId belongs here. Passing the JXA display
  // name fails outright ("Account not found: iCloud").
  const accountArgs = options.accountId ? ["--account", options.accountId] : [];
  const trustedArgs = options.trustedSendersPath
    ? ["--trusted-senders", options.trustedSendersPath]
    : [];

  return {
    listMessages: async ({ mailbox, limit, since }) => {
      const result = await runJson<{ messages?: MailboxMessage[] }>(options, [
        "messages",
        "--mailbox",
        mailbox,
        "--limit",
        String(limit),
        // Pages forward from the cursor. Without it the CLI returns the newest page, so a
        // burst of new mail hides unprocessed older mail behind the row limit permanently.
        ...(since ? ["--since", since] : []),
        ...accountArgs,
        "--engine",
        "sqlite",
        "--format",
        "json",
      ]);
      return result.messages ?? [];
    },

    authCheck: async (messageId) =>
      runJson<MailAuthCheckResult>(options, [
        "auth-check",
        "--id",
        messageId,
        ...trustedArgs,
        ...accountArgs,
        "--engine",
        "sqlite",
      ]),

    readThreadHeaders: async (messageId) => {
      const result = await runJson<{ message?: { allHeaders?: unknown } }>(options, [
        "get",
        "--id",
        messageId,
        ...accountArgs,
        "--engine",
        "sqlite",
        "--format",
        "json",
      ]);
      return parseThreadHeaders(result.message?.allHeaders);
    },
  };
}

/**
 * Pulls `In-Reply-To` and `References` out of raw headers.
 *
 * These are sender-controlled and are treated as *claims* by `decideThreadReply`, which
 * checks them against what the agent recorded sending. Nothing here grants anything.
 */
export function parseThreadHeaders(allHeaders: unknown): MessageThreadHeaders {
  const text =
    typeof allHeaders === "string"
      ? allHeaders
      : allHeaders && typeof allHeaders === "object"
        ? Object.entries(allHeaders as Record<string, unknown>)
            .map(([key, value]) => `${key}: ${String(value)}`)
            .join("\n")
        : "";
  if (!text) {
    return {};
  }
  // Unfold continuation lines before matching; both headers commonly wrap.
  const unfolded = text.replace(/\r?\n[ \t]+/g, " ");
  const inReplyTo = /^in-reply-to:\s*(.+)$/im.exec(unfolded)?.[1]?.trim();
  const referencesRaw = /^references:\s*(.+)$/im.exec(unfolded)?.[1];
  const references = referencesRaw
    ?.split(/\s+/)
    .map((value) => value.trim())
    .filter(Boolean);
  return {
    ...(inReplyTo ? { inReplyTo } : {}),
    ...(references && references.length > 0 ? { references } : {}),
  };
}

/** Prefixes `Re:` unless the subject already carries one, matching normal client behavior. */
export function replySubject(subject: string | undefined): string {
  const trimmed = subject?.trim();
  if (!trimmed) {
    return "Re:";
  }
  return /^re:/i.test(trimmed) ? trimmed : `Re: ${trimmed}`;
}

/**
 * Network-safe iCloud defaults for installations that use the CLI's implicit iCloud host.
 * Other senders keep their configured SMTP transport untouched.
 */
export function replyTransportArgs(fromAddress: string | undefined): string[] {
  const domain = fromAddress?.split("@").at(-1)?.trim().toLowerCase();
  if (!domain || !["icloud.com", "me.com", "mac.com"].includes(domain)) {
    return [];
  }
  return ["--tls-mode", "starttls", "--port", "587", "--no-imap-append-sent"];
}

/**
 * Sends a reply through `mail-cli smtp-send`.
 *
 * Deliberately not `mail-cli reply`, which drives Mail.app over JXA. That path asks Mail to
 * build a reply draft, and a draft arrives already quoting the original with the insertion
 * point inside quote level 1; writing the body into it renders the agent's own words as
 * quoted text. No prompt can undo that, because the quoting is applied after the text is
 * handed over.
 *
 * Composing the MIME message directly also settles two things the JXA path could not:
 *
 * - Reading already works with Mail.app closed (`--engine sqlite`), and now replying does
 *   too, so the channel no longer needs a GUI app running to answer.
 * - `smtp-send` mints and reports the `Message-ID`. Mail.app assigns one internally and
 *   reports nothing, which left `sentMessageIds` empty and forced thread permission to fall
 *   back to anchoring on inbound ids. Recording what we actually sent is what lets a later
 *   reply be proven to belong to a thread the agent started.
 */
export function createMailCliSender(options: MailCliOptions): ReplySender {
  return async ({ messageId, to, body, subject }) => {
    // Every value is an argv element, never a shell word, so agent-authored text cannot
    // become a command. execFile does not spawn a shell.
    const args = [
      "smtp-send",
      "--to",
      to,
      "--subject",
      replySubject(subject),
      "--body",
      body,
      // Port 465 is blocked on some otherwise-supported networks. Apply the known-good
      // iCloud submission path only to iCloud identities; custom SMTP senders must retain
      // the host, port, TLS, and Sent-folder behavior from their own configuration.
      ...replyTransportArgs(options.fromAddress),
      // Threads the reply onto the original. `smtp-send` derives `References` from this when
      // none is passed, which is correct for answering a message directly.
      "--in-reply-to",
      messageId,
      ...(options.fromAddress ? ["--from", options.fromAddress] : []),
    ];
    const result = await runJson<{ success?: boolean; messageId?: string; rejected?: unknown[] }>(
      options,
      args,
    );
    if (result.success === false) {
      throw new Error(
        `mail-cli smtp-send refused the reply to ${to}: ${JSON.stringify(result.rejected ?? [])}`,
      );
    }
    return { sentMessageId: result.messageId };
  };
}

/** Reads a message body via `mail-cli get`, for the agent prompt. */
export function createMailCliBodyReader(
  options: MailCliOptions,
): (messageId: string) => Promise<string | undefined> {
  // Also --engine sqlite, so also the UUID. See MailCliOptions.
  const accountArgs = options.accountId ? ["--account", options.accountId] : [];
  return async (messageId) => {
    const result = await runJson<{ message?: { content?: string }; content?: string }>(options, [
      "get",
      "--id",
      messageId,
      ...accountArgs,
      "--engine",
      "sqlite",
      "--format",
      "json",
    ]);
    return result.message?.content ?? result.content;
  };
}
