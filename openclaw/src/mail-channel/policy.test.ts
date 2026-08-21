import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { decideEgress, decideIngress, type IngressInput } from "./policy.ts";

// The authentication gate itself (minimums, per-message strengths, break-glass) moved into
// the ingress kernel and is proven end to end by scenarios.test.ts through
// `resolveMailIngress`. What remains here is the channel's pure layering over the kernel's
// answer: loop guard, grant attribution, and the observe escalation.
function ingress(overrides: Partial<IngressInput> = {}): IngressInput {
  return {
    kernelAdmitted: true,
    domainVerified: true,
    allowlisted: true,
    selfAddressed: false,
    threadPermitted: false,
    ...overrides,
  };
}

describe("ingress admission", () => {
  it("I1: dispatches a kernel-admitted, allowlisted sender", () => {
    assert.deepEqual(decideIngress(ingress()), {
      admission: "dispatch",
      reason: "allowlisted_and_authenticated",
    });
  });

  it("I2: drops an allowlisted sender the kernel rejected with nothing proven", () => {
    // The operator gets no exception. Making one would invert the whole model.
    assert.deepEqual(decideIngress(ingress({ kernelAdmitted: false, domainVerified: false })), {
      admission: "drop",
      reason: "identifier_authentication_too_weak",
    });
  });

  it("I5: observes an authenticated stranger, never dispatches", () => {
    assert.deepEqual(
      decideIngress(ingress({ kernelAdmitted: false, allowlisted: false, domainVerified: true })),
      { admission: "observe", reason: "authenticated_but_not_allowlisted" },
    );
  });

  it("I4a: an allowlisted sender the kernel rejected still observes on a proven domain", () => {
    // The inversion guard: enrolling someone must never reduce what the channel does
    // with their mail relative to the identical unenrolled sender.
    assert.deepEqual(decideIngress(ingress({ kernelAdmitted: false, domainVerified: true })), {
      admission: "observe",
      reason: "identifier_authentication_too_weak",
    });
  });

  it("I6: drops an unauthenticated stranger", () => {
    assert.deepEqual(
      decideIngress(ingress({ kernelAdmitted: false, allowlisted: false, domainVerified: false })),
      { admission: "drop", reason: "unauthenticated_sender" },
    );
  });

  it("I13: drops self-addressed mail before any grant applies", () => {
    // Loop guard must outrank the kernel admit, which would otherwise dispatch it.
    assert.deepEqual(decideIngress(ingress({ selfAddressed: true, threadPermitted: true })), {
      admission: "drop",
      reason: "self_addressed",
    });
  });

  it("I9: attributes a kernel admit through the injected thread entry to the thread grant", () => {
    assert.deepEqual(decideIngress(ingress({ allowlisted: false, threadPermitted: true })), {
      admission: "dispatch",
      reason: "thread_originated_by_agent",
    });
  });

  it("thread permission waives the allowlist but not authentication", () => {
    // Greptile P1: an attacker who learns a participant's address and an agent
    // Message-ID could otherwise spoof From and inherit the thread grant. The kernel
    // rejecting the injected entry lands as too-weak, not as a dispatch.
    assert.deepEqual(
      decideIngress(
        ingress({
          kernelAdmitted: false,
          allowlisted: false,
          threadPermitted: true,
          domainVerified: false,
        }),
      ),
      { admission: "drop", reason: "identifier_authentication_too_weak" },
    );
  });
});

describe("egress", () => {
  const base = {
    operatorAddresses: ["operator@example.com"],
    egressAllowlist: ["known@example.com"],
    selfAddresses: ["lobster@example.com"],
    threadPermitted: false,
    operatorInstructed: false,
  };

  it("E3: always permits the operator", () => {
    const d = decideEgress({ ...base, recipients: ["operator@example.com"] });
    assert.deepEqual(d.permitted.map((e) => e.address), ["operator@example.com"]);
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
      recipients: ["operator@example.com", "known@example.com"],
      threadPermitted: true,
      threadParticipants: ["someone-else@example.com"],
    });
    assert.deepEqual(d.reasons.sort(), ["operator_recipient", "recipient_allowlisted"]);
    assert.equal(d.reasons.includes("thread_originated_by_agent"), false);
  });

  it("reports each recipient's own basis, not one basis for the send", () => {
    const d = decideEgress({
      ...base,
      recipients: ["operator@example.com", "known@example.com"],
    });
    assert.deepEqual(d.permitted, [
      { address: "operator@example.com", reason: "operator_recipient" },
      { address: "known@example.com", reason: "recipient_allowlisted" },
    ]);
  });

  it("E8: narrows reply-all instead of leaking to unknown recipients", () => {
    const d = decideEgress({
      ...base,
      recipients: ["operator@example.com", "known@example.com", "stranger@example.com"],
    });
    assert.deepEqual(d.permitted.map((e) => e.address), ["operator@example.com", "known@example.com"]);
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
