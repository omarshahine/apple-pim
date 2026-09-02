// Covers the reply subject the SMTP sender composes. The JXA path never needed this: it
// asked Mail.app to build the draft, and Mail supplied the subject. Composing the message
// ourselves means owning that too.
import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import {
  composeReplyBody,
  formatQuoteAttribution,
  MAX_QUOTED_CHARS,
  quoteText,
  replySubject,
  replyTransportArgs,
} from "./runtime.ts";

describe("replySubject", () => {
  it("prefixes a plain subject", () => {
    assert.equal(replySubject("Testing new mail plug-in"), "Re: Testing new mail plug-in");
  });

  it("does not stack prefixes on an existing reply", () => {
    // Threads bounce back and forth; re-prefixing every hop produces "Re: Re: Re: ...".
    assert.equal(replySubject("Re: Testing"), "Re: Testing");
    assert.equal(replySubject("RE: Testing"), "RE: Testing");
    assert.equal(replySubject("re: Testing"), "re: Testing");
  });

  it("still answers a message that arrived with no subject", () => {
    // A subject-less message is answerable; refusing to reply because a header was missing
    // would drop a real operator instruction.
    assert.equal(replySubject(undefined), "Re:");
    assert.equal(replySubject("   "), "Re:");
  });

  it("trims surrounding whitespace rather than embedding it", () => {
    assert.equal(replySubject("  Testing  "), "Re: Testing");
  });
});

describe("replyTransportArgs", () => {
  it("uses network-safe submission defaults for iCloud identities", () => {
    assert.deepEqual(replyTransportArgs("agent@icloud.com"), [
      "--tls-mode",
      "starttls",
      "--port",
      "587",
      "--no-imap-append-sent",
    ]);
    assert.deepEqual(replyTransportArgs("agent@ME.com"), replyTransportArgs("agent@icloud.com"));
  });

  it("does not override a custom SMTP transport", () => {
    assert.deepEqual(replyTransportArgs("agent@example.com"), []);
    assert.deepEqual(replyTransportArgs(undefined), []);
  });
});

// Covers the quoted original the SMTP sender appends. The JXA path got this from Mail.app,
// which built the reply draft already quoting the message being answered. Composing the
// MIME message ourselves means owning the quote too, and until this existed every reply
// the channel sent arrived as a bare paragraph with no sign of what it was answering.
describe("formatQuoteAttribution", () => {
  const original = {
    sender: "Omar Shahine <omar@shahine.com>",
    date: "2026-09-02T01:04:17.000Z",
  };

  it("matches the attribution line Mail.app writes", () => {
    assert.equal(
      formatQuoteAttribution(original, "America/Los_Angeles"),
      "On Sep 1, 2026, at 6:04 PM, Omar Shahine <omar@shahine.com> wrote:",
    );
  });

  it("drops the date rather than the whole line when the date is unusable", () => {
    // A quotable body with an unparseable Date header still deserves an attribution; the
    // reader needs to know who wrote the text below far more than when.
    assert.equal(
      formatQuoteAttribution({ sender: original.sender, date: "not a date" }),
      "Omar Shahine <omar@shahine.com> wrote:",
    );
    assert.equal(
      formatQuoteAttribution({ sender: original.sender }),
      "Omar Shahine <omar@shahine.com> wrote:",
    );
  });

  it("has nothing to attribute without a sender", () => {
    assert.equal(formatQuoteAttribution({ date: original.date }), undefined);
    assert.equal(formatQuoteAttribution({ sender: "  " }), undefined);
  });
});

describe("quoteText", () => {
  it("prefixes every line, including the blank ones", () => {
    // A blank line left unprefixed ends the quote block in most clients, so the rest of the
    // original renders as though the agent had written it.
    assert.equal(quoteText("first\n\nsecond"), "> first\n>\n> second");
  });

  it("nests an already-quoted original one level deeper", () => {
    assert.equal(quoteText("mine\n> theirs"), "> mine\n>> theirs");
  });

  it("normalizes CRLF so quoting does not strand carriage returns", () => {
    assert.equal(quoteText("first\r\nsecond"), "> first\n> second");
  });

  it("truncates a pathological original instead of mailing it back whole", () => {
    const quoted = quoteText("x".repeat(MAX_QUOTED_CHARS + 5_000));
    assert.ok(quoted.length < MAX_QUOTED_CHARS + 200);
    assert.ok(quoted.endsWith("\n>\n> [Quoted text truncated]"));
  });
});

describe("composeReplyBody", () => {
  const original = {
    sender: "Omar Shahine <omar@shahine.com>",
    date: "2026-09-02T01:04:17.000Z",
    content: "Are you looking at the family calendar or my personal calendar",
  };

  it("top-posts the reply above the quoted original", () => {
    assert.equal(
      composeReplyBody("Neither.", original, "America/Los_Angeles"),
      [
        "Neither.",
        "",
        "On Sep 1, 2026, at 6:04 PM, Omar Shahine <omar@shahine.com> wrote:",
        "",
        "> Are you looking at the family calendar or my personal calendar",
      ].join("\n"),
    );
  });

  it("sends the reply alone when the original could not be read", () => {
    // Quoting is a courtesy; the answer is the message. A failed fetch must not cost the
    // operator the reply itself.
    assert.equal(composeReplyBody("Neither.", undefined), "Neither.");
    assert.equal(composeReplyBody("Neither.", { ...original, content: "   " }), "Neither.");
  });

  it("quotes without attribution when the sender is unknown", () => {
    assert.equal(
      composeReplyBody("Neither.", { content: "Which calendar?" }),
      "Neither.\n\n> Which calendar?",
    );
  });
});
