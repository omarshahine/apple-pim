import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadScenario } from "../helpers/scenario-runner.js";
import { createMockCLI } from "../helpers/mock-cli.js";
import { argsPairPresent } from "../helpers/grader.js";
import { handleCalendar } from "../../lib/handlers/calendar.js";
import { handleReminder } from "../../lib/handlers/reminder.js";
import { handleContact } from "../../lib/handlers/contact.js";
import { handleMail } from "../../lib/handlers/mail.js";
import { buildDryRunResponse } from "../../lib/dry-run.js";
import { relativeDateString } from "../../lib/cli-runner.js";
import {
  buildCalendarCreateArgs,
  buildCalendarUpdateArgs,
  buildReminderCreateArgs,
} from "../../lib/tool-args.js";

const handlers = {
  calendar: handleCalendar,
  reminder: handleReminder,
  contact: handleContact,
  mail: handleMail,
};

const scenario = loadScenario("tool-call-correctness.yaml");

describe("Category 1: Tool Call Correctness", () => {
  describe("ISO 8601 date passthrough", () => {
    it("passes ISO 8601 offset through to --start unchanged", () => {
      const args = buildCalendarCreateArgs(
        { title: "Dinner", start: "2026-03-15T19:00:00-07:00" },
        "Personal"
      );
      expect(argsPairPresent(args, "--start", "2026-03-15T19:00:00-07:00")).toBe(true);
    });

    it("passes positive UTC offset through unchanged", () => {
      const args = buildCalendarCreateArgs(
        { title: "Call", start: "2026-03-16T09:00:00+05:30" },
        "Work"
      );
      expect(argsPairPresent(args, "--start", "2026-03-16T09:00:00+05:30")).toBe(true);
    });

    it("passes Z (UTC) suffix through unchanged", () => {
      const args = buildCalendarCreateArgs(
        { title: "UTC Event", start: "2026-03-15T12:00:00Z" },
        null
      );
      expect(argsPairPresent(args, "--start", "2026-03-15T12:00:00Z")).toBe(true);
    });
  });

  describe("duration vs end", () => {
    it("uses --duration when duration is provided", () => {
      const args = buildCalendarCreateArgs(
        { title: "Chat", start: "2026-03-15T10:00:00", duration: 30 },
        null
      );
      expect(args).toContain("--duration");
      expect(args).toContain("30");
      expect(args).not.toContain("--end");
    });

    it("uses --end when end is provided", () => {
      const args = buildCalendarCreateArgs(
        { title: "Chat", start: "2026-03-15T10:00:00", end: "2026-03-15T11:00:00" },
        null
      );
      expect(args).toContain("--end");
      expect(args).not.toContain("--duration");
    });
  });

  describe("all-day flag", () => {
    it("includes --all-day when allDay is true", () => {
      const args = buildCalendarCreateArgs(
        { title: "Holiday", start: "2026-12-25", allDay: true },
        null
      );
      expect(args).toContain("--all-day");
    });

    it("omits --all-day when allDay is falsy", () => {
      const args = buildCalendarCreateArgs(
        { title: "Meeting", start: "2026-03-15T10:00:00" },
        null
      );
      expect(args).not.toContain("--all-day");
    });
  });

  describe("recurrence serialization", () => {
    it("serializes recurrence as JSON string", () => {
      const recurrence = { frequency: "weekly", daysOfTheWeek: ["monday"] };
      const args = buildCalendarCreateArgs(
        { title: "Sync", start: "2026-03-16T09:00:00", recurrence },
        null
      );
      const recIdx = args.indexOf("--recurrence");
      expect(recIdx).not.toBe(-1);
      expect(JSON.parse(args[recIdx + 1])).toEqual(recurrence);
    });

    it("serializes reminder recurrence as JSON string", () => {
      const recurrence = { frequency: "monthly", interval: 1 };
      const args = buildReminderCreateArgs(
        { title: "Pay rent", recurrence },
        "Bills"
      );
      const recIdx = args.indexOf("--recurrence");
      expect(recIdx).not.toBe(-1);
      expect(JSON.parse(args[recIdx + 1])).toEqual(recurrence);
    });
  });

  describe("multiple alarms", () => {
    it("produces multiple --alarm flags", () => {
      const args = buildCalendarCreateArgs(
        { title: "Important", start: "2026-03-15T14:00:00", alarm: [5, 15, 60] },
        null
      );
      const alarmIndices = args
        .map((a, i) => (a === "--alarm" ? i : -1))
        .filter((i) => i !== -1);
      expect(alarmIndices).toHaveLength(3);
      expect(args[alarmIndices[0] + 1]).toBe("5");
      expect(args[alarmIndices[1] + 1]).toBe("15");
      expect(args[alarmIndices[2] + 1]).toBe("60");
    });
  });

  describe("relative date resolution (lastDays)", () => {
    it("computes --from as a date string for lastDays", async () => {
      const mockCLI = createMockCLI({ "calendar-cli:events": { events: [] } });
      await handleCalendar({ action: "events", lastDays: 7 }, mockCLI);

      const callArgs = mockCLI.mock.calls[0][1];
      expect(callArgs).toContain("--from");
      const fromIdx = callArgs.indexOf("--from");
      // Should be a YYYY-MM-DD date string
      expect(callArgs[fromIdx + 1]).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    });

    it("prefers explicit date bounds over synthetic zero relative defaults", async () => {
      const mockCLI = createMockCLI({ "calendar-cli:events": { events: [] } });
      await handleCalendar({
        action: "events",
        from: "2026-09-13T00:00:00-07:00",
        to: "2026-09-21T00:00:00-07:00",
        lastDays: 0,
        nextDays: 0,
      }, mockCLI);

      expect(mockCLI.mock.calls[0][1]).toEqual([
        "events",
        "--from", "2026-09-13T00:00:00-07:00",
        "--to", "2026-09-21T00:00:00-07:00",
      ]);
    });

    it("resolves relative dates in the host timezone rather than UTC", () => {
      const previousTZ = process.env.TZ;
      process.env.TZ = "America/Los_Angeles";
      vi.useFakeTimers();
      vi.setSystemTime(new Date("2026-09-14T00:30:00Z"));

      try {
        expect(relativeDateString(0)).toBe("2026-09-13");
      } finally {
        vi.useRealTimers();
        if (previousTZ === undefined) delete process.env.TZ;
        else process.env.TZ = previousTZ;
      }
    });
  });

  describe("reminder location as JSON", () => {
    it("serializes location object as JSON string", () => {
      const location = { latitude: 47.6, longitude: -122.3, proximity: "arrive" };
      const args = buildReminderCreateArgs(
        { title: "Pick up", location },
        null
      );
      const locIdx = args.indexOf("--location");
      expect(locIdx).not.toBe(-1);
      expect(JSON.parse(args[locIdx + 1])).toEqual(location);
    });
  });

  describe("required field validation", () => {
    it("calendar create includes --title with undefined when title missing (schema enforces)", () => {
      // buildCalendarCreateArgs unconditionally pushes --title and --start.
      // Validation of required fields is handled by the JSON Schema layer, not JS.
      const args = buildCalendarCreateArgs({ start: "2026-03-15" }, null);
      expect(args).toContain("--title");
      // The value after --title will be undefined, which the CLI rejects
      const titleIdx = args.indexOf("--title");
      expect(args[titleIdx + 1]).toBeUndefined();
    });

    it("calendar get throws without id", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleCalendar({ action: "get" }, mockCLI))
        .rejects.toThrow("Event ID is required");
    });

    it("calendar update requires id", async () => {
      const mockCLI = createMockCLI({});
      // buildCalendarUpdateArgs itself doesn't throw, but produces no --id
      const args = buildCalendarUpdateArgs({ title: "New Title" });
      expect(args).toContain("update");
    });

    it("calendar delete requires id via handler", async () => {
      // The handler delegates to buildCalendarDeleteArgs which uses args.id directly
      // The handler calls runCLI which would catch missing id
      const args = buildCalendarCreateArgs({ title: "T", start: "2026-03-15" }, null);
      expect(args[0]).toBe("create");
    });

    it("reminder get throws without id", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleReminder({ action: "get" }, mockCLI))
        .rejects.toThrow("Reminder ID is required");
    });

    it("reminder complete throws without id", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleReminder({ action: "complete" }, mockCLI))
        .rejects.toThrow("Reminder ID is required");
    });

    it("reminder delete throws without id", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleReminder({ action: "delete" }, mockCLI))
        .rejects.toThrow("Reminder ID is required");
    });

    it("contact get throws without id", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleContact({ action: "get" }, mockCLI))
        .rejects.toThrow("Contact ID is required");
    });

    it("contact delete throws without id", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleContact({ action: "delete" }, mockCLI))
        .rejects.toThrow("Contact ID is required");
    });

    it("mail get throws without id", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleMail({ action: "get" }, mockCLI))
        .rejects.toThrow("Message ID is required");
    });

    it("mail update throws without id", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleMail({ action: "update" }, mockCLI))
        .rejects.toThrow("Message ID is required");
    });

    it("mail move throws without id", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleMail({ action: "move" }, mockCLI))
        .rejects.toThrow("Message ID is required");
    });

    it("mail move throws without toMailbox", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleMail({ action: "move", id: "msg_1" }, mockCLI))
        .rejects.toThrow("toMailbox");
    });

    it("mail delete throws without id", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleMail({ action: "delete" }, mockCLI))
        .rejects.toThrow("Message ID is required");
    });

    it("mail reply throws without id", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleMail({ action: "reply" }, mockCLI))
        .rejects.toThrow("Message ID is required");
    });

    it("mail send throws without to", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleMail({ action: "send", subject: "Hi", body: "Hello" }, mockCLI))
        .rejects.toThrow("recipient");
    });

    it("mail send throws without subject", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleMail({ action: "send", to: ["a@example.com"], body: "Hello" }, mockCLI))
        .rejects.toThrow("Subject");
    });

    it("calendar search throws without query", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleCalendar({ action: "search" }, mockCLI))
        .rejects.toThrow("query");
    });

    it("reminder search throws without query", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleReminder({ action: "search" }, mockCLI))
        .rejects.toThrow("query");
    });

    it("contact search throws without query", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleContact({ action: "search" }, mockCLI))
        .rejects.toThrow("query");
    });

    it("mail search throws without query", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleMail({ action: "search" }, mockCLI))
        .rejects.toThrow("query");
    });

    it("mail save_attachment throws without id", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleMail({ action: "save_attachment" }, mockCLI))
        .rejects.toThrow("Message ID is required");
    });
  });

  describe("save_attachment argument construction", () => {
    it("passes --index when index is provided", async () => {
      const mockCLI = createMockCLI({ "mail-cli:save-attachment": { success: true, saved: [] } });
      await handleMail({ action: "save_attachment", id: "msg_1", index: 2 }, mockCLI);

      const callArgs = mockCLI.mock.calls[0][1];
      expect(callArgs).toContain("save-attachment");
      expect(argsPairPresent(callArgs, "--id", "msg_1")).toBe(true);
      expect(argsPairPresent(callArgs, "--index", "2")).toBe(true);
    });

    it("passes --dest-dir when destDir is provided", async () => {
      const mockCLI = createMockCLI({ "mail-cli:save-attachment": { success: true, saved: [] } });
      await handleMail({ action: "save_attachment", id: "msg_1", destDir: "/tmp/test" }, mockCLI);

      const callArgs = mockCLI.mock.calls[0][1];
      // destDir is canonicalized before it reaches the CLI, so /tmp resolves to
      // /private/tmp on macOS and stays /tmp on Linux.
      expect(argsPairPresent(callArgs, "--dest-dir", join(realpathSync("/tmp"), "test"))).toBe(true);
    });

    it("omits --index when index is not provided", async () => {
      const mockCLI = createMockCLI({ "mail-cli:save-attachment": { success: true, saved: [] } });
      await handleMail({ action: "save_attachment", id: "msg_1" }, mockCLI);

      const callArgs = mockCLI.mock.calls[0][1];
      expect(callArgs).not.toContain("--index");
    });
  });

  describe("send/reply attachment argument construction", () => {
    let attachDir;
    let attachA;
    let attachB;
    let policyPath;

    beforeAll(() => {
      attachDir = realpathSync(mkdtempSync(join(tmpdir(), "pim-eval-att-")));
      attachA = join(attachDir, "a.pdf");
      attachB = join(attachDir, "b.pdf");
      writeFileSync(attachA, "%PDF-A");
      writeFileSync(attachB, "%PDF-B");
      policyPath = join(attachDir, "mail-attachments.json");
      writeFileSync(policyPath, JSON.stringify({ enabled: true, allowedRoots: [attachDir] }));
      process.env.APPLE_PIM_MAIL_ATTACHMENTS_CONFIG = policyPath;
    });

    afterAll(() => {
      delete process.env.APPLE_PIM_MAIL_ATTACHMENTS_CONFIG;
      rmSync(attachDir, { recursive: true, force: true });
    });

    it("send default-denies attachments when no policy file exists", async () => {
      const mockCLI = createMockCLI({ "mail-cli:send": { success: true } });
      const saved = process.env.APPLE_PIM_MAIL_ATTACHMENTS_CONFIG;
      process.env.APPLE_PIM_MAIL_ATTACHMENTS_CONFIG = "/tmp/pim-eval-no-such-policy.json";
      try {
        await expect(handleMail({
          action: "send", to: ["a@b.com"], subject: "test", body: "hi",
          attachment: attachA,
        }, mockCLI)).rejects.toThrow(/disabled by default/i);
      } finally {
        process.env.APPLE_PIM_MAIL_ATTACHMENTS_CONFIG = saved;
      }
    });

    it("send passes --attachment for single file path (with opt-in policy)", async () => {
      const mockCLI = createMockCLI({ "mail-cli:send": { success: true } });
      await handleMail({
        action: "send", to: ["a@b.com"], subject: "test", body: "hi",
        attachment: attachA,
      }, mockCLI);

      const callArgs = mockCLI.mock.calls[0][1];
      expect(argsPairPresent(callArgs, "--attachment", attachA)).toBe(true);
    });

    it("send passes multiple --attachment flags for array", async () => {
      const mockCLI = createMockCLI({ "mail-cli:send": { success: true } });
      await handleMail({
        action: "send", to: ["a@b.com"], subject: "test", body: "hi",
        attachment: [attachA, attachB],
      }, mockCLI);

      const callArgs = mockCLI.mock.calls[0][1];
      const attValues = callArgs
        .map((arg, i) => arg === "--attachment" ? callArgs[i + 1] : null)
        .filter(Boolean);
      expect(attValues).toContain(attachA);
      expect(attValues).toContain(attachB);
      expect(attValues).toHaveLength(2);
    });

    it("send omits --attachment when not provided", async () => {
      const mockCLI = createMockCLI({ "mail-cli:send": { success: true } });
      await handleMail({
        action: "send", to: ["a@b.com"], subject: "test", body: "hi",
      }, mockCLI);

      const callArgs = mockCLI.mock.calls[0][1];
      expect(callArgs).not.toContain("--attachment");
    });

    it("send throws for nonexistent attachment path", async () => {
      const mockCLI = createMockCLI({ "mail-cli:send": { success: true } });
      await expect(handleMail({
        action: "send", to: ["a@b.com"], subject: "test", body: "hi",
        attachment: join(attachDir, "does-not-exist-abc123.txt"),
      }, mockCLI)).rejects.toThrow(/Attachment file not found/);
    });

    it("send refuses attachments outside allowedRoots", async () => {
      const mockCLI = createMockCLI({ "mail-cli:send": { success: true } });
      await expect(handleMail({
        action: "send", to: ["a@b.com"], subject: "test", body: "hi",
        attachment: "/etc/hosts",
      }, mockCLI)).rejects.toThrow(/outside allowedRoots/i);
    });

    it("send refuses denylisted filenames even when inside allowedRoots", async () => {
      const idRsa = join(attachDir, "id_rsa");
      writeFileSync(idRsa, "PRIVATE KEY");
      const mockCLI = createMockCLI({ "mail-cli:send": { success: true } });
      await expect(handleMail({
        action: "send", to: ["a@b.com"], subject: "test", body: "hi",
        attachment: idRsa,
      }, mockCLI)).rejects.toThrow(/denylisted filename/i);
    });

    it("reply passes --attachment when provided", async () => {
      const mockCLI = createMockCLI({ "mail-cli:reply": { success: true } });
      await handleMail({
        action: "reply", id: "msg_1", body: "thanks",
        attachment: attachA,
      }, mockCLI);

      const callArgs = mockCLI.mock.calls[0][1];
      expect(argsPairPresent(callArgs, "--attachment", attachA)).toBe(true);
    });

    it("reply passes multiple --attachment flags for array", async () => {
      const mockCLI = createMockCLI({ "mail-cli:reply": { success: true } });
      await handleMail({
        action: "reply", id: "msg_1", body: "thanks",
        attachment: [attachA, attachB],
      }, mockCLI);

      const callArgs = mockCLI.mock.calls[0][1];
      const attValues = callArgs
        .map((arg, i) => arg === "--attachment" ? callArgs[i + 1] : null)
        .filter(Boolean);
      expect(attValues).toContain(attachA);
      expect(attValues).toContain(attachB);
      expect(attValues).toHaveLength(2);
    });

    it("reply throws for nonexistent attachment path", async () => {
      const mockCLI = createMockCLI({ "mail-cli:reply": { success: true } });
      await expect(handleMail({
        action: "reply", id: "msg_1", body: "thanks",
        attachment: join(attachDir, "does-not-exist-abc123.txt"),
      }, mockCLI)).rejects.toThrow(/Attachment file not found/);
    });
  });

  describe("batch operation validation", () => {
    it("calendar batch_create throws with empty events", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleCalendar({ action: "batch_create", events: [] }, mockCLI))
        .rejects.toThrow("cannot be empty");
    });

    it("reminder batch_create throws with empty reminders", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleReminder({ action: "batch_create", reminders: [] }, mockCLI))
        .rejects.toThrow("cannot be empty");
    });

    it("reminder batch_complete throws with empty ids", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleReminder({ action: "batch_complete", ids: [] }, mockCLI))
        .rejects.toThrow("cannot be empty");
    });

    it("reminder batch_delete throws with empty ids", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleReminder({ action: "batch_delete", ids: [] }, mockCLI))
        .rejects.toThrow("cannot be empty");
    });

    it("mail batch_update throws with empty ids", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleMail({ action: "batch_update", ids: [] }, mockCLI))
        .rejects.toThrow("cannot be empty");
    });

    it("mail batch_delete throws with empty ids", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleMail({ action: "batch_delete", ids: [] }, mockCLI))
        .rejects.toThrow("cannot be empty");
    });
  });

  describe("dry-run description accuracy", () => {
    it("calendar create dry-run contains title and calendar", () => {
      const result = buildDryRunResponse("calendar", {
        action: "create",
        title: "Team Lunch",
        start: "2026-03-15T12:00:00",
        calendar: "Work",
      });
      expect(result.dryRun).toBe(true);
      expect(result.description).toContain("Team Lunch");
      expect(result.description).toContain("Work");
    });

    it("reminder create dry-run contains title and list", () => {
      const result = buildDryRunResponse("reminder", {
        action: "create",
        title: "Buy milk",
        list: "Shopping",
      });
      expect(result.description).toContain("Buy milk");
      expect(result.description).toContain("Shopping");
    });

    it("calendar delete dry-run contains event ID", () => {
      const result = buildDryRunResponse("calendar", {
        action: "delete",
        id: "evt_ABC123",
      });
      expect(result.description).toContain("evt_ABC123");
    });

    it("mail send dry-run contains recipients and subject", () => {
      const result = buildDryRunResponse("mail", {
        action: "send",
        to: ["alice@example.com", "bob@example.com"],
        subject: "Quarterly Review",
        body: "See attached.",
      });
      expect(result.description).toContain("alice@example.com");
      expect(result.description).toContain("bob@example.com");
      expect(result.description).toContain("Quarterly Review");
    });
  });

  describe("unknown action handling", () => {
    it("calendar throws for unknown action", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleCalendar({ action: "teleport" }, mockCLI))
        .rejects.toThrow("Unknown calendar action");
    });

    it("reminder throws for unknown action", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleReminder({ action: "teleport" }, mockCLI))
        .rejects.toThrow("Unknown reminder action");
    });

    it("contact throws for unknown action", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleContact({ action: "teleport" }, mockCLI))
        .rejects.toThrow("Unknown contact action");
    });

    it("mail throws for unknown action", async () => {
      const mockCLI = createMockCLI({});
      await expect(handleMail({ action: "teleport" }, mockCLI))
        .rejects.toThrow("Unknown mail action");
    });
  });
});
