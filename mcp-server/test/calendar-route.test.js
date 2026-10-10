import { describe, expect, it } from "vitest";
import { canReadCalendarStore } from "../../lib/cli-runner.js";

// calendar-cli's auth-status reports two independent things: `authorization` is EventKit
// access (swift/Sources/CalendarCLI/CalendarCLI.swift AuthStatus), and
// `calendarStore.readable` is whether this process can read the local Calendar store that
// supplies subscribed calendars' availability. Only a process with both can serve that read.
describe("canReadCalendarStore", () => {
  it.each(["authorized", "fullAccess"])("is true when %s and the store is readable", (authorization) => {
    expect(canReadCalendarStore({ authorization, calendarStore: { readable: true } })).toBe(true);
  });

  it("is false when Calendar access is granted but the store is unreadable", () => {
    expect(
      canReadCalendarStore({ authorization: "authorized", calendarStore: { readable: false } }),
    ).toBe(false);
  });

  it("is false for a calendar-cli that reports no store", () => {
    // An older binary omits calendarStore. Like a mail-cli without envelopeIndex
    // (mailRouteFromAuthStatus), missing means not readable.
    expect(canReadCalendarStore({ authorization: "authorized" })).toBe(false);
  });

  it.each(["notDetermined", "writeOnly", "denied", "restricted", "unknown"])("is false when %s", (authorization) => {
    expect(canReadCalendarStore({ authorization, calendarStore: { readable: true } })).toBe(false);
  });

  it("is false for unknown shapes rather than failing open", () => {
    for (const status of [
      undefined,
      {},
      { calendarStore: { readable: true } },
      { authorization: "authorized", calendarStore: { readable: "yes" } },
      { authorization: "authorized", calendarStore: {} },
      { authorization: "authorized", calendarStore: null },
    ]) {
      expect(canReadCalendarStore(status)).toBe(false);
    }
  });
});
