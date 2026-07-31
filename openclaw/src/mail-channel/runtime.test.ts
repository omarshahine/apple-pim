// Covers the reply subject the SMTP sender composes. The JXA path never needed this: it
// asked Mail.app to build the draft, and Mail supplied the subject. Composing the message
// ourselves means owning that too.
import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { replySubject } from "./runtime.ts";

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
