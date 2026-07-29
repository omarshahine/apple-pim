/**
 * Maps `mail-cli auth-check` output onto per-identifier authentication strength.
 *
 * This is the shim boundary for OpenClaw RFC 0027
 * (https://github.com/openclaw/rfcs/pull/51). Core does not yet ship
 * `IdentifierAuthentication`, so the type is declared locally and the gate is applied
 * plugin-side. When the kernel lands the primitive, this module keeps its logic and only
 * its consumers change: the strengths below are handed to the ingress subject instead of
 * being enforced here.
 *
 * The invariant this module exists to hold: strength is derived only from transport
 * metadata that our own boundary authenticated, never from sender-controlled message
 * content. `mail-cli auth-check` enforces the provenance half (authserv-id pinning, SPF
 * alignment); this module refuses to promote anything it cannot justify.
 */

/**
 * Ordered authentication strength. Mirrors the RFC 0027 scale.
 *
 * `unverified` and `mutable` are both untrustworthy and are separated because they are
 * untrustworthy for different reasons. A display name is weak because it is an *alias*: two
 * people can hold the same one, and it identifies nobody even when honestly set. An
 * unauthenticated `From:` is weak because nothing *bound* it to its sender: it is an exact,
 * stable identifier whose claimed ownership is simply unproven.
 *
 * This module originally collapsed the two, scoring an unauthenticated address `mutable`,
 * because three levels were all the scale had. That produced the right admission and the
 * wrong reason, which is how a diagnostic ends up describing a precise address as a
 * nickname. The RFC gained the fourth level after implementing it here surfaced the gap.
 */
export type IdentifierAuthentication = "verified" | "asserted" | "unverified" | "mutable";

const RANK: Record<IdentifierAuthentication, number> = {
  verified: 3,
  asserted: 2,
  unverified: 1,
  mutable: 0,
};

/** Returns true when `actual` meets or exceeds the required minimum. */
export function meetsMinimum(
  actual: IdentifierAuthentication,
  minimum: IdentifierAuthentication,
): boolean {
  return RANK[actual] >= RANK[minimum];
}

/** Returns the weaker of two strengths, which is how entry and subject sides combine. */
export function weakest(
  a: IdentifierAuthentication,
  b: IdentifierAuthentication,
): IdentifierAuthentication {
  return RANK[a] <= RANK[b] ? a : b;
}

/** Verdict vocabulary emitted by `mail-cli auth-check`. */
export type MailAuthVerdict = "verified" | "suspicious" | "unknown" | "untrusted";

/** Parsed shape of one `mail-cli auth-check` invocation. */
export type MailAuthCheckResult = {
  verdict: MailAuthVerdict;
  sender?: string;
  matchedContact?: string;
  checks?: {
    dkim?: { result?: string; signingDomain?: string; match?: boolean };
    spf?: { result?: string; mailFrom?: string; aligned?: boolean; match?: boolean };
  };
  warnings?: string[];
};

/** Strength for each identifier one inbound message yields. */
export type MailIdentifierStrengths = {
  /** Full sender address. Needs an operator assertion binding address to signing domain. */
  address: IdentifierAuthentication;
  /** Sender domain. Needs only a passing *aligned* check from a trusted boundary. */
  domain: IdentifierAuthentication;
  /** Display name. Sender-chosen, so never above `mutable`. */
  displayName: IdentifierAuthentication;
};

/**
 * `unknown` means auth-check could not establish provenance at all: no trusted
 * authserv-id configured for the account, or no Authentication-Results from one. Nothing
 * in the message may be promoted, because the only evidence available is sender-writable,
 * which is the definition of `mutable`.
 */
function provenanceEstablished(result: MailAuthCheckResult): boolean {
  return result.verdict !== "unknown";
}

/** Domain part of an address, lowercased. Empty when absent, which never aligns. */
function senderDomain(address: string | undefined): string {
  if (!address?.includes("@")) {
    return "";
  }
  return address.split("@").pop()?.trim().toLowerCase() ?? "";
}

/**
 * Relaxed-alignment approximation: exact match, or one domain is a subdomain of the other.
 * Without a public-suffix list this cannot compute true organizational domains, so it is
 * deliberately narrower than DMARC relaxed alignment rather than wider. Mirrors
 * `domainAligns` in MailCLI.swift so the two sides cannot drift apart in interpretation.
 */
function domainsAlign(a: string | undefined, b: string | undefined): boolean {
  const x = a?.trim().toLowerCase() ?? "";
  const y = b?.trim().toLowerCase() ?? "";
  if (!x || !y) {
    return false;
  }
  return x === y || x.endsWith(`.${y}`) || y.endsWith(`.${x}`);
}

/**
 * Maps one auth-check result onto per-identifier strengths.
 *
 * The address and the domain are deliberately scored differently, which is the whole
 * reason RFC 0027 is per-identifier rather than one per-message trust score:
 *
 * - An *aligned* passing DKIM signature, or an aligned SPF pass, proves the *domain*.
 * - Only auth-check's `verified` verdict, which requires a DKIM signature from a domain the
 *   operator listed in that sender's `expectedDkimDomains`, says anything about the
 *   *mailbox*.
 *
 * A `From` address with neither behind it scores `mutable`: a string the sender typed, with
 * no evidence from our side of the boundary. Scoring it `asserted` was the original defect
 * in this module. `asserted` has to mean "a trusted boundary stamped something about this",
 * because otherwise the address identifier has a floor of `asserted`, the default
 * `asserted` minimum is not a bar at all, and every allowlisted address is admitted on the
 * strength of its own `From` header. That is the I2/I7/I8 bypass in the scenario doc.
 */
export function mailAuthToIdentifierStrengths(
  result: MailAuthCheckResult,
): MailIdentifierStrengths {
  const displayName: IdentifierAuthentication = "mutable";

  if (!provenanceEstablished(result)) {
    return { address: "unverified", domain: "unverified", displayName };
  }

  // A DKIM pass authenticates the *signing* domain (header.d), which is not automatically
  // the sender's domain. Promoting on an unaligned signature would let any domain that can
  // sign anything vouch for this sender, the same defect alignment fixes for SPF.
  const dkimPassed = result.checks?.dkim?.result === "pass";
  const dkimAligned =
    dkimPassed && domainsAlign(result.checks?.dkim?.signingDomain, senderDomain(result.sender));
  // `match` on spf already folds in alignment; `aligned` is kept for diagnostics.
  const spfPassedAligned = result.checks?.spf?.match === true;
  const domainAuthenticated = dkimAligned || spfPassedAligned;

  // auth-check returns `verified` only when a DKIM signature matched the sender's configured
  // expectedDkimDomains. That operator assertion is what carries the claim from domain to
  // mailbox; without it the address can be no stronger than its domain.
  const operatorAssertedMailbox = result.verdict === "verified";

  const address: IdentifierAuthentication = operatorAssertedMailbox
    ? "verified"
    : domainAuthenticated
      ? "asserted"
      : "unverified";

  // An expected signer need not align: mailbox providers routinely sign with their own
  // domain (fastmail.com for a shahine.com address). Naming that signer for that sender is
  // a narrower operator statement than alignment, so it carries the domain claim as well.
  const domain: IdentifierAuthentication =
    domainAuthenticated || operatorAssertedMailbox ? "verified" : "unverified";

  return { address, domain, displayName };
}
