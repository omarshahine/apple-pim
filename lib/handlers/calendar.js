import { relativeDateString } from "../cli-runner.js";
import {
  buildCalendarCreateArgs,
  buildCalendarDeleteArgs,
  buildCalendarUpdateArgs,
} from "../tool-args.js";

export async function handleCalendar(args, runCLI) {
  const cliArgs = [];

  switch (args.action) {
    case "list":
      return await runCLI("calendar-cli", ["list"]);

    case "events":
      cliArgs.push("events");
      if (args.calendar) cliArgs.push("--calendar", args.calendar);
      // Some tool runtimes materialize omitted numeric properties as 0. Explicit
      // bounds must win or `from`/`to` silently collapse to "today".
      if (args.from) {
        cliArgs.push("--from", args.from);
      } else if (args.lastDays !== undefined) {
        cliArgs.push("--from", relativeDateString(-args.lastDays));
      }
      if (args.to) {
        cliArgs.push("--to", args.to);
      } else if (args.nextDays !== undefined) {
        cliArgs.push("--to", relativeDateString(args.nextDays));
      }
      if (args.limit) cliArgs.push("--limit", String(args.limit));
      return await runCLI("calendar-cli", cliArgs);

    case "get":
      if (!args.id) throw new Error("Event ID is required for calendar get");
      return await runCLI("calendar-cli", ["get", "--id", args.id]);

    case "search":
      if (!args.query) throw new Error("Search query is required for calendar search");
      cliArgs.push("search", args.query);
      if (args.calendar) cliArgs.push("--calendar", args.calendar);
      if (args.from) cliArgs.push("--from", args.from);
      if (args.to) cliArgs.push("--to", args.to);
      if (args.limit) cliArgs.push("--limit", String(args.limit));
      return await runCLI("calendar-cli", cliArgs);

    case "create":
      return await runCLI(
        "calendar-cli",
        buildCalendarCreateArgs(args, args.calendar)
      );

    case "update":
      return await runCLI("calendar-cli", buildCalendarUpdateArgs(args));

    case "delete":
      return await runCLI("calendar-cli", buildCalendarDeleteArgs(args));

    case "batch_create":
      if (!args.events || !Array.isArray(args.events) || args.events.length === 0) {
        throw new Error("Events array is required and cannot be empty");
      }
      return await runCLI("calendar-cli", [
        "batch-create",
        "--json",
        JSON.stringify(args.events),
      ]);

    default:
      throw new Error(`Unknown calendar action: ${args.action}`);
  }
}
