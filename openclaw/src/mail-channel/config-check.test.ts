import { describe, it } from "node:test";
import { strict as assert } from "node:assert";
import { checkChannelConfig, type ConfigCheckInput } from "./config-check.ts";

function input(overrides: Partial<ConfigCheckInput> = {}): ConfigCheckInput {
  return {
    allowFrom: ["omar@shahine.com"],
    selfAddresses: ["lobster@example.com"],
    minIdentifierAuthentication: "verified",
    trustedSendersPath: "~/.config/lobster/trusted-senders.json",
    trustedSenders: [
      { name: "Omar", emails: ["omar@shahine.com"], expectedDkimDomains: ["shahine.com"] },
    ],
    trustedAuthservIds: { "*": ["mx.icloud.com"] },
    ...overrides,
  };
}

const codes = (i: ConfigCheckInput) => checkChannelConfig(i).map((f) => f.code);

describe("checkChannelConfig", () => {
  it("says nothing when both files agree", () => {
    assert.deepEqual(checkChannelConfig(input()), []);
  });

  it("reports an empty selfAddresses, because the loop guard cannot fire without it", () => {
    assert.ok(codes(input({ selfAddresses: [] })).includes("loop_guard_disabled"));
  });

  // The whole reason this module exists: the strict posture makes a missing enrollment
  // change behavior, and nothing else in the system says so.
  it("reports an allowFrom entry with no enrollment behind it", () => {
    const found = checkChannelConfig(input({ allowFrom: ["omar@shahine.com", "lora@shahine.com"] }));
    assert.deepEqual(
      found.map((f) => f.code),
      ["allowlisted_not_enrolled"],
    );
    assert.match(found[0]!.message, /lora@shahine\.com/);
    assert.match(found[0]!.message, /readable\s+but never actioned/);
  });

  it("reports an enrollment that names no signers, which can never verify", () => {
    const found = codes(
      input({
        allowFrom: [],
        trustedSenders: [{ name: "Omar", emails: ["omar@shahine.com"], expectedDkimDomains: [] }],
      }),
    );
    assert.deepEqual(found, ["enrolled_without_expected_signers"]);
  });

  it("treats an enrollment with only blank signers as naming none", () => {
    const found = codes(
      input({
        trustedSenders: [
          { name: "Omar", emails: ["omar@shahine.com"], expectedDkimDomains: ["  "] },
        ],
      }),
    );
    assert.ok(found.includes("enrolled_without_expected_signers"));
    // ...and the address is therefore still uncovered.
    assert.ok(found.includes("allowlisted_not_enrolled"));
  });

  it("matches allowFrom against enrollment case-insensitively", () => {
    assert.deepEqual(checkChannelConfig(input({ allowFrom: ["Omar@Shahine.COM"] })), []);
  });

  it("reports a missing authserv-id pin, which drops everything", () => {
    assert.ok(codes(input({ trustedAuthservIds: {} })).includes("no_trusted_authserv_id"));
    assert.ok(codes(input({ trustedAuthservIds: undefined })).includes("no_trusted_authserv_id"));
  });

  // mail-cli keys the set off the message's own account, so any populated key counts.
  // Warning on a name mismatch here would fire on working installs: real files key by
  // Mail.app display name *and* by account UUID, and startup cannot know which will hit.
  it("accepts any populated authserv-id key, wildcard or not", () => {
    const maps: Record<string, readonly string[]>[] = [
      { "*": ["mx.icloud.com"] },
      { iCloud: ["mx.icloud.com"] },
      { "168231BA-20A5-4B91-B54D-8D9906C76D25": ["mx.icloud.com"] },
      { Fastmail: ["mx.fastmail.com"] },
    ];
    for (const map of maps) {
      assert.deepEqual(checkChannelConfig(input({ trustedAuthservIds: map })), [], JSON.stringify(map));
    }
  });

  it("treats a map of only blank ids as unconfigured", () => {
    assert.ok(codes(input({ trustedAuthservIds: { iCloud: ["  "] } })).includes("no_trusted_authserv_id"));
  });

  // An unreadable file means nothing authenticates at all, which subsumes every enrollment
  // finding below it. Reporting one line beats reporting one per allowlist entry.
  it("stops at an unreadable trusted-senders file", () => {
    assert.deepEqual(codes(input({ trustedSenders: undefined, allowFrom: ["a@b.com", "c@d.com"] })), [
      "trusted_senders_unreadable",
    ]);
  });

  // At the default minimum an authenticated domain is enough for an allowlisted sender, so
  // the enrollment gap changes nothing and reporting it would be noise.
  it("stays quiet about enrollment gaps at the default minimum", () => {
    const found = codes(
      input({ minIdentifierAuthentication: "asserted", allowFrom: ["nobody@example.com"] }),
    );
    assert.deepEqual(found, []);
  });

  it("still reports the loop guard and authserv-id pin at the default minimum", () => {
    const found = codes(
      input({ minIdentifierAuthentication: "asserted", selfAddresses: [], trustedAuthservIds: {} }),
    );
    assert.deepEqual(found, ["loop_guard_disabled", "no_trusted_authserv_id"]);
  });
});
