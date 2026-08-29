// Covers the reply subject the SMTP sender composes. The JXA path never needed this: it
// asked Mail.app to build the draft, and Mail supplied the subject. Composing the message
// ourselves means owning that too.
import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { replySubject, replyTransportArgs } from "./runtime.ts";

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
