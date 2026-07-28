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
import path from "node:path";
import type { MailAuthCheckResult } from "../mail-auth/strength.ts";
import type { InboundDeps, MailboxMessage, MessageThreadHeaders } from "./inbound.ts";

const run = promisify(execFile);

export type MailCliOptions = {
  /** Directory holding the Swift CLIs. Falls back to whatever is on PATH. */
  binDir?: string;
  /** Path to trusted-senders.json, which carries expectedDkimDomains and authserv-ids. */
  trustedSendersPath?: string;
  /** Mail.app account name, passed as a lookup hint. */
  account?: string;
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

/** Builds the inbound dependency set backed by the real CLI. */
export function createMailCliDeps(options: MailCliOptions): InboundDeps {
  const accountArgs = options.account ? ["--account", options.account] : [];
  const trustedArgs = options.trustedSendersPath
    ? ["--trusted-senders", options.trustedSendersPath]
    : [];

  return {
    listMessages: async ({ mailbox, limit }) => {
      const result = await runJson<{ messages?: MailboxMessage[] }>(options, [
        "messages",
        "--mailbox",
        mailbox,
        "--limit",
        String(limit),
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
