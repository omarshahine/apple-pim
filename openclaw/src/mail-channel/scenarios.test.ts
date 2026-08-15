/**
 * The ingress table from docs/mail-channel-scenarios.md, executed.
 *
 * The doc is the specification, and it drifted from the code once already: the scenario
 * rows said `drop` for I2/I7/I8 while the documented default minimum (`asserted`) admitted
 * every one of them, because the address identifier had a floor of `asserted` and so the
 * default was not a bar at all. Nothing caught it, because the unit tests either fixed the
 * minimum at `verified` or asserted the strengths without running them through admission.
 *
 * So each row runs the real `mail-cli auth-check` shape through the real strength mapping
 * and the real policy, at **both** configured postures. A row that changes behavior in the
 * code without changing here is a drift, and a row whose two postures disagree is a place
 * the operator's choice of minimum actually matters, which is worth stating explicitly.
 */

import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import {
  mailAuthToIdentifierStrengths,
  type IdentifierAuthentication,
  type MailAuthCheckResult,
  type MailIdentifierStrengths,
} from "../mail-auth/strength.ts";
import { resolveMailIngress } from "./inbound.ts";
import type { Admission } from "./policy.ts";

const OPERATOR = "operator@example.com";

type Row = {
  id: string;
  what: string;
  auth: MailAuthCheckResult;
  allowlisted?: boolean;
  selfAddressed?: boolean;
  threadPermitted?: boolean;
  strengths: Pick<MailIdentifierStrengths, "address" | "domain">;
  /** Admission at the default `asserted` minimum. */
  atDefault: Admission;
  /** Admission at the strict `verified` minimum. */
  atStrict: Admission;
};

/** An Authentication-Results header from a trusted authserv-id, DKIM aligned and expected. */
const GENUINE: MailAuthCheckResult["checks"] = {
  dkim: { result: "pass", signingDomain: "example.com", match: true },
  spf: { result: "pass", mailFrom: OPERATOR, aligned: true, match: true },
};

/** Aligned pass, but no expectedDkimDomains entry binds the mailbox to that signer. */
function alignedButUnenrolled(domain: string): MailAuthCheckResult["checks"] {
  return {
    dkim: { result: "pass", signingDomain: domain, match: false },
    spf: { result: "pass", mailFrom: `bounce@${domain}`, aligned: true, match: true },
  };
}

const ROWS: Row[] = [
  {
    id: "I1",
    what: "operator, authenticated, enrolled",
    auth: { verdict: "verified", sender: OPERATOR, checks: GENUINE },
    allowlisted: true,
    strengths: { address: "verified", domain: "verified" },
    atDefault: "dispatch",
    atStrict: "dispatch",
  },
  {
    id: "I2",
    what: "operator's address, authentication failed",
    auth: {
      verdict: "suspicious",
      sender: OPERATOR,
      checks: { dkim: { result: "fail" }, spf: { result: "fail", match: false } },
    },
    allowlisted: true,
    strengths: { address: "unverified", domain: "unverified" },
    // The operator is not special. A failed authentication is dropped, not escalated.
    atDefault: "drop",
    atStrict: "drop",
  },
  {
    id: "I3",
    what: "operator's address, no trusted authserv-id configured",
    // auth-check fails closed and returns no checks at all: every header is sender-writable.
    auth: { verdict: "unknown", sender: OPERATOR },
    allowlisted: true,
    strengths: { address: "unverified", domain: "unverified" },
    atDefault: "drop",
    atStrict: "drop",
  },
  {
    id: "I4",
    what: "enrolled non-operator (family, colleague)",
    auth: {
      verdict: "verified",
      sender: "family@example.com",
      checks: { ...GENUINE, spf: { result: "pass", mailFrom: "family@example.com", match: true } },
    },
    allowlisted: true,
    strengths: { address: "verified", domain: "verified" },
    atDefault: "dispatch",
    atStrict: "dispatch",
  },
  {
    id: "I4a",
    what: "allowlisted, domain authenticated, not enrolled in trusted-senders.json",
    auth: {
      verdict: "untrusted",
      sender: "family@example.com",
      checks: alignedButUnenrolled("example.com"),
    },
    allowlisted: true,
    strengths: { address: "asserted", domain: "verified" },
    // The drift case: on `allowFrom` but with no expectedDkimDomains entry to bind the
    // mailbox. Under the strict posture it lands exactly where I5 does, readable but not
    // actionable, because it must never be admitted *less* than the same message would be
    // without the allowlist entry.
    atDefault: "dispatch",
    atStrict: "observe",
  },
  {
    id: "I5",
    what: "authenticated stranger",
    auth: {
      verdict: "untrusted",
      sender: "noreply@email.apple.com",
      checks: alignedButUnenrolled("email.apple.com"),
    },
    strengths: { address: "asserted", domain: "verified" },
    atDefault: "observe",
    atStrict: "observe",
  },
  {
    id: "I6",
    what: "unauthenticated stranger",
    auth: {
      verdict: "untrusted",
      sender: "stranger@example.com",
      checks: { dkim: { result: "none" }, spf: { result: "fail", match: false } },
    },
    strengths: { address: "unverified", domain: "unverified" },
    atDefault: "drop",
    atStrict: "drop",
  },
  {
    id: "I7",
    what: "spoofed operator, forged Authentication-Results",
    // The forged header carries an authserv-id we do not trust, so auth-check never reads
    // it and reports no checks. The forgery buys the attacker nothing.
    auth: { verdict: "suspicious", sender: OPERATOR },
    allowlisted: true,
    strengths: { address: "unverified", domain: "unverified" },
    atDefault: "drop",
    atStrict: "drop",
  },
  {
    id: "I8",
    what: "spoofed operator, valid SPF for the attacker's own domain",
    auth: {
      verdict: "suspicious",
      sender: OPERATOR,
      checks: {
        dkim: { result: "none" },
        // Passes for attacker.example, which is not the From domain. Unaligned proves nothing.
        spf: { result: "pass", mailFrom: "bounce@attacker.example", aligned: false, match: false },
      },
    },
    allowlisted: true,
    strengths: { address: "unverified", domain: "unverified" },
    atDefault: "drop",
    atStrict: "drop",
  },
  {
    id: "I9",
    what: "reply inside a thread the agent started, from an addressed participant",
    auth: {
      verdict: "untrusted",
      sender: "correspondent@example.com",
      checks: alignedButUnenrolled("example.com"),
    },
    threadPermitted: true,
    strengths: { address: "asserted", domain: "verified" },
    // Thread permission waives the allowlist, never authentication. Under the strict
    // posture a thread the agent itself started cannot be *acted on* unless the participant
    // is separately enrolled; the reply is still readable, because the grant failing to
    // apply must not put them below an ordinary authenticated stranger.
    atDefault: "dispatch",
    atStrict: "observe",
  },
  {
    id: "I10a",
    what: "claimed thread membership from a non-participant",
    // decideThreadReply already rejected the claim, so it arrives as ordinary new mail.
    auth: {
      verdict: "untrusted",
      sender: "stranger@example.com",
      checks: { dkim: { result: "none" }, spf: { result: "none", match: false } },
    },
    threadPermitted: false,
    strengths: { address: "unverified", domain: "unverified" },
    atDefault: "drop",
    atStrict: "drop",
  },
  {
    id: "I11",
    what: "bulk or marketing mail, authenticated",
    auth: {
      verdict: "untrusted",
      sender: "news@marketing.example",
      checks: alignedButUnenrolled("marketing.example"),
    },
    strengths: { address: "asserted", domain: "verified" },
    atDefault: "observe",
    atStrict: "observe",
  },
  {
    id: "I12",
    what: "forwarded mail, alignment broken in transit",
    auth: {
      verdict: "untrusted",
      sender: OPERATOR,
      checks: {
        dkim: { result: "pass", signingDomain: "forwarder.example", match: false },
        spf: { result: "fail", mailFrom: "bounce@forwarder.example", aligned: false, match: false },
      },
    },
    strengths: { address: "unverified", domain: "unverified" },
    atDefault: "drop",
    atStrict: "drop",
  },
  {
    id: "I13",
    what: "mail from the agent's own address",
    auth: { verdict: "verified", sender: "lobster@example.com", checks: GENUINE },
    allowlisted: true,
    selfAddressed: true,
    strengths: { address: "verified", domain: "verified" },
    // The loop guard runs before any grant, so even a perfectly authenticated message drops.
    atDefault: "drop",
    atStrict: "drop",
  },
];

/**
 * Runs one scenario row through the real ingress kernel via the channel's single
 * admission path, so this table proves `resolveChannelMessageIngress` end to end
 * rather than a local reimplementation of its gate.
 */
async function admissionFor(
  row: Pick<Row, "auth" | "allowlisted" | "selfAddressed" | "threadPermitted">,
  minimum: IdentifierAuthentication,
): Promise<Admission> {
  const strengths = mailAuthToIdentifierStrengths(row.auth);
  const address = row.auth.sender ?? "sender@example.test";
  const resolved = await resolveMailIngress({
    address,
    strengths,
    allowFrom: row.allowlisted ? [address] : [],
    allowlisted: row.allowlisted ?? false,
    selfAddressed: row.selfAddressed ?? false,
    threadPermitted: row.threadPermitted ?? false,
    minIdentifierAuthentication: minimum,
    conversationId: "scenario-thread",
  });
  return resolved.decision.admission;
}

describe("scenario doc: ingress table", () => {
  for (const row of ROWS) {
    it(`${row.id}: ${row.what}`, async () => {
      const strengths = mailAuthToIdentifierStrengths(row.auth);
      assert.equal(strengths.address, row.strengths.address, "address strength");
      assert.equal(strengths.domain, row.strengths.domain, "domain strength");

      assert.equal(
        await admissionFor(row, "asserted"),
        row.atDefault,
        "at the default `asserted` minimum",
      );
      assert.equal(
        await admissionFor(row, "verified"),
        row.atStrict,
        "at the strict `verified` minimum",
      );
    });
  }
});

describe("scenario doc: invariants across the table", () => {
  const RANK: Record<Admission, number> = { drop: 0, observe: 1, dispatch: 2 };

  // The inversion that made `allowFrom` actively harmful: at the strict minimum an
  // allowlisted-but-unenrolled sender dropped, while the identical message from a sender
  // *not* on the allowlist was admitted to `observe`. Enrolling someone must never reduce
  // what the channel does with their mail.
  it("adding a sender to allowFrom never lowers their admission", async () => {
    for (const row of ROWS) {
      if (row.selfAddressed) {
        continue;
      }
      for (const minimum of ["asserted", "verified"] as const) {
        const off = await admissionFor({ ...row, allowlisted: false }, minimum);
        const on = await admissionFor({ ...row, allowlisted: true }, minimum);
        assert.ok(
          RANK[on] >= RANK[off],
          `${row.id} at ${minimum}: allowlisted=${on} is weaker than allowlisted=false=${off}`,
        );
      }
    }
  });

  // Same argument for the other grant. Thread permission is a grant, and a grant that
  // cannot be exercised must leave the sender exactly where an ungranted one lands.
  it("thread permission never lowers admission", async () => {
    for (const row of ROWS) {
      if (row.selfAddressed) {
        continue;
      }
      for (const minimum of ["asserted", "verified"] as const) {
        const off = await admissionFor({ ...row, threadPermitted: false }, minimum);
        const on = await admissionFor({ ...row, threadPermitted: true }, minimum);
        assert.ok(
          RANK[on] >= RANK[off],
          `${row.id} at ${minimum}: threadPermitted=${on} is weaker than ungranted=${off}`,
        );
      }
    }
  });

  // The strict posture may only ever be at least as closed as the default. If a row is
  // admitted more freely under `verified`, the minimum is being read backwards somewhere.
  it("the strict minimum is never more permissive than the default", () => {
    for (const row of ROWS) {
      assert.ok(
        RANK[row.atStrict] <= RANK[row.atDefault],
        `${row.id}: strict=${row.atStrict} is more permissive than default=${row.atDefault}`,
      );
    }
  });

  // A `From` header nobody vouched for must not clear either posture an operator would
  // realistically run. Named for the two minimums it actually checks: the weak values are
  // break-glass and are asserted separately below, rather than folded in here where the
  // stored expectations would make this pass without testing them.
  it("no unauthenticated row reaches dispatch at either supported minimum", () => {
    const unauthenticated = ROWS.filter((r) => r.strengths.domain === "unverified");
    assert.ok(unauthenticated.length > 0, "the table must cover unauthenticated senders");
    for (const row of unauthenticated) {
      assert.equal(row.atDefault, "drop", `${row.id} at the default minimum`);
      assert.equal(row.atStrict, "drop", `${row.id} at the strict minimum`);
    }
  });

  // `unverified` is not offered as a config value because it would do nothing distinct: this
  // channel never scores an address or domain `mutable`, so the two weakest minimums admit
  // the same mail. If a future mapping emits `mutable` for an address, that stops being true
  // and this fails, which is the point.
  it("treats `unverified` and `mutable` as the same minimum, which is why only one is configurable", async () => {
    for (const row of ROWS) {
      if (row.selfAddressed) {
        continue;
      }
      assert.equal(
        await admissionFor(row, "unverified"),
        await admissionFor(row, "mutable"),
        row.id,
      );
    }
  });

  // And the break-glass value is genuinely break-glass: it admits what the real postures
  // reject, so nobody reads the equivalence above as "the weak setting is safe".
  it("the break-glass minimum does admit what the supported ones drop", async () => {
    const spoofed = ROWS.find((r) => r.id === "I7");
    assert.ok(spoofed, "I7 is the spoofed-operator row");
    const admission = await admissionFor({ auth: spoofed.auth, allowlisted: true }, "mutable");
    assert.equal(admission, "dispatch", "break-glass means exactly that");
  });
});
