import { describe, expect, it } from "vitest";
import { mailRouteFromAuthStatus } from "../../lib/cli-runner.js";

// The state table is mail-cli's, not ours: swift/Sources/MailCLI/MailCLI.swift
// emits authorized / notDetermined / denied / unavailable / error for Mail.app
// Automation, and reports Full Disk Access separately as envelopeIndex.readable.
// Mail needs both, so only the both-granted case may skip the helper.
describe("mailRouteFromAuthStatus", () => {
  it("goes direct only when Automation and Full Disk Access are both granted", () => {
    expect(
      mailRouteFromAuthStatus({ authorization: "authorized", envelopeIndex: { readable: true } }),
    ).toEqual({ route: "direct", mayPrompt: false });
  });

  it("uses the helper when Automation is granted but the Envelope Index is unreadable", () => {
    // Reads open ~/Library/Mail directly, so Automation alone is not enough.
    expect(
      mailRouteFromAuthStatus({ authorization: "authorized", envelopeIndex: { readable: false } }),
    ).toEqual({ route: "helper", mayPrompt: false });
  });

  it("uses the helper when Mail.app is not running", () => {
    // "unavailable" is returned before any TCC check, so it carries no
    // permission signal. Treating it as a green light would cache the direct
    // route on a host with no Mail grants at all.
    expect(
      mailRouteFromAuthStatus({
        authorization: "unavailable",
        message: "Mail.app is not running",
        envelopeIndex: { readable: true },
      }),
    ).toEqual({ route: "helper", mayPrompt: false });
  });

  it("flags a prompt only for notDetermined", () => {
    expect(
      mailRouteFromAuthStatus({ authorization: "notDetermined", envelopeIndex: { readable: true } }),
    ).toEqual({ route: "helper", mayPrompt: true });
  });

  it("uses the helper without prompting when Automation is denied", () => {
    expect(
      mailRouteFromAuthStatus({ authorization: "denied", envelopeIndex: { readable: true } }),
    ).toEqual({ route: "helper", mayPrompt: false });
  });

  it("uses the helper for unknown shapes rather than failing open", () => {
    for (const status of [undefined, {}, { authorization: "error" }]) {
      expect(mailRouteFromAuthStatus(status).route).toBe("helper");
    }
  });
});
