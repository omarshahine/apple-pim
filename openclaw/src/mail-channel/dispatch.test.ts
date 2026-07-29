import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { dispatchAdmittedMessage, type DispatchDeps, type DispatchOptions } from "./dispatch.ts";
import type { ClassifiedMessage } from "./inbound.ts";
import type { OpenClawConfig } from "openclaw/plugin-sdk/config-contracts";

const OPTIONS: DispatchOptions = {
  cfg: {} as OpenClawConfig,
  operatorAddresses: ["omar@shahine.com"],
  egressAllowlist: ["known@example.com"],
  selfAddresses: ["lobster@example.com"],
  sessionPrefix: "apple-mail:default",
};

function classified(
  address: string,
  admission: "dispatch" | "observe" = "dispatch",
): ClassifiedMessage {
  return {
    message: { messageId: "m1", sender: address, subject: "hello" },
    address,
    decision: { admission, reason: "allowlisted_and_authenticated" },
  } as ClassifiedMessage;
}

function deps(overrides: Partial<DispatchDeps> = {}) {
  const sent: { to: string; body: string }[] = [];
  const suppressed: { address: string; reason: string }[] = [];
  const base: DispatchDeps = {
    // Immediately produce a reply, so `deliver` is always exercised.
    dispatchReply: async ({ dispatcherOptions }) => {
      await dispatcherOptions.deliver({ text: "the agent's reply" });
    },
    sendReply: async ({ to, body }) => {
      sent.push({ to, body });
    },
    onSuppressed: (params) => suppressed.push(params),
    ...overrides,
  };
  return { deps: base, sent, suppressed };
}

describe("dispatchAdmittedMessage", () => {
  it("replies to the operator", async () => {
    const { deps: d, sent } = deps();
    const r = await dispatchAdmittedMessage(classified("omar@shahine.com"), d, OPTIONS);
    assert.equal(r.replied, true);
    assert.deepEqual(sent, [{ to: "omar@shahine.com", body: "the agent's reply" }]);
  });

  it("replies to an egress-allowlisted correspondent", async () => {
    const { deps: d, sent } = deps();
    const r = await dispatchAdmittedMessage(classified("known@example.com"), d, OPTIONS);
    assert.equal(r.replied, true);
    assert.equal(sent.length, 1);
  });

  // The whole point of graduated admission: readable, not repliable.
  it("runs the agent but suppresses the reply for an observe-only message", async () => {
    const { deps: d, sent, suppressed } = deps();
    let agentRan = false;
    const r = await dispatchAdmittedMessage(
      classified("stranger@example.com", "observe"),
      {
        ...d,
        dispatchReply: async ({ dispatcherOptions }) => {
          agentRan = true;
          await dispatcherOptions.deliver({ text: "the agent's reply" });
        },
      },
      OPTIONS,
    );
    assert.equal(agentRan, true, "the agent should still see the message");
    assert.deepEqual(sent, [], "but nothing may be sent back");
    assert.equal(r.replied, false);
    assert.equal(suppressed[0]?.reason, "observe_only");
  });

  // Admission and egress are separate grants. Being readable is not being writable.
  it("suppresses the reply to a dispatched sender who is not a permitted recipient", async () => {
    const { deps: d, sent, suppressed } = deps();
    const r = await dispatchAdmittedMessage(classified("stranger@example.com"), d, OPTIONS);
    assert.deepEqual(sent, []);
    assert.equal(r.replied, false);
    assert.equal(suppressed[0]?.reason, "recipient_not_permitted");
  });

  it("never replies to itself", async () => {
    const { deps: d, sent } = deps();
    await dispatchAdmittedMessage(classified("lobster@example.com"), d, OPTIONS);
    assert.deepEqual(sent, []);
  });

  it("does not send an empty reply", async () => {
    const { deps: d, sent } = deps({
      dispatchReply: async ({ dispatcherOptions }) => {
        await dispatcherOptions.deliver({ text: "   " });
      },
    });
    await dispatchAdmittedMessage(classified("omar@shahine.com"), d, OPTIONS);
    assert.deepEqual(sent, []);
  });

  // Greptile P1: the agent used to receive only the subject line.
  it("gives the agent the body, not just the subject", async () => {
    const bodies: (string | undefined)[] = [];
    const { deps: d } = deps({
      readBody: async () => "the actual message body",
      dispatchReply: async ({ ctx }) => {
        bodies.push(ctx.Body);
      },
    });
    await dispatchAdmittedMessage(classified("omar@shahine.com"), d, OPTIONS);
    assert.equal(bodies[0], "Subject: hello\n\nthe actual message body");
  });

  it("still dispatches something useful when there is no subject", async () => {
    const bodies: (string | undefined)[] = [];
    const { deps: d } = deps({
      readBody: async () => "body only",
      dispatchReply: async ({ ctx }) => {
        bodies.push(ctx.Body);
      },
    });
    const m = classified("omar@shahine.com");
    m.message.subject = undefined;
    await dispatchAdmittedMessage(m, d, OPTIONS);
    assert.equal(bodies[0], "body only");
  });

  // Greptile P2: permission is not delivery.
  it("does not report a reply when the model produced nothing", async () => {
    const { deps: d, sent } = deps({
      dispatchReply: async ({ dispatcherOptions }) => {
        await dispatcherOptions.deliver({ text: "   " });
      },
    });
    const r = await dispatchAdmittedMessage(classified("omar@shahine.com"), d, OPTIONS);
    assert.deepEqual(sent, []);
    assert.equal(r.replied, false);
    assert.equal(r.reason, "empty_reply");
  });

  it("scopes the session per sender so correspondents cannot read each other", async () => {
    const keys: (string | undefined)[] = [];
    const { deps: d } = deps({
      dispatchReply: async ({ ctx }) => {
        keys.push(ctx.SessionKey);
      },
    });
    await dispatchAdmittedMessage(classified("omar@shahine.com"), d, OPTIONS);
    await dispatchAdmittedMessage(classified("known@example.com"), d, OPTIONS);
    assert.deepEqual(keys, [
      "apple-mail:default:omar@shahine.com",
      "apple-mail:default:known@example.com",
    ]);
  });
});
