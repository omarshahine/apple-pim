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
    sender: "operator@example.com",
    checks: {
      dkim: { result: "pass", signingDomain: "example.com", match: true },
      spf: { result: "pass", mailFrom: "operator@example.com", aligned: true, match: true },
    },
    ...overrides,
  };
}

describe("ordering", () => {
  it("ranks verified above asserted above unverified above mutable", () => {
    assert.equal(meetsMinimum("verified", "asserted"), true);
    assert.equal(meetsMinimum("asserted", "asserted"), true);
    assert.equal(meetsMinimum("unverified", "asserted"), false);
    assert.equal(meetsMinimum("mutable", "asserted"), false);
    assert.equal(meetsMinimum("asserted", "verified"), false);
    // The two weak levels are distinct, not aliases: unverified outranks mutable.
    assert.equal(meetsMinimum("unverified", "mutable"), true);
    assert.equal(meetsMinimum("mutable", "unverified"), false);
  });

  it("takes the weaker side, which is how entry and subject combine", () => {
    assert.equal(weakest("verified", "mutable"), "mutable");
    assert.equal(weakest("verified", "asserted"), "asserted");
    assert.equal(weakest("verified", "verified"), "verified");
  });
});

describe("mailAuthToIdentifierStrengths", () => {
  // RFC 0027 conformance. The two weak levels mean different things, and this channel emits
  // exactly one of each: an alias it never checks, and an address nobody authenticated.
  // Conflating them was the original defect here, and produced a diagnostic that described
  // a precise address as a nickname.
  it("separates the unproven address from the alias", () => {
    const unauthenticated = mailAuthToIdentifierStrengths({
      verdict: "suspicious",
      sender: "operator@example.com",
      checks: { dkim: { result: "fail" }, spf: { result: "fail", match: false } },
    });
    assert.equal(unauthenticated.address, "unverified", "stable, attacker-chosen, unproven");
    assert.equal(unauthenticated.displayName, "mutable", "an alias, whoever set it");
    // Both are below the default minimum, so the distinction is descriptive, not permissive.
    assert.equal(meetsMinimum(unauthenticated.address, "asserted"), false);
    assert.equal(meetsMinimum(unauthenticated.displayName, "asserted"), false);
  });

  it("never emits `mutable` for an address, whatever the verdict", () => {
    for (const verdict of ["verified", "suspicious", "unknown", "untrusted"] as const) {
      const s = mailAuthToIdentifierStrengths(result({ verdict }));
      assert.notEqual(s.address, "mutable", verdict);
      assert.notEqual(s.domain, "mutable", verdict);
    }
  });

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
        dkim: { result: "pass", signingDomain: "example.com", match: true },
        spf: { result: "pass", mailFrom: "operator@example.com", aligned: true, match: true },
      },
      warnings: ["No trustedAuthservIds configured for account key 'iCloud'"],
    });
    assert.deepEqual(mailAuthToIdentifierStrengths(forged), {
      address: "unverified",
      domain: "unverified",
      displayName: "mutable",
    });
  });

  it("an unaligned SPF pass authenticates nothing about this sender", () => {
    const unaligned = result({
      verdict: "suspicious",
      checks: {
        dkim: { result: "none", signingDomain: "", match: false },
        spf: { result: "pass", mailFrom: "bounce@attacker.example", aligned: false, match: false },
      },
    });
    assert.equal(mailAuthToIdentifierStrengths(unaligned).domain, "unverified");
    assert.equal(mailAuthToIdentifierStrengths(unaligned).address, "unverified");
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
      address: "unverified",
      domain: "unverified",
      displayName: "mutable",
    });
  });

  it("accepts a subdomain signature as aligned", () => {
    const subdomainSigner = result({
      verdict: "suspicious",
      checks: {
        dkim: { result: "pass", signingDomain: "mail.example.com", match: false },
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
        dkim: { result: "pass", signingDomain: "example.com", match: false },
        spf: { result: "none", match: false },
      },
    });
    assert.deepEqual(mailAuthToIdentifierStrengths(alignedUnexpected), {
      address: "asserted",
      domain: "verified",
      displayName: "mutable",
    });
  });

  // Shape taken from a real `mail-cli auth-check` run against an unenrolled sender.
  // Before mail-cli was fixed it returned empty `checks` here, which made this case
  // indistinguishable from an unauthenticated stranger.
  it("verifies the domain but not the address for an authenticated stranger", () => {
    const stranger = result({
      verdict: "untrusted",
      sender: "noreply@email.apple.com",
      checks: {
        dkim: { result: "pass", signingDomain: "email.apple.com", match: false },
        spf: { result: "pass", mailFrom: "bounce@email.apple.com", aligned: true, match: true },
      },
    });
    const strengths = mailAuthToIdentifierStrengths(stranger);
    // No expectedDkimDomains binds this address to a signer, so no mailbox claim.
    assert.equal(strengths.address, "asserted");
    // The transport did prove the domain. This is what makes "read an authenticated
    // stranger, do not reply to them" expressible at all.
    assert.equal(strengths.domain, "verified");
  });

  it("keeps an unauthenticated stranger fully unverified", () => {
    const stranger = result({
      verdict: "untrusted",
      sender: "spoofed@example.com",
      checks: {
        dkim: { result: "none", signingDomain: "", match: false },
        spf: { result: "fail", aligned: false, match: false },
      },
    });
    assert.deepEqual(mailAuthToIdentifierStrengths(stranger), {
      address: "unverified",
      domain: "unverified",
      displayName: "mutable",
    });
  });

  it("treats missing checks as unproven rather than absent-therefore-fine", () => {
    assert.deepEqual(mailAuthToIdentifierStrengths({ verdict: "suspicious" }), {
      address: "unverified",
      domain: "unverified",
      displayName: "mutable",
    });
  });

  // Mailbox providers sign with their own domain, so the operator's expectedDkimDomains
  // entry routinely names a signer that does not align with the sender's domain. That
  // assertion is narrower than alignment, so it has to carry the domain claim too;
  // otherwise a correctly enrolled sender would come back verified-address / mutable-domain,
  // which `weakest()` would then collapse back to mutable.
  it("carries the domain claim when the operator named an unaligned expected signer", () => {
    const providerSigned = result({
      verdict: "verified",
      sender: "operator@example.com",
      checks: {
        dkim: { result: "pass", signingDomain: "fastmail.com", match: true },
        spf: { result: "pass", mailFrom: "operator@example.com", aligned: true, match: true },
      },
    });
    assert.deepEqual(mailAuthToIdentifierStrengths(providerSigned), {
      address: "verified",
      domain: "verified",
      displayName: "mutable",
    });
  });

  // The bug this mapping exists to prevent. `address` used to have a floor of `asserted`,
  // so `mutable` was unreachable for it and the default `asserted` minimum was not a bar.
  it("reaches unverified on the address, so the default minimum is a real bar", () => {
    const unauthenticated: MailAuthCheckResult[] = [
      { verdict: "unknown", sender: "operator@example.com" },
      { verdict: "suspicious", sender: "operator@example.com" },
      { verdict: "untrusted", sender: "operator@example.com" },
    ];
    for (const r of unauthenticated) {
      const strengths = mailAuthToIdentifierStrengths(r);
      assert.equal(strengths.address, "unverified", `verdict ${r.verdict}`);
      assert.equal(meetsMinimum(strengths.address, "asserted"), false, `verdict ${r.verdict}`);
    }
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

  // The default minimum is `asserted`, and it has to reject a message that authenticated
  // nothing even when the allowlist entry itself is a fully verified address.
  it("the default minimum rejects a message that proved nothing, however strong the entry", () => {
    const subject = mailAuthToIdentifierStrengths(
      result({
        verdict: "suspicious",
        checks: { dkim: { result: "fail" }, spf: { result: "fail", match: false } },
      }),
    ).address;
    assert.equal(meetsMinimum(weakest("verified", subject), "asserted"), false);
  });

  // I5: the domain authenticated but no operator assertion binds the mailbox. Readable at
  // the default minimum, and still short of the strict posture.
  it("an authenticated stranger clears asserted but not verified", () => {
    const stranger = mailAuthToIdentifierStrengths(
      result({
        verdict: "untrusted",
        sender: "noreply@email.apple.com",
        checks: {
          dkim: { result: "pass", signingDomain: "email.apple.com", match: false },
          spf: { result: "pass", mailFrom: "bounce@email.apple.com", aligned: true, match: true },
        },
      }),
    ).address;
    assert.equal(meetsMinimum(stranger, "asserted"), true);
    assert.equal(meetsMinimum(stranger, "verified"), false);
  });
});
