import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import {
  classifyMessage,
  selectNewMessages,
  senderAddress,
  type InboundDeps,
  type MailboxMessage,
} from "./inbound.ts";
import type { MailAuthCheckResult } from "../mail-auth/strength.ts";

function msg(overrides: Partial<MailboxMessage> = {}): MailboxMessage {
  return {
    messageId: "m1@example.com",
    sender: "Omar Shahine <omar@shahine.com>",
    dateReceived: "2026-07-28T10:00:00.000Z",
    ...overrides,
  };
}

const VERIFIED_AUTH: MailAuthCheckResult = {
  verdict: "verified",
  sender: "omar@shahine.com",
  checks: {
    dkim: { result: "pass", signingDomain: "shahine.com", match: true },
    spf: { result: "pass", mailFrom: "omar@shahine.com", aligned: true, match: true },
  },
};

function deps(overrides: Partial<InboundDeps> = {}): InboundDeps {
  return {
    listMessages: async () => [],
    authCheck: async () => VERIFIED_AUTH,
    ...overrides,
  };
}

describe("senderAddress", () => {
  it("extracts from a display-name form", () => {
    assert.equal(senderAddress("Omar Shahine <Omar@Shahine.com>"), "omar@shahine.com");
  });
  it("passes a bare address through", () => {
    assert.equal(senderAddress("  omar@shahine.com "), "omar@shahine.com");
  });
});

describe("selectNewMessages", () => {
  it("returns everything on a cold cursor", () => {
    const r = selectNewMessages([msg({ messageId: "a" }), msg({ messageId: "b" })], {});
    assert.deepEqual(r.fresh.map((m) => m.messageId), ["a", "b"]);
  });

  it("skips messages already seen at the same watermark", () => {
    const first = selectNewMessages([msg({ messageId: "a" })], {});
    const second = selectNewMessages([msg({ messageId: "a" })], first.cursor);
    assert.deepEqual(second.fresh, []);
  });

  // Two messages can share a timestamp. A strictly-after cursor would lose one forever.
  it("does not lose a second message sharing the watermark timestamp", () => {
    const first = selectNewMessages([msg({ messageId: "a" })], {});
    const second = selectNewMessages(
      [msg({ messageId: "a" }), msg({ messageId: "b" })],
      first.cursor,
    );
    assert.deepEqual(second.fresh.map((m) => m.messageId), ["b"]);
  });

  it("does not replay when a poll returns nothing new", () => {
    const first = selectNewMessages([msg({ messageId: "a" })], {});
    const empty = selectNewMessages([], first.cursor);
    const third = selectNewMessages([msg({ messageId: "a" })], empty.cursor);
    assert.deepEqual(third.fresh, []);
  });

  it("advances past older messages once the watermark moves", () => {
    const first = selectNewMessages([msg({ messageId: "a" })], {});
    const newer = msg({ messageId: "b", dateReceived: "2026-07-28T11:00:00.000Z" });
    const second = selectNewMessages([newer, msg({ messageId: "a" })], first.cursor);
    assert.deepEqual(second.fresh.map((m) => m.messageId), ["b"]);
  });

  it("skips junk without spending an auth check on it", () => {
    const r = selectNewMessages([msg({ messageId: "j", isJunk: true })], {});
    assert.deepEqual(r.fresh, []);
  });

  it("returns an undated message once, then never again", () => {
    // The first assertion alone hid a replay bug: undated ids were never recorded, so the
    // message came back fresh on every poll forever.
    const undated = msg({ messageId: "u", dateReceived: undefined });
    const first = selectNewMessages([undated], {});
    assert.deepEqual(first.fresh.map((m) => m.messageId), ["u"]);
    const second = selectNewMessages([undated], first.cursor);
    assert.deepEqual(second.fresh, []);
  });

  it("keeps undated dedupe working alongside dated messages", () => {
    const undated = msg({ messageId: "u", dateReceived: undefined });
    const first = selectNewMessages([msg({ messageId: "a" }), undated], {});
    assert.deepEqual(first.fresh.map((m) => m.messageId).sort(), ["a", "u"]);
    const second = selectNewMessages([msg({ messageId: "a" }), undated], first.cursor);
    assert.deepEqual(second.fresh, []);
  });
});

describe("classifyMessage", () => {
  it("dispatches an authenticated allowlisted sender", async () => {
    const r = await classifyMessage(msg(), deps(), {
      allowlisted: true,
      minIdentifierAuthentication: "verified",
      selfAddressed: false,
    });
    assert.equal(r.decision.admission, "dispatch");
    assert.equal(r.address, "omar@shahine.com");
  });

  it("observes an authenticated stranger", async () => {
    const stranger: MailAuthCheckResult = {
      verdict: "untrusted",
      sender: "noreply@email.apple.com",
      checks: { dkim: { result: "pass", signingDomain: "email.apple.com", match: false } },
    };
    const r = await classifyMessage(
      msg({ sender: "Apple <noreply@email.apple.com>" }),
      deps({ authCheck: async () => stranger }),
      { allowlisted: false, minIdentifierAuthentication: "verified", selfAddressed: false },
    );
    assert.equal(r.decision.admission, "observe");
  });

  it("drops a spoofed sender whose provenance never held", async () => {
    const forged: MailAuthCheckResult = { verdict: "unknown", sender: "omar@shahine.com" };
    const r = await classifyMessage(msg(), deps({ authCheck: async () => forged }), {
      allowlisted: true,
      minIdentifierAuthentication: "verified",
      selfAddressed: false,
    });
    assert.equal(r.decision.admission, "drop");
    assert.equal(r.decision.reason, "identifier_authentication_too_weak");
  });

  it("does not read thread headers when the agent has sent nothing", async () => {
    let called = false;
    await classifyMessage(
      msg(),
      deps({
        readThreadHeaders: async () => {
          called = true;
          return {};
        },
      }),
      { allowlisted: true, minIdentifierAuthentication: "verified", selfAddressed: false },
    );
    assert.equal(called, false);
  });

  it("admits a thread reply from an addressed participant", async () => {
    const r = await classifyMessage(
      msg({ sender: "friend@example.com" }),
      deps({
        authCheck: async () => ({ ...VERIFIED_AUTH, sender: "friend@example.com" }),
        readThreadHeaders: async () => ({ inReplyTo: "<agent-1@lobster.local>" }),
      }),
      {
        allowlisted: false,
        minIdentifierAuthentication: "verified",
        selfAddressed: false,
        threadRecords: [
          {
            sentMessageIds: ["<agent-1@lobster.local>"],
            addressedRecipients: ["friend@example.com"],
          },
        ],
      },
    );
    assert.equal(r.decision.admission, "dispatch");
    assert.equal(r.decision.reason, "thread_originated_by_agent");
  });

  it("ignores a forged thread claim from a non-participant", async () => {
    const r = await classifyMessage(
      msg({ sender: "attacker@evil.example" }),
      deps({
        authCheck: async () => ({ ...VERIFIED_AUTH, sender: "attacker@evil.example" }),
        readThreadHeaders: async () => ({ inReplyTo: "<agent-1@lobster.local>" }),
      }),
      {
        allowlisted: false,
        minIdentifierAuthentication: "verified",
        selfAddressed: false,
        threadRecords: [
          {
            sentMessageIds: ["<agent-1@lobster.local>"],
            addressedRecipients: ["friend@example.com"],
          },
        ],
      },
    );
    // Falls through to ordinary admission: the claim buys nothing.
    assert.notEqual(r.decision.reason, "thread_originated_by_agent");
  });
});
