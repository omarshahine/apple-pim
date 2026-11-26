---
description: Manage macOS reminders - list, search, create, complete, update, delete with filtering and batch operations
argument-hint: "[lists|items|search|create|complete|update|delete] [options]"
allowed-tools:
  - mcp__plugin_apple-pim_apple-pim__reminder
---

# Reminder Management

Manage reminders using the Apple EventKit framework.

## Available Operations

When the user runs this command, determine which operation they need and use the `reminder` tool with the appropriate action:

### List Reminder Lists
Use `reminder` with action `lists` to show all available reminder lists with their IDs.

### List Reminders
Use `reminder` with action `items` to list reminders with optional filtering:
- Optional: `list` (filter by list), `limit`
- Optional: `filter` for date-based views:
  - `overdue` - Past due, incomplete reminders
  - `today` - Due today + overdue (most useful default)
  - `tomorrow` - Due tomorrow only
  - `week` - Due this calendar week
  - `upcoming` - All incomplete with due dates
  - `completed` - Finished reminders
  - `all` - Everything
- Default (no filter): shows incomplete reminders from all lists

### Search Reminders
Use `reminder` with action `search` to find reminders by title or notes:
- Required: `query` (search term)
- Optional: `list`, `completed`, `limit`

### Create Reminder
Use `reminder` with action `create` to create a new reminder:
- Required: `title`
- Optional: `list`, `due` (date/time), `notes`, `priority` (0=none, 1=high, 5=medium, 9=low), `url`, `alarm`, `location`, `recurrence`

### Complete Reminder
Use `reminder` with action `complete` to mark a single reminder as done:
- Required: `id` (reminder ID)
- Optional: `undo` (mark as incomplete)

### Batch Complete
Use `reminder` with action `batch_complete` to mark multiple reminders as done at once:
- Required: `ids` (array of reminder IDs)
- Optional: `undo` (mark as incomplete)

### Update Reminder
Use `reminder` with action `update` to modify an existing reminder:
- Required: `id` (reminder ID)
- Optional: `title`, `due`, `notes`, `priority`, `url`, `location`, `recurrence`
- To clear a due date: set `due` to empty string
- To remove recurrence: set `recurrence.frequency` to `"none"`

### Delete Reminder
Use `reminder` with action `delete` to remove a single reminder:
- Required: `id` (reminder ID)

### Batch Delete
Use `reminder` with action `batch_delete` to remove multiple reminders at once:
- Required: `ids` (array of reminder IDs)

### Sections, Subtasks, Tags and Flags
Reads (`items`, `get`, `search`) include `flagged`, `urgent`, `parentId`, `isSubtask`, `subtaskIds`, `section`, `tags`, `richLinks` and `attachments`; `lists` includes each list's `sections`. They need Full Disk Access; when `metadata.available` is `false`, say so and quote `metadata.reason`.

Writing them uses Apple's private ReminderKit framework. These actions are off by default and need `private: true`. Each is read back and verified; if one fails, report it and do not retry:
- `set_flag`: `id`, optional `flagged: false` to unflag
- `add_subtask`: `parentId`, `title` (then `update` the new ID for due date or notes)
- `move_subtask`: `id` plus `parentId` (same list, top-level parent) or `topLevel: true`
- `set_section`: `id`, `section` (name or ID from `lists`)
- `set_tags`: `id`, `addTags` and/or `removeTags`

### Batch Create
Use `reminder` with action `batch_create` to create multiple reminders in one operation:
- Required: `reminders` (array of reminder objects, each with at least `title`)

## Priority Levels

- 0 = None (default)
- 1 = High (! in Reminders app)
- 5 = Medium (!!)
- 9 = Low (!!!)

## Examples

**List reminder lists:**
```
/apple-pim:reminders lists
```

**List reminders with filters:**
```
/apple-pim:reminders items
/apple-pim:reminders items --list "Shopping"
/apple-pim:reminders items --filter overdue
/apple-pim:reminders items --filter today
/apple-pim:reminders items --filter week
/apple-pim:reminders items --filter completed
```

**Search reminders:**
```
/apple-pim:reminders search "groceries"
```

**Create a reminder:**
```
/apple-pim:reminders create "Buy milk"
/apple-pim:reminders create "Call dentist" --due "tomorrow 9am" --list "Personal"
/apple-pim:reminders create "Submit report" --due "Friday 5pm" --priority 1
/apple-pim:reminders create "Buy groceries" --location {"name":"Home","latitude":37.33,"longitude":-122.03,"proximity":"arrive"}
/apple-pim:reminders create "Check docs" --url "https://example.com/docs"
```

**Complete a reminder:**
```
/apple-pim:reminders complete --id <reminder_id>
/apple-pim:reminders complete --id <reminder_id> --undo
```

**Batch complete multiple reminders:**
```
/apple-pim:reminders batch-complete --ids [<id1>, <id2>, <id3>]
```

**Update a reminder:**
```
/apple-pim:reminders update --id <reminder_id> --due "next Monday"
```

**Delete a reminder:**
```
/apple-pim:reminders delete --id <reminder_id>
```

**Batch delete multiple reminders:**
```
/apple-pim:reminders batch-delete --ids [<id1>, <id2>]
```

## Parsing User Intent

When a user provides natural language, map to the appropriate operation:
- "What do I need to do?" -> `reminder` with action `items`
- "What's overdue?" -> `reminder` with action `items` and filter "overdue"
- "What's due today?" -> `reminder` with action `items` and filter "today"
- "What's coming up this week?" -> `reminder` with action `items` and filter "week"
- "Show my shopping list" -> `reminder` with action `items` and list="Shopping"
- "Show completed reminders" -> `reminder` with action `items` and filter "completed"
- "Remind me to call mom" -> `reminder` with action `create` and title "Call mom"
- "Remind me to buy flowers tomorrow" -> `reminder` with action `create` with title and due date
- "Mark the milk reminder as done" -> First `reminder` with action `search` for "milk", then action `complete`
- "Mark all the groceries as done" -> Search, then `reminder` with action `batch_complete` with all matching IDs
- "I finished the report" -> Infer reminder, then `reminder` with action `complete`
- "Clear all completed reminders" -> `reminder` with action `items` and filter "completed", then action `batch_delete`
- "Remind me when I get home to take out the trash" -> `reminder` with action `create` with title and location (proximity: "arrive")
- "Remind me when I leave the office to call mom" -> `reminder` with action `create` with title and location (proximity: "depart")
