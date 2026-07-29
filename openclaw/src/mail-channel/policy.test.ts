import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { decideEgress, decideIngress, type IngressInput } from "./policy.ts";
import type { MailIdentifierStrengths } from "../mail-auth/strength.ts";

const VERIFIED: MailIdentifierStrengths = {
  address: "verified",
  domain: "verified",
  displayName: "mutable",
};
const AUTHENTICATED_STRANGER: MailIdentifierStrengths = {
  address: "asserted",
  domain: "verified",
  displayName: "mutable",
};
// Nothing authenticated, so both identifiers are `unverified`: presented by a party nobody
// vouched for. `asserted` here would model a state the mapper cannot produce and would stop
// these cases distinguishing a proven domain from an unproven one.
const UNAUTHENTICATED: MailIdentifierStrengths = {
  address: "unverified",
  domain: "unverified",
  displayName: "mutable",
};

function ingress(overrides: Partial<IngressInput> = {}): IngressInput {
  return {
    strengths: VERIFIED,
    senderAddress: "omar@shahine.com",
    allowlisted: true,
    minIdentifierAuthentication: "verified",
    selfAddressed: false,
    threadPermitted: false,
    ...overrides,
  };
}

describe("ingress admission", () => {
  it("I1: dispatches an authenticated, allowlisted sender", () => {
    assert.deepEqual(decideIngress(ingress()), {
      admission: "dispatch",
      reason: "allowlisted_and_authenticated",
    });
  });

  it("I2: drops an allowlisted sender whose message did not authenticate", () => {
    // The operator gets no exception. Making one would invert the whole model.
    assert.deepEqual(decideIngress(ingress({ strengths: UNAUTHENTICATED })), {
      admission: "drop",
      reason: "identifier_authentication_too_weak",
    });
  });

  it("I5: observes an authenticated stranger, never dispatches", () => {
    assert.deepEqual(
      decideIngress(ingress({ strengths: AUTHENTICATED_STRANGER, allowlisted: false })),
      { admission: "observe", reason: "authenticated_but_not_allowlisted" },
    );
  });

  it("I6: drops an unauthenticated stranger", () => {
    assert.deepEqual(decideIngress(ingress({ strengths: UNAUTHENTICATED, allowlisted: false })), {
      admission: "drop",
      reason: "unauthenticated_sender",
    });
  });

  it("I7/I8: a forged or unaligned pass lands as unauthenticated, not as a stranger to read", () => {
    // Both attacks resolve to unverified/unverified upstream, so they cannot reach observe:
    // the `observe` branch needs a verified domain, and nothing proved one.
    const forged = decideIngress(ingress({ strengths: UNAUTHENTICATED, allowlisted: false }));
    assert.equal(forged.admission, "drop");
  });

  it("I13: drops self-addressed mail before any grant applies", () => {
    // Loop guard must outrank thread permission, which would otherwise dispatch it.
    assert.deepEqual(decideIngress(ingress({ selfAddressed: true, threadPermitted: true })), {
      admission: "drop",
      reason: "self_addressed",
    });
  });

  it("thread permission waives the allowlist but not authentication", () => {
    // Greptile P1: an attacker who learns a participant's address and an agent
    // Message-ID could otherwise spoof From and inherit the thread grant.
    assert.deepEqual(
      decideIngress(
        ingress({ allowlisted: false, strengths: UNAUTHENTICATED, threadPermitted: true }),
      ),
      { admission: "drop", reason: "identifier_authentication_too_weak" },
    );
  });

  it("I9: dispatches a thread reply from a sender who is not allowlisted", () => {
    assert.deepEqual(
      decideIngress(
        ingress({
          allowlisted: false,
          strengths: VERIFIED,
          threadPermitted: true,
        }),
      ),
      { admission: "dispatch", reason: "thread_originated_by_agent" },
    );
  });

  // This test used to assert the opposite, and passed only because the fixture above scored
  // an unauthenticated address `asserted`. It was the original bypass written down as
  // expected behavior: allowlisted plus the shipped default minimum, admitted with nothing
  // authenticated. Correcting the fixture surfaced it.
  it("drops an allowlisted sender who authenticated nothing, at the shipped default", () => {
    const decision = decideIngress(
      ingress({ strengths: UNAUTHENTICATED, minIdentifierAuthentication: "asserted" }),
    );
    assert.equal(decision.admission, "drop");
    assert.equal(decision.reason, "identifier_authentication_too_weak");
  });

  it("admits that same sender only under the break-glass minimum", () => {
    assert.equal(
      decideIngress(
        ingress({ strengths: UNAUTHENTICATED, minIdentifierAuthentication: "mutable" }),
      ).admission,
      "dispatch",
    );
  });
});

describe("egress", () => {
  const base = {
    operatorAddresses: ["omar@shahine.com"],
    egressAllowlist: ["known@example.com"],
    selfAddresses: ["lobster@example.com"],
    threadPermitted: false,
    operatorInstructed: false,
  };

  it("E3: always permits the operator", () => {
    const d = decideEgress({ ...base, recipients: ["omar@shahine.com"] });
    assert.deepEqual(d.permitted.map((e) => e.address), ["omar@shahine.com"]);
    assert.equal(d.denied.length, 0);
  });

  it("E5: denies an arbitrary address by default", () => {
    const d = decideEgress({ ...base, recipients: ["stranger@example.com"] });
    assert.deepEqual(d.permitted, []);
    assert.equal(d.denied[0]?.reason, "recipient_not_permitted");
  });

  it("E4: permits an explicitly allowlisted recipient", () => {
    assert.deepEqual(
      decideEgress({ ...base, recipients: ["known@example.com"] }).permitted.map((e) => e.address),
      ["known@example.com"],
    );
  });

  it("E1: permits a reply to an existing thread participant", () => {
    const d = decideEgress({
      ...base,
      recipients: ["stranger@example.com"],
      threadPermitted: true,
      threadParticipants: ["stranger@example.com"],
    });
    assert.deepEqual(d.permitted.map((e) => e.address), ["stranger@example.com"]);
    assert.deepEqual(d.reasons, ["thread_originated_by_agent"]);
  });

  it("thread permission does not let a reply-all add new recipients", () => {
    // Greptile P1: otherwise a permitted thread becomes a general send capability.
    const d = decideEgress({
      ...base,
      recipients: ["stranger@example.com", "outsider@example.com"],
      threadPermitted: true,
      threadParticipants: ["stranger@example.com"],
    });
    assert.deepEqual(d.permitted.map((e) => e.address), ["stranger@example.com"]);
    assert.deepEqual(d.denied, [
      { address: "outsider@example.com", reason: "recipient_not_permitted" },
    ]);
  });

  it("thread permission with no recorded participants grants nothing", () => {
    const d = decideEgress({
      ...base,
      recipients: ["stranger@example.com"],
      threadPermitted: true,
    });
    assert.deepEqual(d.permitted, []);
  });

  it("does not credit the thread grant when no thread participant was admitted", () => {
    // Codex finding on #83: the basis was read off the input flags, so any non-empty send
    // with threadPermitted set was logged as thread authority it never used.
    const d = decideEgress({
      ...base,
      recipients: ["omar@shahine.com", "known@example.com"],
      threadPermitted: true,
      threadParticipants: ["someone-else@example.com"],
    });
    assert.deepEqual(d.reasons.sort(), ["operator_recipient", "recipient_allowlisted"]);
    assert.equal(d.reasons.includes("thread_originated_by_agent"), false);
  });

  it("reports each recipient's own basis, not one basis for the send", () => {
    const d = decideEgress({
      ...base,
      recipients: ["omar@shahine.com", "known@example.com"],
    });
    assert.deepEqual(d.permitted, [
      { address: "omar@shahine.com", reason: "operator_recipient" },
      { address: "known@example.com", reason: "recipient_allowlisted" },
    ]);
  });

  it("E8: narrows reply-all instead of leaking to unknown recipients", () => {
    const d = decideEgress({
      ...base,
      recipients: ["omar@shahine.com", "known@example.com", "stranger@example.com"],
    });
    assert.deepEqual(d.permitted.map((e) => e.address), ["omar@shahine.com", "known@example.com"]);
    assert.deepEqual(d.denied, [
      { address: "stranger@example.com", reason: "recipient_not_permitted" },
    ]);
  });

  it("E10: never sends to itself, even inside a permitted thread", () => {
    const d = decideEgress({
      ...base,
      recipients: ["lobster@example.com"],
      threadPermitted: true,
      threadParticipants: ["lobster@example.com"],
    });
    assert.deepEqual(d.permitted, []);
    assert.equal(d.denied[0]?.reason, "self_addressed");
  });

  it("inbound trust grants nothing outbound", () => {
    // An address can be fully verified inbound and still not be a permitted recipient.
    const d = decideEgress({ ...base, recipients: ["verified-inbound@example.com"] });
    assert.deepEqual(d.permitted, []);
  });

  it("matches recipients case-insensitively", () => {
    assert.deepEqual(
      decideEgress({ ...base, recipients: ["Known@Example.COM"] }).permitted.map((e) => e.address),
      ["Known@Example.COM"],
    );
  });
});
