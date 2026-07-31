/**
 * The send gate closes the reply/send asymmetry (#98): agent-originated mail runs through the
 * same egress policy as replies. These tests pin the three outcomes and the config reading,
 * so a policy change cannot quietly reopen the gap.
 */

import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import type { OpenClawConfig } from "openclaw/plugin-sdk/config-contracts";
import {
  classifySend,
  collectSendRecipients,
  describeSendApproval,
  evaluateSend,
  resolveSendEgressPolicy,
  type SendEgressPolicy,
} from "./send-approval.ts";

const policy: SendEgressPolicy = {
  operatorAddresses: ["operator@example.com"],
  egressAllowlist: ["known@example.com"],
  selfAddresses: ["agent@example.com"],
};

describe("classifySend", () => {
  it("allows a send to the operator", () => {
    assert.deepEqual(classifySend({ recipients: ["operator@example.com"], policy }), { kind: "allow" });
  });

  it("allows a send to an allowlisted recipient", () => {
    assert.deepEqual(classifySend({ recipients: ["known@example.com"], policy }), { kind: "allow" });
  });

  it("asks for approval for an unlisted recipient", () => {
    assert.deepEqual(classifySend({ recipients: ["stranger@example.com"], policy }), {
      kind: "approve",
      unlisted: ["stranger@example.com"],
    });
  });

  it("asks for approval when any single recipient is unlisted", () => {
    // A mixed send is not silently narrowed to the permitted recipients: the operator approves
    // the send as addressed, or it is denied. Reporting every unlisted address lets them see
    // exactly who would be mailed.
    const result = classifySend({
      recipients: ["operator@example.com", "stranger@example.com", "other@example.com"],
      policy,
    });
    assert.deepEqual(result, { kind: "approve", unlisted: ["stranger@example.com", "other@example.com"] });
  });

  it("hard-blocks a send to the agent's own address, outranking approval", () => {
    // Even alongside an unlisted recipient, the loop guard wins: emailing itself is never an
    // approval question.
    assert.deepEqual(classifySend({ recipients: ["agent@example.com", "stranger@example.com"], policy }), {
      kind: "loop",
      addresses: ["agent@example.com"],
    });
  });

  it("matches recipients regardless of case", () => {
    assert.deepEqual(classifySend({ recipients: ["KNOWN@Example.COM"], policy }), { kind: "allow" });
    assert.deepEqual(classifySend({ recipients: ["Agent@EXAMPLE.com"], policy }), {
      kind: "loop",
      addresses: ["Agent@EXAMPLE.com"],
    });
  });

  it("treats an empty recipient list as allow, leaving validation to the tool handler", () => {
    assert.deepEqual(classifySend({ recipients: [], policy }), { kind: "allow" });
  });

  it("asks for approval for everyone when the allowlist is empty", () => {
    // Deny-by-default: an apple-mail install with no egressAllowlist governs every send.
    const empty: SendEgressPolicy = { operatorAddresses: [], egressAllowlist: [], selfAddresses: [] };
    assert.deepEqual(classifySend({ recipients: ["anyone@example.com"], policy: empty }), {
      kind: "approve",
      unlisted: ["anyone@example.com"],
    });
  });
});

describe("evaluateSend", () => {
  it("collects recipients and delegates to classifySend", () => {
    assert.deepEqual(evaluateSend({ to: "known@example.com", subject: "hi" }, policy), { kind: "allow" });
    assert.deepEqual(evaluateSend({ to: "stranger@example.com", subject: "hi" }, policy), {
      kind: "approve",
      unlisted: ["stranger@example.com"],
    });
  });

  it("skips the gate for a dry-run send, which never delivers mail", () => {
    // withAgentDX returns a preview for any truthy dryRun and never calls the CLI, so an
    // unlisted recipient must not trigger an approval that governs a send that cannot happen.
    assert.deepEqual(evaluateSend({ to: "stranger@example.com", dryRun: true }, policy), { kind: "allow" });
    assert.deepEqual(evaluateSend({ to: "stranger@example.com", dryRun: 1 }, policy), { kind: "allow" });
  });

  it("still gates a real send when dryRun is falsy", () => {
    assert.deepEqual(evaluateSend({ to: "stranger@example.com", dryRun: false }, policy), {
      kind: "approve",
      unlisted: ["stranger@example.com"],
    });
  });
});

describe("collectSendRecipients", () => {
  it("gathers to, cc, and bcc, accepting string or array", () => {
    const params = {
      to: "a@example.com",
      cc: ["b@example.com", "c@example.com"],
      bcc: "d@example.com",
    };
    assert.deepEqual(collectSendRecipients(params), [
      "a@example.com",
      "b@example.com",
      "c@example.com",
      "d@example.com",
    ]);
  });

  it("ignores missing and non-string fields", () => {
    assert.deepEqual(collectSendRecipients({ to: "a@example.com", cc: [42, "b@example.com"], bcc: null }), [
      "a@example.com",
      "b@example.com",
    ]);
  });

  it("returns nothing for a send with no recipients", () => {
    assert.deepEqual(collectSendRecipients({ subject: "x", body: "y" }), []);
  });
});

describe("resolveSendEgressPolicy", () => {
  const asConfig = (channels: Record<string, unknown>): OpenClawConfig => ({ channels }) as OpenClawConfig;

  it("returns undefined when the apple-mail channel is not configured", () => {
    assert.equal(resolveSendEgressPolicy(asConfig({})), undefined);
    assert.equal(resolveSendEgressPolicy({} as OpenClawConfig), undefined);
  });

  const topLevel = () =>
    asConfig({
      "apple-mail": {
        operatorAddresses: ["op@example.com"],
        egressAllowlist: ["ok@example.com"],
        selfAddresses: ["me@example.com"],
      },
    });

  it("reads the top-level channel block for a single-account install", () => {
    assert.deepEqual(resolveSendEgressPolicy(topLevel()), {
      operatorAddresses: ["op@example.com"],
      egressAllowlist: ["ok@example.com"],
      selfAddresses: ["me@example.com"],
    });
  });

  it("uses the top-level policy when `from` is a managed self address", () => {
    assert.deepEqual(resolveSendEgressPolicy(topLevel(), "me@example.com")?.egressAllowlist, ["ok@example.com"]);
  });

  it("fails closed when `from` is not a managed self address, even top-level", () => {
    // The scoping added for multi-account must not be defeatable by the common top-level shape:
    // a send claiming an identity the channel does not own inherits no allowlist.
    const resolved = resolveSendEgressPolicy(topLevel(), "impostor@example.com");
    assert.deepEqual(resolved?.egressAllowlist, []);
    assert.deepEqual(resolved?.operatorAddresses, []);
    assert.deepEqual(resolved?.selfAddresses, ["me@example.com"]);
  });

  const multiAccount = () =>
    asConfig({
      "apple-mail": {
        selfAddresses: ["top@example.com"],
        accounts: {
          work: { egressAllowlist: ["w@example.com"], selfAddresses: ["work-self@example.com"] },
          home: { egressAllowlist: ["h@example.com"], selfAddresses: ["home-self@example.com"], operatorAddresses: ["op@example.com"] },
        },
      },
    });

  it("scopes the allowlist to the account the sender is attributed to", () => {
    // The whole point of scoping: `work`'s allowlist must not carry over to a send from `home`.
    const work = resolveSendEgressPolicy(multiAccount(), "work-self@example.com");
    assert.deepEqual(work?.egressAllowlist, ["w@example.com"]);
    const home = resolveSendEgressPolicy(multiAccount(), "home-self@example.com");
    assert.deepEqual(home?.egressAllowlist, ["h@example.com"]);
    assert.deepEqual(home?.operatorAddresses, ["op@example.com"]);
  });

  it("unions self addresses across every account so any self-send is a loop", () => {
    const resolved = resolveSendEgressPolicy(multiAccount(), "work-self@example.com");
    assert.deepEqual(resolved?.selfAddresses.sort(), [
      "home-self@example.com",
      "top@example.com",
      "work-self@example.com",
    ]);
  });

  it("fails closed to an empty allowlist when a multi-account sender cannot be attributed", () => {
    // Unknown `from`, and no `from` with no default account: nothing may be sent without approval,
    // but the loop guard still holds.
    for (const from of ["stranger@example.com", undefined]) {
      const resolved = resolveSendEgressPolicy(multiAccount(), from);
      assert.deepEqual(resolved?.egressAllowlist, []);
      assert.deepEqual(resolved?.operatorAddresses, []);
      assert.equal(resolved?.selfAddresses.includes("work-self@example.com"), true);
    }
  });

  it("fails closed when a `from` matches more than one account", () => {
    // Both accounts inherit the top-level self address, so `shared@example.com` is ambiguous:
    // it must not silently take whichever account is listed first.
    const cfg = asConfig({
      "apple-mail": {
        selfAddresses: ["shared@example.com"],
        accounts: {
          work: { egressAllowlist: ["w@example.com"] },
          home: { egressAllowlist: ["h@example.com"] },
        },
      },
    });
    const resolved = resolveSendEgressPolicy(cfg, "shared@example.com");
    assert.deepEqual(resolved?.egressAllowlist, []);
  });

  it("attributes to a single named account even when `from` is omitted", () => {
    const resolved = resolveSendEgressPolicy(
      asConfig({
        "apple-mail": {
          accounts: { personal: { egressAllowlist: ["p@example.com"], selfAddresses: ["me@example.com"] } },
        },
      }),
      undefined,
    );
    assert.deepEqual(resolved?.egressAllowlist, ["p@example.com"]);
  });

  it("fails closed when `from` names an identity the sole account does not own", () => {
    const resolved = resolveSendEgressPolicy(
      asConfig({
        "apple-mail": {
          accounts: { personal: { egressAllowlist: ["p@example.com"], selfAddresses: ["me@example.com"] } },
        },
      }),
      "someone-else@example.com",
    );
    assert.deepEqual(resolved?.egressAllowlist, []);
  });

  it("attributes a send with no `from` to the default account", () => {
    const resolved = resolveSendEgressPolicy(
      asConfig({
        "apple-mail": {
          accounts: {
            default: { egressAllowlist: ["d@example.com"], selfAddresses: ["default-self@example.com"] },
            other: { egressAllowlist: ["o@example.com"], selfAddresses: ["other-self@example.com"] },
          },
        },
      }),
      undefined,
    );
    assert.deepEqual(resolved?.egressAllowlist, ["d@example.com"]);
  });

  it("de-duplicates an address that appears in the top-level and the resolved account", () => {
    const resolved = resolveSendEgressPolicy(
      asConfig({
        "apple-mail": {
          egressAllowlist: ["dup@example.com"],
          accounts: { a: { selfAddresses: ["a-self@example.com"] } },
        },
      }),
      "a-self@example.com",
    );
    // `a` has no allowlist of its own, so it inherits the top-level one; no duplication.
    assert.deepEqual(resolved?.egressAllowlist, ["dup@example.com"]);
  });
});

describe("describeSendApproval", () => {
  it("names the recipients and the subject", () => {
    const text = describeSendApproval(["stranger@example.com"], "Lunch?");
    assert.match(text, /stranger@example\.com/);
    assert.match(text, /Lunch\?/);
  });

  it("falls back to a placeholder for an empty subject", () => {
    assert.match(describeSendApproval(["x@example.com"], "   "), /\(no subject\)/);
  });
});
