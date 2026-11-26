import { describe, expect, it } from "vitest";
import { loadScenario } from "../helpers/scenario-runner.js";
import { buildDryRunResponse, isMutation } from "../../lib/dry-run.js";
import { detectSuspiciousContent } from "../../lib/sanitize.js";
import { handleCalendar } from "../../lib/handlers/calendar.js";
import { handleReminder } from "../../lib/handlers/reminder.js";
import { handleContact } from "../../lib/handlers/contact.js";
import { handleMail } from "../../lib/handlers/mail.js";
import { tools } from "../../lib/schemas.js";
import { createMockCLI } from "../helpers/mock-cli.js";

const scenarioFile = loadScenario("safety.yaml");

const handlers = {
  calendar: handleCalendar,
  reminder: handleReminder,
  contact: handleContact,
  mail: handleMail,
};

describe("Category 4: Safety Properties", () => {
  describe("destructive operation warnings", () => {
    for (const testCase of scenarioFile.destructive_actions) {
      const desc = `${testCase.tool} ${testCase.input.action}${testCase.input.toMailbox ? ` to ${testCase.input.toMailbox}` : ""} ${testCase.has_warning ? "has" : "does NOT have"} warning`;
      it(desc, () => {
        const result = buildDryRunResponse(testCase.tool, testCase.input);
        if (testCase.has_warning) {
          expect(result.warning).toBeDefined();
          expect(result.warning).toContain("destructive");
        } else {
          expect(result.warning).toBeUndefined();
        }
      });
    }
  });

  describe("ID-required action validation", () => {
    for (const entry of scenarioFile.id_required_actions) {
      for (const action of entry.actions) {
        it(`${entry.tool} ${action} throws without id`, async () => {
          const handler = handlers[entry.tool];
          const mockCLI = createMockCLI({});

          // Build minimal args (some actions need additional fields)
          const args = { action };
          if (action === "reply") args.body = "test";
          if (action === "move") args.toMailbox = "Archive";

          await expect(handler(args, mockCLI)).rejects.toThrow(/[Ii][Dd].*required|required.*[Ii][Dd]/i);
        });
      }
    }
  });

  describe("injection pattern detection", () => {
    for (const text of scenarioFile.injection_patterns.suspicious) {
      it(`detects: "${text.substring(0, 50)}..."`, () => {
        const result = detectSuspiciousContent(text);
        expect(result.suspicious).toBe(true);
        expect(result.matches.length).toBeGreaterThan(0);
      });
    }

    for (const text of scenarioFile.injection_patterns.clean) {
      it(`clean: "${text}"`, () => {
        const result = detectSuspiciousContent(text);
        expect(result.suspicious).toBe(false);
      });
    }
  });

  describe("internal params stripped from dry-run", () => {
    const internalParams = scenarioFile.internal_params.params_to_strip;

    it("dry-run response parameters do not include internal params", () => {
      const result = buildDryRunResponse("calendar", {
        action: "create",
        title: "Test",
        start: "2026-03-15",
        dryRun: true,
        fields: ["id", "title"],
        configDir: "/custom/config",
        profile: "test-profile",
      });

      for (const param of internalParams) {
        expect(result.parameters).not.toHaveProperty(param);
      }

      // But the actual params should be present
      expect(result.parameters.title).toBe("Test");
      expect(result.parameters.start).toBe("2026-03-15");
    });
  });

  describe("schema coverage", () => {
    it("every calendar action enum value has at least one eval", () => {
      const calendarTool = tools.find((t) => t.name === "calendar");
      const actions = calendarTool.inputSchema.properties.action.enum;
      // These are covered across our eval files
      const covered = new Set([
        "list", "events", "get", "search", "create", "update", "delete",
        "batch_create", "schema",
      ]);
      for (const action of actions) {
        expect(covered.has(action)).toBe(true);
      }
    });

    it("every reminder action enum value has at least one eval", () => {
      const reminderTool = tools.find((t) => t.name === "reminder");
      const actions = reminderTool.inputSchema.properties.action.enum;
      const covered = new Set([
        "lists", "items", "get", "search", "create", "complete",
        "update", "delete", "batch_create", "batch_complete", "batch_delete",
        // Private ReminderKit writes: tool-call-correctness.yaml rem-set-flag-*, rem-add-subtask,
        // rem-move-subtask-*, rem-set-section, rem-set-tags-*.
        "set_flag", "add_subtask", "move_subtask", "set_section", "set_tags",
        "schema",
      ]);
      for (const action of actions) {
        expect(covered.has(action)).toBe(true);
      }
    });

    it("every contact action enum value has at least one eval", () => {
      const contactTool = tools.find((t) => t.name === "contact");
      const actions = contactTool.inputSchema.properties.action.enum;
      const covered = new Set([
        "containers", "groups", "list", "search", "get", "create", "update", "delete", "schema",
      ]);
      for (const action of actions) {
        expect(covered.has(action)).toBe(true);
      }
    });

    it("every mail action enum value has at least one eval", () => {
      const mailTool = tools.find((t) => t.name === "mail");
      const actions = mailTool.inputSchema.properties.action.enum;
      const covered = new Set([
        "accounts", "mailboxes", "messages", "get", "search",
        "update", "move", "delete", "batch_update", "batch_delete",
        "send", "reply", "save_attachment", "auth_check", "schema",
      ]);
      for (const action of actions) {
        expect(covered.has(action)).toBe(true);
      }
    });
  });

  describe("mutation detection accuracy", () => {
    it("correctly identifies all calendar mutations", () => {
      expect(isMutation("calendar", "create")).toBe(true);
      expect(isMutation("calendar", "update")).toBe(true);
      expect(isMutation("calendar", "delete")).toBe(true);
      expect(isMutation("calendar", "batch_create")).toBe(true);
      expect(isMutation("calendar", "list")).toBe(false);
      expect(isMutation("calendar", "events")).toBe(false);
      expect(isMutation("calendar", "get")).toBe(false);
      expect(isMutation("calendar", "search")).toBe(false);
    });

    it("correctly identifies all reminder mutations", () => {
      expect(isMutation("reminder", "create")).toBe(true);
      expect(isMutation("reminder", "complete")).toBe(true);
      expect(isMutation("reminder", "update")).toBe(true);
      expect(isMutation("reminder", "delete")).toBe(true);
      expect(isMutation("reminder", "batch_create")).toBe(true);
      expect(isMutation("reminder", "batch_complete")).toBe(true);
      expect(isMutation("reminder", "batch_delete")).toBe(true);
      expect(isMutation("reminder", "lists")).toBe(false);
      expect(isMutation("reminder", "items")).toBe(false);
    });

    it("correctly identifies all mail mutations", () => {
      expect(isMutation("mail", "update")).toBe(true);
      expect(isMutation("mail", "move")).toBe(true);
      expect(isMutation("mail", "delete")).toBe(true);
      expect(isMutation("mail", "batch_update")).toBe(true);
      expect(isMutation("mail", "batch_delete")).toBe(true);
      expect(isMutation("mail", "send")).toBe(true);
      expect(isMutation("mail", "reply")).toBe(true);
      expect(isMutation("mail", "save_attachment")).toBe(true);
      expect(isMutation("mail", "accounts")).toBe(false);
      expect(isMutation("mail", "messages")).toBe(false);
    });

    it("returns false for unknown tools", () => {
      expect(isMutation("unknown", "create")).toBe(false);
    });
  });
});
