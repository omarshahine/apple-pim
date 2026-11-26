/**
 * Dry-run support for mutation operations.
 *
 * When `dryRun: true` is passed, validates all arguments and returns a
 * structured preview of what the operation *would* do, without calling
 * the Swift CLI. This lets agents verify intent before committing changes.
 */

/** Actions that mutate state, organized by tool. */
const MUTATION_ACTIONS = {
  calendar: new Set(["create", "update", "delete", "batch_create"]),
  reminder: new Set([
    "create",
    "complete",
    "update",
    "delete",
    "batch_create",
    "batch_complete",
    "batch_delete",
    "set_flag",
    "add_subtask",
    "move_subtask",
    "set_section",
    "set_tags",
  ]),
  contact: new Set(["create", "update", "delete"]),
  mail: new Set([
    "update",
    "move",
    "delete",
    "batch_update",
    "batch_delete",
    "send",
    "reply",
    "save_attachment",
  ]),
};

/**
 * Check if an action is a mutation for a given tool.
 */
export function isMutation(toolName, action) {
  const actions = MUTATION_ACTIONS[toolName];
  return actions ? actions.has(action) : false;
}

/**
 * Build a dry-run response describing what the operation would do.
 *
 * @param {string} toolName - Tool name (calendar, reminder, contact, mail).
 * @param {object} args - The full tool arguments.
 * @returns {{ dryRun: true, action: string, tool: string, description: string, parameters: object }}
 */
export function buildDryRunResponse(toolName, args) {
  const { action, dryRun, fields, configDir, profile, ...params } = args;

  const description = describeMutation(toolName, action, params);

  return {
    dryRun: true,
    tool: toolName,
    action,
    description,
    parameters: params,
    ...(isDestructive(action, params)
      ? { warning: "This is a destructive operation. Data will be permanently deleted." }
      : {}),
  };
}

function isDestructive(action, params = {}) {
  if (action === "delete" || action === "batch_delete") return true;
  if (action === "move") {
    const dest = (params.toMailbox || "").toLowerCase();
    return dest === "trash" || dest.includes("deleted");
  }
  return false;
}

function describeMutation(tool, action, params) {
  switch (action) {
    case "create":
      return describeCreate(tool, params);
    case "update":
      return describeUpdate(tool, params);
    case "delete":
      return describeDelete(tool, params);
    case "batch_create":
      return describeBatchCreate(tool, params);
    case "batch_complete":
      return `Would mark ${params.ids?.length || 0} reminder(s) as ${params.undo ? "incomplete" : "complete"}`;
    case "batch_update":
      return `Would update ${params.ids?.length || 0} message(s) (${describeMailFlags(params)})`;
    case "batch_delete":
      return `Would delete ${params.ids?.length || 0} ${tool === "mail" ? "message(s)" : "reminder(s)"}`;
    case "complete":
      return `Would mark reminder ${params.id || "?"} as ${params.undo ? "incomplete" : "complete"}`;
    case "move":
      return `Would move message ${params.id || "?"} to mailbox "${params.toMailbox || "?"}"`;
    case "send": {
      const sendAttCount = params.attachment ? (Array.isArray(params.attachment) ? params.attachment.length : 1) : 0;
      return `Would send email to ${formatRecipients(params.to)} with subject "${params.subject || ""}"${sendAttCount ? ` (${sendAttCount} attachment${sendAttCount > 1 ? "s" : ""})` : ""}`;
    }
    case "reply": {
      const replyAttCount = params.attachment ? (Array.isArray(params.attachment) ? params.attachment.length : 1) : 0;
      return `Would reply to message ${params.id || "?"}${replyAttCount ? ` (${replyAttCount} attachment${replyAttCount > 1 ? "s" : ""})` : ""}`;
    }
    case "set_flag":
      return `Would ${params.flagged === false ? "unflag" : "flag"} reminder ${params.id || "?"} (private ReminderKit write)`;
    case "add_subtask":
      return `Would add subtask "${params.title || "?"}" under reminder ${params.parentId || "?"} (private ReminderKit write)`;
    case "move_subtask":
      return params.topLevel
        ? `Would make reminder ${params.id || "?"} top-level (private ReminderKit write)`
        : `Would move reminder ${params.id || "?"} under ${params.parentId || "?"} (private ReminderKit write)`;
    case "set_section":
      return `Would put reminder ${params.id || "?"} in section "${params.section || "?"}" (private ReminderKit write)`;
    case "set_tags": {
      const parts = [];
      if (params.addTags?.length) parts.push(`add ${params.addTags.join(", ")}`);
      if (params.removeTags?.length) parts.push(`remove ${params.removeTags.join(", ")}`);
      return `Would ${parts.join(" and ") || "change no tags"} on reminder ${params.id || "?"} (private ReminderKit write)`;
    }
    case "save_attachment":
      return `Would save ${params.index !== undefined ? `attachment #${params.index}` : "all attachments"} from message ${params.id || "?"} to ${params.destDir || "temp directory"}`;
    default:
      return `Would perform ${action} on ${tool}`;
  }
}

function describeCreate(tool, params) {
  switch (tool) {
    case "calendar":
      return `Would create event "${params.title || "?"}" starting ${params.start || "?"} on calendar "${params.calendar || "default"}"`;
    case "reminder":
      return `Would create reminder "${params.title || "?"}" in list "${params.list || "default"}"${params.due ? ` due ${params.due}` : ""}`;
    case "contact":
      return `Would create contact "${params.name || params.firstName || "?"}"`;
    default:
      return `Would create ${tool} item`;
  }
}

function describeUpdate(tool, params) {
  switch (tool) {
    case "calendar":
      return `Would update event ${params.id || "?"}${params.title ? ` (title → "${params.title}")` : ""}`;
    case "reminder":
      return `Would update reminder ${params.id || "?"}${params.title ? ` (title → "${params.title}")` : ""}`;
    case "contact":
      return `Would update contact ${params.id || "?"}`;
    case "mail":
      return `Would update message ${params.id || "?"} (${describeMailFlags(params)})`;
    default:
      return `Would update ${tool} item ${params.id || "?"}`;
  }
}

function describeDelete(tool, params) {
  const target = tool === "mail" ? "message" : tool === "calendar" ? "event" : tool;
  return `Would delete ${target} ${params.id || "?"}${params.futureEvents ? " and all future occurrences" : ""}`;
}

function describeBatchCreate(tool, params) {
  if (tool === "calendar") {
    return `Would create ${params.events?.length || 0} event(s)`;
  }
  if (tool === "reminder") {
    return `Would create ${params.reminders?.length || 0} reminder(s)`;
  }
  return `Would batch create ${tool} items`;
}

function describeMailFlags(params) {
  const flags = [];
  if (params.read !== undefined) flags.push(`read=${params.read}`);
  if (params.flagged !== undefined) flags.push(`flagged=${params.flagged}`);
  if (params.junk !== undefined) flags.push(`junk=${params.junk}`);
  return flags.length > 0 ? flags.join(", ") : "no flag changes";
}

function formatRecipients(to) {
  if (!to) return "?";
  const list = Array.isArray(to) ? to : [to];
  return list.join(", ");
}
