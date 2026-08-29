/**
 * Field selection utility for reducing token overhead in agent responses.
 *
 * When a `fields` parameter is provided (e.g., ["id", "title", "start"]),
 * only those keys are retained in the output objects. Structural wrapper
 * keys (like "events", "reminders", "contacts", "messages") are preserved
 * automatically — filtering applies to the items inside those arrays and
 * to top-level single-item responses.
 */

/** Keys that wrap result arrays — never stripped by field filtering. */
const WRAPPER_KEYS = new Set([
  "events",
  "reminders",
  "contacts",
  "messages",
  "message",
  "calendars",
  "lists",
  "groups",
  "accounts",
  "mailboxes",
  "results",
  "status",
  "success",
  "error",
  "output",
]);

/**
 * Pick only the requested fields from an object.
 * Always preserves "id" so results stay addressable.
 * When date fields are requested, auto-includes their local counterparts.
 */
function pickFields(obj, fields) {
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) return obj;
  const fieldSet = new Set(fields);
  fieldSet.add("id"); // always include id for addressability
  // Auto-include local time fields when date fields are requested
  if (fieldSet.has("start") || fieldSet.has("startDate")) fieldSet.add("localStart");
  if (fieldSet.has("end") || fieldSet.has("endDate")) fieldSet.add("localEnd");
  const picked = {};
  for (const key of Object.keys(obj)) {
    if (fieldSet.has(key)) {
      picked[key] = obj[key];
    }
  }
  return picked;
}

/**
 * Apply field selection to a tool result.
 *
 * - For list responses (result contains an array under a wrapper key),
 *   each item in the array is filtered.
 * - For single-item responses, the top-level object is filtered.
 * - Wrapper/structural keys are never removed from the top level.
 *
 * @param {object} result - The raw result from a handler.
 * @param {string[]|undefined} fields - Requested fields, or undefined to skip filtering.
 * @returns {object} Filtered result.
 */
export function applyFieldSelection(result, fields) {
  if (!fields || !Array.isArray(fields) || fields.length === 0) {
    return result;
  }
  if (!result || typeof result !== "object") {
    return result;
  }

  // Build augmented field set once for both array-item and top-level paths
  const fieldSet = new Set(fields);
  fieldSet.add("id");
  if (fieldSet.has("start") || fieldSet.has("startDate")) fieldSet.add("localStart");
  if (fieldSet.has("end") || fieldSet.has("endDate")) fieldSet.add("localEnd");

  const filtered = {};

  for (const [key, value] of Object.entries(result)) {
    if (WRAPPER_KEYS.has(key) && Array.isArray(value)) {
      // Filter each item in the wrapped array
      filtered[key] = value.map((item) => pickFields(item, fields));
    } else if (key === "message" && value && typeof value === "object") {
      // A single-message response is structurally identical to a messages array with one
      // item. Preserve the wrapper, but still apply the caller's token-reduction request to
      // its contents.
      filtered[key] = pickFields(value, fields);
    } else if (WRAPPER_KEYS.has(key)) {
      // Structural scalars/objects (e.g., success, status) — keep as-is
      filtered[key] = value;
    } else {
      // Top-level item fields — filter if requested
      if (fieldSet.has(key)) {
        filtered[key] = value;
      }
    }
  }

  return filtered;
}
