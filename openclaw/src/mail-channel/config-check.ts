/**
 * Startup configuration checks for the Apple Mail channel.
 *
 * Every control here fails closed, which is the right direction and the worst one to debug:
 * a control that silently does not apply looks exactly like one that passes. The specific
 * trap is that admission needs two files to agree. `allowFrom` in `openclaw.json` says who
 * may drive the agent; `trusted-senders.json` says what proves they are who they claim.
 * Configure the first and forget the second and, under the strict posture, that sender is
 * readable but never actionable, with nothing in the logs pointing at the missing half.
 *
 * So these run once at account start and say it out loud. Pure, so the rules are testable
 * without a mailbox; the caller supplies the parsed file.
 */

import type { IdentifierAuthentication } from "../mail-auth/strength.ts";

export type ConfigFinding = {
  /** Stable code, so a caller can suppress one check without pattern-matching prose. */
  code:
    | "loop_guard_disabled"
    | "trusted_senders_unreadable"
    | "no_trusted_authserv_id"
    | "allowlisted_not_enrolled"
    | "enrolled_without_expected_signers";
  message: string;
};

/** One `trustedSenders` entry, narrowed to what these checks read. */
export type TrustedSenderEntry = {
  name?: string;
  emails?: readonly string[];
  expectedDkimDomains?: readonly string[];
};

export type ConfigCheckInput = {
  allowFrom: readonly string[];
  selfAddresses: readonly string[];
  minIdentifierAuthentication: IdentifierAuthentication;
  trustedSendersPath?: string;
  /** Parsed `trustedSenders`, or undefined when the file could not be read or parsed. */
  trustedSenders?: readonly TrustedSenderEntry[];
  /** Parsed `trustedAuthservIds`, keyed by Mail.app account name, with `*` as the wildcard. */
  trustedAuthservIds?: Readonly<Record<string, readonly string[]>>;
};

function normalize(values: readonly string[] | undefined): Set<string> {
  return new Set((values ?? []).map((value) => value.trim().toLowerCase()).filter(Boolean));
}

/**
 * Returns everything wrong with this account's configuration, most severe first.
 *
 * Empty means the two files agree and the channel will behave the way the scenario doc
 * describes.
 */
export function checkChannelConfig(input: ConfigCheckInput): ConfigFinding[] {
  const findings: ConfigFinding[] = [];
  const path = input.trustedSendersPath ?? "trusted-senders.json";

  // I13. Without this the agent can answer its own mail, and the loop is only bounded by
  // however long it takes someone to notice.
  if (normalize(input.selfAddresses).size === 0) {
    findings.push({
      code: "loop_guard_disabled",
      message:
        "channels.apple-mail.selfAddresses is empty, so the loop guard cannot fire and the " +
        "agent may process its own replies. Set it to every address this account sends as.",
    });
  }

  if (!input.trustedSenders) {
    findings.push({
      code: "trusted_senders_unreadable",
      message:
        `${path} could not be read, so no sender can authenticate and every message will ` +
        "be dropped. This is the fail-closed state, not a working install.",
    });
    return findings;
  }

  // I3. auth-check refuses to read Authentication-Results from an unpinned authserv-id,
  // because a sender can write that header themselves.
  //
  // Scoped no further than "is anything configured". mail-cli picks the set from the
  // *message's* own account (`msg.mailbox().account().name()`, or the account UUID when the
  // display name does not resolve), so startup cannot know which key a future message will
  // land on, and guessing from the channel's `account` option would warn about working
  // installs. A diagnostic that cries wolf is worse than none.
  const configuredIds = Object.values(input.trustedAuthservIds ?? {}).flatMap((ids) =>
    (ids ?? []).filter((id) => id.trim().length > 0),
  );
  if (configuredIds.length === 0) {
    findings.push({
      code: "no_trusted_authserv_id",
      message:
        `${path} configures no trustedAuthservIds at all, so no Authentication-Results ` +
        "header is believed and every message is dropped. Run `mail-cli auth-check` on a " +
        "known-good message; it reports the authserv-ids observed, keyed by account name.",
    });
  }

  // Only the strict posture turns a missing enrollment into a behavior change. At the
  // default minimum an authenticated domain is enough to dispatch an allowlisted sender,
  // so reporting the gap there would be noise about a control nothing is relying on.
  if (input.minIdentifierAuthentication !== "verified") {
    return findings;
  }

  const enrolledWithSigners = new Set<string>();
  for (const sender of input.trustedSenders) {
    const hasSigners = (sender.expectedDkimDomains ?? []).some((d) => d.trim().length > 0);
    const emails = normalize(sender.emails);
    if (hasSigners) {
      for (const email of emails) {
        enrolledWithSigners.add(email);
      }
      continue;
    }
    if (emails.size > 0) {
      findings.push({
        code: "enrolled_without_expected_signers",
        message:
          `${path} enrolls ${sender.name ?? [...emails].join(", ")} with no ` +
          "expectedDkimDomains, so no signature can match and the address can never reach " +
          "`verified`. Add the signing domain; `mail-cli auth-check` reports the observed one.",
      });
    }
  }

  for (const entry of normalize(input.allowFrom)) {
    if (!enrolledWithSigners.has(entry)) {
      findings.push({
        code: "allowlisted_not_enrolled",
        message:
          `${entry} is in channels.apple-mail.allowFrom but has no expectedDkimDomains entry ` +
          `in ${path}. Under minIdentifierAuthentication "verified" their mail is readable ` +
          "but never actioned, because nothing binds that address to a signer.",
      });
    }
  }

  return findings;
}
