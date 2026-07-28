import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import {
  mailAuthToIdentifierStrengths,
  meetsMinimum,
  weakest,
  type MailAuthCheckResult,
} from "./strength.ts";

/** Builds an auth-check result without restating unrelated fields in every case. */
function result(overrides: Partial<MailAuthCheckResult> = {}): MailAuthCheckResult {
  return {
    verdict: "verified",
    sender: "omar@shahine.com",
    checks: {
      dkim: { result: "pass", signingDomain: "shahine.com", match: true },
      spf: { result: "pass", mailFrom: "omar@shahine.com", aligned: true, match: true },
    },
    ...overrides,
  };
}

describe("ordering", () => {
  it("ranks verified above asserted above mutable", () => {
    assert.equal(meetsMinimum("verified", "asserted"), true);
    assert.equal(meetsMinimum("asserted", "asserted"), true);
    assert.equal(meetsMinimum("mutable", "asserted"), false);
    assert.equal(meetsMinimum("asserted", "verified"), false);
  });

  it("takes the weaker side, which is how entry and subject combine", () => {
    assert.equal(weakest("verified", "mutable"), "mutable");
    assert.equal(weakest("verified", "asserted"), "asserted");
    assert.equal(weakest("verified", "verified"), "verified");
  });
});

describe("mailAuthToIdentifierStrengths", () => {
  it("a display name is never promoted, whatever the verdict", () => {
    for (const verdict of ["verified", "suspicious", "unknown", "untrusted"] as const) {
      assert.equal(mailAuthToIdentifierStrengths(result({ verdict })).displayName, "mutable");
    }
  });

  it("genuine mail from an enrolled sender verifies both address and domain", () => {
    assert.deepEqual(mailAuthToIdentifierStrengths(result()), {
      address: "verified",
      domain: "verified",
      displayName: "mutable",
    });
  });

  // The forged-header case. auth-check reports `unknown` when no Authentication-Results
  // came from a trusted authserv-id, so the only headers present are sender-writable.
  it("refuses to promote anything when provenance was never established", () => {
    const forged = result({
      verdict: "unknown",
      checks: {
        dkim: { result: "pass", signingDomain: "shahine.com", match: true },
        spf: { result: "pass", mailFrom: "omar@shahine.com", aligned: true, match: true },
      },
      warnings: ["No trustedAuthservIds configured for account key 'iCloud'"],
    });
    assert.deepEqual(mailAuthToIdentifierStrengths(forged), {
      address: "asserted",
      domain: "asserted",
      displayName: "mutable",
    });
  });

  it("an unaligned SPF pass does not verify the domain", () => {
    const unaligned = result({
      verdict: "suspicious",
      checks: {
        dkim: { result: "none", signingDomain: "", match: false },
        spf: { result: "pass", mailFrom: "bounce@attacker.example", aligned: false, match: false },
      },
    });
    assert.equal(mailAuthToIdentifierStrengths(unaligned).domain, "asserted");
    assert.equal(mailAuthToIdentifierStrengths(unaligned).address, "asserted");
  });

  // A DKIM pass authenticates header.d, not the From domain. An unaligned signature means
  // some unrelated domain signed this message, which vouches for nobody.
  it("does not verify the domain on an unaligned DKIM signature", () => {
    const unalignedSigner = result({
      verdict: "suspicious",
      checks: {
        dkim: { result: "pass", signingDomain: "bulk-sender.example", match: false },
        spf: { result: "none", match: false },
      },
    });
    assert.deepEqual(mailAuthToIdentifierStrengths(unalignedSigner), {
      address: "asserted",
      domain: "asserted",
      displayName: "mutable",
    });
  });

  it("accepts a subdomain signature as aligned", () => {
    const subdomainSigner = result({
      verdict: "suspicious",
      checks: {
        dkim: { result: "pass", signingDomain: "mail.shahine.com", match: false },
        spf: { result: "none", match: false },
      },
    });
    assert.equal(mailAuthToIdentifierStrengths(subdomainSigner).domain, "verified");
  });

  // The case that motivates per-identifier scoring: the signature aligns, so the domain
  // claim stands, but nothing binds this mailbox to that signer.
  it("verifies the domain but not the address when the signer is aligned but unexpected", () => {
    const alignedUnexpected = result({
      verdict: "suspicious",
      checks: {
        dkim: { result: "pass", signingDomain: "shahine.com", match: false },
        spf: { result: "none", match: false },
      },
    });
    assert.deepEqual(mailAuthToIdentifierStrengths(alignedUnexpected), {
      address: "asserted",
      domain: "verified",
      displayName: "mutable",
    });
  });

  it("does not verify the address for a sender who is not enrolled", () => {
    const stranger = result({
      verdict: "untrusted",
      sender: "someone@example.com",
      checks: { dkim: { result: "pass", signingDomain: "example.com", match: false } },
    });
    const strengths = mailAuthToIdentifierStrengths(stranger);
    assert.equal(strengths.address, "asserted");
    // Provenance held and DKIM passed, so the domain claim still stands. This is what
    // makes "authenticated stranger, readable but not repliable" expressible.
    assert.equal(strengths.domain, "verified");
  });

  it("treats missing checks as unproven rather than absent-therefore-fine", () => {
    assert.deepEqual(mailAuthToIdentifierStrengths({ verdict: "suspicious" }), {
      address: "asserted",
      domain: "asserted",
      displayName: "mutable",
    });
  });
});

describe("policy composition", () => {
  // Mirrors the RFC's min(entry, subject) rule: a display-name allowlist entry stays weak
  // no matter how strongly the message authenticated.
  it("a mutable allowlist entry cannot be rescued by a verified message", () => {
    const subject = mailAuthToIdentifierStrengths(result()).address;
    assert.equal(meetsMinimum(weakest("mutable", subject), "asserted"), false);
  });

  it("a verified message clears a verified minimum on the address entry", () => {
    const subject = mailAuthToIdentifierStrengths(result()).address;
    assert.equal(meetsMinimum(weakest("verified", subject), "verified"), true);
  });

  it("today's default minimum admits anything non-mutable, preserving current behavior", () => {
    const subject = mailAuthToIdentifierStrengths(result({ verdict: "suspicious" })).address;
    assert.equal(meetsMinimum(weakest("verified", subject), "asserted"), true);
  });
});
