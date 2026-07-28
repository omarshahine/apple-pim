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

/** Ordered authentication strength. Mirrors the RFC 0027 scale. */
export type IdentifierAuthentication = "verified" | "asserted" | "mutable";

const RANK: Record<IdentifierAuthentication, number> = {
  verified: 2,
  asserted: 1,
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
  /** Sender domain. Needs only a passing check from a trusted boundary. */
  domain: IdentifierAuthentication;
  /** Display name. Sender-chosen, so never above `mutable`. */
  displayName: IdentifierAuthentication;
};

/**
 * `unknown` means auth-check could not establish provenance at all: no trusted
 * authserv-id configured for the account, or no Authentication-Results from one. Nothing
 * in the message may be promoted, because the only evidence available is sender-writable.
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
 * - A passing DKIM signature, or an aligned SPF pass, proves something about the *domain*.
 * - Only a DKIM signature from a domain the operator listed in that sender's
 *   `expectedDkimDomains` says anything about the *mailbox*, which is what auth-check's
 *   own `verified` verdict already requires.
 */
export function mailAuthToIdentifierStrengths(
  result: MailAuthCheckResult,
): MailIdentifierStrengths {
  const displayName: IdentifierAuthentication = "mutable";

  if (!provenanceEstablished(result)) {
    return { address: "asserted", domain: "asserted", displayName };
  }

  // A DKIM pass authenticates the *signing* domain (header.d), which is not automatically
  // the sender's domain. Promoting on an unaligned signature would let any domain that can
  // sign anything vouch for this sender, the same defect alignment fixes for SPF.
  const dkimPassed = result.checks?.dkim?.result === "pass";
  const dkimAligned =
    dkimPassed && domainsAlign(result.checks?.dkim?.signingDomain, senderDomain(result.sender));
  // `match` on spf already folds in alignment; `aligned` is kept for diagnostics.
  const spfPassedAligned = result.checks?.spf?.match === true;

  const domain: IdentifierAuthentication =
    dkimAligned || spfPassedAligned ? "verified" : "asserted";

  // auth-check only returns `verified` when a DKIM signature matched the sender's
  // configured expectedDkimDomains (and SPF, unless that sender sets requireSpf=false).
  // That operator assertion is what carries the claim from domain to mailbox.
  const address: IdentifierAuthentication = result.verdict === "verified" ? "verified" : "asserted";

  return { address, domain, displayName };
}
