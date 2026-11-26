import {
  buildReminderCreateArgs,
  buildReminderUpdateArgs,
} from "../tool-args.js";

const METADATA_MODES = new Set(["auto", "off", "required"]);

/** `--metadata <mode>` for read commands, validated so a typo fails here, not in the CLI. */
function metadataArgs(args) {
  if (args.metadata === undefined) return [];
  if (!METADATA_MODES.has(args.metadata)) {
    throw new Error(`metadata must be one of auto, off, required (got ${args.metadata})`);
  }
  return ["--metadata", args.metadata];
}

/**
 * Private ReminderKit writes (flags, subtasks, sections, tags) are off by default. The
 * caller opts in per call with `private: true`; reminder-cli refuses without `--private`
 * as well, so the gate holds even if this check were bypassed.
 */
function privateArgs(args, action) {
  if (args.private !== true) {
    throw new Error(
      `reminder ${action} writes through Apple's private ReminderKit framework and is off by default. ` +
      "Pass private: true to confirm. It needs Full Disk Access so the result can be read back and verified.",
    );
  }
  return ["--private"];
}

function requireId(args, action) {
  if (!args.id) throw new Error(`Reminder ID is required for reminder ${action}`);
  return args.id;
}

export async function handleReminder(args, runCLI) {
  const cliArgs = [];

  switch (args.action) {
    case "lists":
      return await runCLI("reminder-cli", ["lists", ...metadataArgs(args)]);

    case "items":
      cliArgs.push("items");
      if (args.list) cliArgs.push("--list", args.list);
      if (args.filter) cliArgs.push("--filter", args.filter);
      if (!args.filter && args.completed) cliArgs.push("--completed");
      if (args.limit) cliArgs.push("--limit", String(args.limit));
      cliArgs.push(...metadataArgs(args));
      return await runCLI("reminder-cli", cliArgs);

    case "get":
      if (!args.id) throw new Error("Reminder ID is required for reminder get");
      return await runCLI("reminder-cli", ["get", "--id", args.id, ...metadataArgs(args)]);

    case "search":
      if (!args.query) throw new Error("Search query is required for reminder search");
      cliArgs.push("search", args.query);
      if (args.list) cliArgs.push("--list", args.list);
      if (args.completed) cliArgs.push("--completed");
      if (args.limit) cliArgs.push("--limit", String(args.limit));
      cliArgs.push(...metadataArgs(args));
      return await runCLI("reminder-cli", cliArgs);

    case "create":
      return await runCLI(
        "reminder-cli",
        buildReminderCreateArgs(args, args.list)
      );

    case "complete":
      if (!args.id) throw new Error("Reminder ID is required for reminder complete");
      cliArgs.push("complete", "--id", args.id);
      if (args.undo) cliArgs.push("--undo");
      return await runCLI("reminder-cli", cliArgs);

    case "update":
      return await runCLI("reminder-cli", buildReminderUpdateArgs(args));

    case "delete":
      if (!args.id) throw new Error("Reminder ID is required for reminder delete");
      return await runCLI("reminder-cli", ["delete", "--id", args.id]);

    case "batch_create":
      if (!args.reminders || !Array.isArray(args.reminders) || args.reminders.length === 0) {
        throw new Error("Reminders array is required and cannot be empty");
      }
      return await runCLI("reminder-cli", [
        "batch-create",
        "--json",
        JSON.stringify(args.reminders),
      ]);

    case "batch_complete":
      if (!args.ids || !Array.isArray(args.ids) || args.ids.length === 0) {
        throw new Error("IDs array is required and cannot be empty");
      }
      cliArgs.push("batch-complete", "--json", JSON.stringify(args.ids));
      if (args.undo) cliArgs.push("--undo");
      return await runCLI("reminder-cli", cliArgs);

    case "batch_delete":
      if (!args.ids || !Array.isArray(args.ids) || args.ids.length === 0) {
        throw new Error("IDs array is required and cannot be empty");
      }
      return await runCLI("reminder-cli", [
        "batch-delete",
        "--json",
        JSON.stringify(args.ids),
      ]);

    case "set_flag": {
      const id = requireId(args, "set_flag");
      const gate = privateArgs(args, "set_flag");
      cliArgs.push("set-flag", "--id", id, ...gate);
      if (args.flagged === false) cliArgs.push("--unflag");
      return await runCLI("reminder-cli", cliArgs);
    }

    case "add_subtask": {
      const parent = args.parentId;
      if (!parent) throw new Error("parentId is required for reminder add_subtask");
      if (!args.title) throw new Error("title is required for reminder add_subtask");
      const gate = privateArgs(args, "add_subtask");
      return await runCLI("reminder-cli", ["add-subtask", "--parent", parent, "--title", args.title, ...gate]);
    }

    case "move_subtask": {
      const id = requireId(args, "move_subtask");
      if (Boolean(args.parentId) === Boolean(args.topLevel)) {
        throw new Error("Pass exactly one of parentId or topLevel: true for reminder move_subtask");
      }
      const gate = privateArgs(args, "move_subtask");
      cliArgs.push("move-subtask", "--id", id, ...gate);
      if (args.parentId) cliArgs.push("--parent", args.parentId);
      else cliArgs.push("--top-level");
      return await runCLI("reminder-cli", cliArgs);
    }

    case "set_section": {
      const id = requireId(args, "set_section");
      if (!args.section) throw new Error("section (name or ID) is required for reminder set_section");
      const gate = privateArgs(args, "set_section");
      return await runCLI("reminder-cli", ["set-section", "--id", id, "--section", args.section, ...gate]);
    }

    case "set_tags": {
      const id = requireId(args, "set_tags");
      const add = args.addTags ?? [];
      const remove = args.removeTags ?? [];
      if (!Array.isArray(add) || !Array.isArray(remove) || add.length + remove.length === 0) {
        throw new Error("addTags and/or removeTags (arrays of tag names) are required for reminder set_tags");
      }
      const gate = privateArgs(args, "set_tags");
      cliArgs.push("set-tags", "--id", id, ...gate);
      for (const tag of add) cliArgs.push("--add", String(tag));
      for (const tag of remove) cliArgs.push("--remove", String(tag));
      return await runCLI("reminder-cli", cliArgs);
    }

    default:
      throw new Error(`Unknown reminder action: ${args.action}`);
  }
}
