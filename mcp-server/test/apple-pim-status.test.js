import { describe, expect, it } from "vitest";
import { handleApplePim } from "../../lib/handlers/apple-pim.js";

describe("PIM permission status", () => {
  it.each(["authorized", "denied", "restricted", "writeOnly", "notDetermined", "unavailable", "futureState"])(
    "exposes %s independently of the credential-shaped legacy field",
    async (permissionStatus) => {
      const result = await handleApplePim({ action: "status" }, async () => ({ authorization: permissionStatus }));
      for (const domain of ["calendars", "reminders", "contacts", "mail"]) {
        expect(result.status[domain]).toMatchObject({ enabled: true, permissionStatus, authorization: permissionStatus });
      }
    },
  );

  it("keeps unknown and failed permissions distinguishable from granted access", async () => {
    const result = await handleApplePim({ action: "status" }, async (cli) => {
      if (cli === "mail-cli") throw new Error("Mail.app is not running");
      return {};
    });
    expect(result.status.calendars).toMatchObject({ enabled: true, permissionStatus: "unknown" });
    expect(result.status.mail).toEqual({ enabled: false, permissionStatus: "error", authorization: "error", message: "Mail.app is not running" });
  });
});
