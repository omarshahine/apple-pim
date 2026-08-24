import { describe, expect, it } from "vitest";
import {
  buildCalendarCreateArgs,
  buildCalendarDeleteArgs,
  buildCalendarUpdateArgs,
  buildContactCreateArgs,
  buildContactUpdateArgs,
  buildReminderCreateArgs,
  buildReminderUpdateArgs,
} from "../../lib/tool-args.js";

describe("buildCalendarDeleteArgs", () => {
  it("uses safe single-occurrence delete by default", () => {
    expect(buildCalendarDeleteArgs({ id: "evt_123" })).toEqual([
      "delete",
      "--id",
      "evt_123",
    ]);
  });

  it("adds future-events flag when requested", () => {
    expect(
      buildCalendarDeleteArgs({ id: "evt_123", futureEvents: true })
    ).toEqual(["delete", "--id", "evt_123", "--future-events"]);
  });
});

describe("buildCalendarCreateArgs", () => {
  it("maps recurrence and url args for calendar create", () => {
    const args = buildCalendarCreateArgs(
      {
        title: "Team sync",
        start: "2026-02-18 10:00",
        url: "https://example.com",
        recurrence: { frequency: "weekly", daysOfTheWeek: ["monday"] },
      },
      "Work"
    );
    expect(args).toEqual([
      "create",
      "--title",
      "Team sync",
      "--start",
      "2026-02-18 10:00",
      "--calendar",
      "Work",
      "--url",
      "https://example.com",
      "--recurrence",
      JSON.stringify({ frequency: "weekly", daysOfTheWeek: ["monday"] }),
    ]);
  });

  it("passes attendees as JSON-stringified --attendees flag", () => {
    const attendees = [
      { email: "alice@example.com", name: "Alice", role: "required" },
      { email: "bob@example.com" },
    ];
    const args = buildCalendarCreateArgs(
      { title: "Meeting", start: "2026-03-01 14:00", attendees },
      "Work"
    );
    expect(args).toContain("--attendees");
    const attIndex = args.indexOf("--attendees");
    expect(JSON.parse(args[attIndex + 1])).toEqual(attendees);
  });

  it("omits --attendees when not provided", () => {
    const args = buildCalendarCreateArgs(
      { title: "Solo", start: "2026-03-01 14:00" },
      "Work"
    );
    expect(args).not.toContain("--attendees");
  });

  it("converts negative alarm values to positive", () => {
    const args = buildCalendarCreateArgs(
      { title: "Meeting", start: "2026-03-01 14:00", alarm: [-60, -720] },
      "Work"
    );
    expect(args).toContain("--alarm");
    const idx1 = args.indexOf("--alarm");
    expect(args[idx1 + 1]).toBe("60");
    const idx2 = args.indexOf("--alarm", idx1 + 1);
    expect(args[idx2 + 1]).toBe("720");
  });

  it("drops non-numeric alarm values", () => {
    const args = buildCalendarCreateArgs(
      { title: "Meeting", start: "2026-03-01 14:00", alarm: ["abc", NaN] },
      "Work"
    );
    expect(args).not.toContain("--alarm");
  });
});

describe("buildCalendarUpdateArgs", () => {
  it("maps futureEvents and recurrence args for calendar update", () => {
    const args = buildCalendarUpdateArgs({
      id: "evt_1",
      recurrence: { frequency: "monthly", daysOfTheMonth: [1, 15] },
      futureEvents: true,
    });
    expect(args).toEqual([
      "update",
      "--id",
      "evt_1",
      "--recurrence",
      JSON.stringify({ frequency: "monthly", daysOfTheMonth: [1, 15] }),
      "--future-events",
    ]);
  });

  it("passes attendees as JSON-stringified --attendees flag on update", () => {
    const attendees = [{ email: "carol@example.com", role: "chair" }];
    const args = buildCalendarUpdateArgs({ id: "evt_2", attendees });
    expect(args).toContain("--attendees");
    const attIndex = args.indexOf("--attendees");
    expect(JSON.parse(args[attIndex + 1])).toEqual(attendees);
  });
});

describe("buildReminderCreateArgs", () => {
  it("maps recurrence args for reminder create", () => {
    const args = buildReminderCreateArgs(
      {
        title: "Pay rent",
        recurrence: { frequency: "monthly", interval: 1 },
      },
      "Reminders"
    );
    expect(args).toEqual([
      "create",
      "--title",
      "Pay rent",
      "--list",
      "Reminders",
      "--recurrence",
      JSON.stringify({ frequency: "monthly", interval: 1 }),
    ]);
  });
});

describe("buildReminderUpdateArgs", () => {
  it("maps recurrence args for reminder update", () => {
    const args = buildReminderUpdateArgs({
      id: "rem_1",
      recurrence: { frequency: "weekly", daysOfTheWeek: ["friday"] },
    });
    expect(args).toEqual([
      "update",
      "--id",
      "rem_1",
      "--recurrence",
      JSON.stringify({ frequency: "weekly", daysOfTheWeek: ["friday"] }),
    ]);
  });
});

describe("buildContactCreateArgs", () => {
  it("omits empty rich arrays to prevent accidental clearing", () => {
    const args = buildContactCreateArgs({
      name: "Ada Lovelace",
      emails: [],
      phones: [],
      addresses: [],
      notes: "Test",
    });
    expect(args).toEqual(["create", "--name", "Ada Lovelace", "--notes", "Test"]);
  });

  it("passes --container when container is specified", () => {
    const args = buildContactCreateArgs({
      name: "Jane Doe",
      container: "iCloud",
      email: "jane@example.com",
    });
    expect(args).toContain("--container");
    const idx = args.indexOf("--container");
    expect(args[idx + 1]).toBe("iCloud");
  });

  it("omits --container when not specified", () => {
    const args = buildContactCreateArgs({
      name: "Jane Doe",
    });
    expect(args).not.toContain("--container");
  });

  it("maps non-empty rich arrays as JSON", () => {
    const args = buildContactCreateArgs({
      firstName: "Ada",
      emails: [{ label: "work", value: "ada@example.com" }],
      relations: [{ label: "assistant", name: "Charles" }],
    });
    expect(args).toEqual([
      "create",
      "--first-name",
      "Ada",
      "--emails",
      JSON.stringify([{ label: "work", value: "ada@example.com" }]),
      "--relations",
      JSON.stringify([{ label: "assistant", name: "Charles" }]),
    ]);
  });
});

describe("buildContactUpdateArgs", () => {
  it("includes id and omits empty rich arrays", () => {
    const args = buildContactUpdateArgs({
      id: "contact_1",
      emails: [],
      phones: [],
      firstName: "Grace",
    });
    expect(args).toEqual(["update", "--id", "contact_1", "--first-name", "Grace"]);
  });
});

describe("reminder url mirroring opt-out", () => {
  // EKReminder.url is invisible in Apple Reminders, so the CLI mirrors it into the notes.
  // A caller storing a machine-only link has to be able to reach the opt-out.
  it("mirrors by default on create", () => {
    const args = buildReminderCreateArgs({ title: "t", url: "https://example.com/x" });
    expect(args).toContain("--url");
    expect(args).not.toContain("--no-url-in-notes");
  });

  it("passes the opt-out on create when urlInNotes is false", () => {
    const args = buildReminderCreateArgs({
      title: "t", url: "https://example.com/x", urlInNotes: false,
    });
    expect(args).toContain("--no-url-in-notes");
  });

  it("passes the opt-out on update, including when clearing the url", () => {
    expect(
      buildReminderUpdateArgs({ id: "1", url: "https://example.com/x", urlInNotes: false })
    ).toContain("--no-url-in-notes");
    expect(
      buildReminderUpdateArgs({ id: "1", url: "", urlInNotes: false })
    ).toContain("--no-url-in-notes");
  });

  it("does not pass the opt-out when no url is supplied", () => {
    expect(buildReminderCreateArgs({ title: "t", urlInNotes: false }))
      .not.toContain("--no-url-in-notes");
    expect(buildReminderUpdateArgs({ id: "1", urlInNotes: false }))
      .not.toContain("--no-url-in-notes");
  });
});
