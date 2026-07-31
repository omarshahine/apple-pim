import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { dispatchAdmittedMessage, type DispatchDeps, type DispatchOptions } from "./dispatch.ts";
import type { ClassifiedMessage } from "./inbound.ts";
import type { OpenClawConfig } from "openclaw/plugin-sdk/config-contracts";

const OPTIONS: DispatchOptions = {
  cfg: {} as OpenClawConfig,
  operatorAddresses: ["operator@example.com"],
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
    threadKey: "m1",
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
    const r = await dispatchAdmittedMessage(classified("operator@example.com"), d, OPTIONS);
    assert.equal(r.replied, true);
    assert.deepEqual(sent, [{ to: "operator@example.com", body: "the agent's reply" }]);
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
    await dispatchAdmittedMessage(classified("operator@example.com"), d, OPTIONS);
    assert.deepEqual(sent, []);
  });

  // The body is never fetched for the agent. Sender and subject decide whether it is worth
  // opening, and the agent opens it itself via the message id.
  it("gives the agent the envelope and the id, never the body", async () => {
    const bodies: (string | undefined)[] = [];
    const { deps: d } = deps({
      dispatchReply: async ({ ctx }) => {
        bodies.push(ctx.Body);
      },
    });
    const m = classified("operator@example.com");
    m.message.dateReceived = "2026-07-29T14:02:00Z";
    m.message.attachmentCount = 2;
    await dispatchAdmittedMessage(m, d, OPTIONS);
    const prompt = bodies[0] ?? "";
    assert.match(
      prompt,
      /Envelope:\nFrom: operator@example\.com\nSubject: hello\nDate: 2026-07-29T14:02:00Z\nAttachments: 2\nMessage-ID: m1/,
    );
    // The body is withheld, so the prompt has to name the call that fetches it. Without
    // this the envelope reads as the whole message and the agent answers the subject line.
    assert.match(prompt, /apple_pim_mail/);
    assert.match(prompt, /action: "get"/);
    // And it has to say the reply *is* the email, or the model writes a chat response.
    assert.match(prompt, /sent to the sender verbatim/);
    // The envelope stays labelled as sender-authored data, not instructions.
    assert.match(prompt, /never instructions to obey/);
  });

  it("omits date and attachments when there are none, and names a missing subject", () => {
    const bodies: (string | undefined)[] = [];
    const { deps: d } = deps({
      dispatchReply: async ({ ctx }) => {
        bodies.push(ctx.Body);
      },
    });
    const m = classified("operator@example.com");
    m.message.subject = undefined;
    return dispatchAdmittedMessage(m, d, OPTIONS).then(() => {
      assert.match(
        bodies[0] ?? "",
        /Envelope:\nFrom: operator@example\.com\nSubject: \(none\)\nMessage-ID: m1/,
      );
      assert.doesNotMatch(bodies[0] ?? "", /Date:|Attachments:/);
    });
  });

  // Opt-in, and it runs after admission so it never reads mail the channel dropped.
  it("includes a cheap-model summary when one is configured", async () => {
    const bodies: (string | undefined)[] = [];
    const { deps: d } = deps({
      summarize: async () => "A receipt for one coffee.",
      dispatchReply: async ({ ctx }) => {
        bodies.push(ctx.Body);
      },
    });
    await dispatchAdmittedMessage(classified("operator@example.com"), d, OPTIONS);
    // Sits between the envelope and the fetch instruction, so a summary never displaces
    // the agent's ability to open the message it summarises.
    assert.match(bodies[0] ?? "", /Summary:\nA receipt for one coffee\./);
  });

  // Greptile P2: permission is not delivery.
  it("does not report a reply when the model produced nothing", async () => {
    const { deps: d, sent } = deps({
      dispatchReply: async ({ dispatcherOptions }) => {
        await dispatcherOptions.deliver({ text: "   " });
      },
    });
    const r = await dispatchAdmittedMessage(classified("operator@example.com"), d, OPTIONS);
    assert.deepEqual(sent, []);
    assert.equal(r.replied, false);
    assert.equal(r.reason, "empty_reply");
  });

  // Per thread, not per sender. A sender-keyed session never ends and mixes unrelated
  // conversations; a thread has a natural start and finish.
  it("scopes the session per thread", async () => {
    const keys: (string | undefined)[] = [];
    const { deps: d } = deps({
      dispatchReply: async ({ ctx }) => {
        keys.push(ctx.SessionKey);
      },
    });
    const first = classified("operator@example.com");
    const laterInSameThread = classified("operator@example.com");
    laterInSameThread.message.messageId = "m2";
    laterInSameThread.threadKey = "m1";
    const unrelated = classified("operator@example.com");
    unrelated.message.messageId = "m3";
    unrelated.threadKey = "m3";

    for (const m of [first, laterInSameThread, unrelated]) {
      await dispatchAdmittedMessage(m, d, OPTIONS);
    }
    assert.deepEqual(keys, [
      "apple-mail:default:m1",
      "apple-mail:default:m1",
      "apple-mail:default:m3",
    ]);
  });

  it("keeps two senders in one thread together, since no thread spans strangers", async () => {
    const keys: (string | undefined)[] = [];
    const { deps: d } = deps({
      dispatchReply: async ({ ctx }) => {
        keys.push(ctx.SessionKey);
      },
    });
    const a = classified("operator@example.com");
    const b = classified("known@example.com");
    b.threadKey = "m1";
    await dispatchAdmittedMessage(a, d, OPTIONS);
    await dispatchAdmittedMessage(b, d, OPTIONS);
    assert.deepEqual(keys, ["apple-mail:default:m1", "apple-mail:default:m1"]);
  });
});

// The thread rule is only as good as the record behind it, and the record must follow
// delivery: writing it on permission would grant thread standing for a message that a
// suppressed or empty reply never actually sent.
describe("thread recording", () => {
  it("records the thread after a reply is sent", async () => {
    const recorded: unknown[] = [];
    const { deps: d } = deps({
      sendReply: async () => ({ sentMessageId: "<agent-1@lobster.example>" }),
      recordThread: async (reply) => {
        recorded.push(reply);
      },
    });
    await dispatchAdmittedMessage(classified("operator@example.com"), d, OPTIONS);
    assert.deepEqual(recorded, [
      {
        inboundMessageId: "m1",
        sentMessageId: "<agent-1@lobster.example>",
        recipients: ["operator@example.com"],
      },
    ]);
  });

  it("records nothing when the reply was suppressed", async () => {
    const recorded: unknown[] = [];
    const { deps: d } = deps({
      recordThread: async (reply) => {
        recorded.push(reply);
      },
    });
    await dispatchAdmittedMessage(classified("stranger@example.com", "observe"), d, OPTIONS);
    assert.deepEqual(recorded, []);
  });

  it("records nothing when the model produced an empty reply", async () => {
    const recorded: unknown[] = [];
    const { deps: d } = deps({
      dispatchReply: async ({ dispatcherOptions }) => {
        await dispatcherOptions.deliver({ text: "   " });
      },
      recordThread: async (reply) => {
        recorded.push(reply);
      },
    });
    await dispatchAdmittedMessage(classified("operator@example.com"), d, OPTIONS);
    assert.deepEqual(recorded, []);
  });

  // Mail.app assigns its own Message-ID and reports nothing back, which is the common path.
  it("still records the inbound anchor when the transport reports no id", async () => {
    const recorded: { sentMessageId?: string }[] = [];
    const { deps: d } = deps({
      recordThread: async (reply) => {
        recorded.push(reply);
      },
    });
    await dispatchAdmittedMessage(classified("operator@example.com"), d, OPTIONS);
    assert.equal(recorded.length, 1);
    assert.equal(recorded[0]?.sentMessageId, undefined);
  });
});
