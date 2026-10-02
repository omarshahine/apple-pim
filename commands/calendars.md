---
description: Manage macOS calendar events - list, search, create, update, delete with batch operations
argument-hint: "[list|events|search|create|update|delete] [options]"
allowed-tools:
  - mcp__plugin_apple-pim_apple-pim__calendar
---

# Calendar Management

Manage calendar events using the Apple EventKit framework.

## Available Operations

When the user runs this command, determine which operation they need and use the `calendar` tool with the appropriate action:

### List Calendars
Use `calendar` with action `list` to show all available calendars with their IDs and names.

### List Events
Use `calendar` with action `events` to list events within a date range:
- Default: today through next 7 days
- Parameters: `calendar` (filter by calendar), `from` (start date), `to` (end date), `limit`
- Convenience parameters: `lastDays` (N days ago), `nextDays` (N days ahead)
- Each event includes `availability`: `busy`, `free`, `tentative`, `unavailable`, or `notSupported`
- Subscribed calendars' availability is read from the local Calendar store, which needs Full Disk Access

### Get Event
Use `calendar` with action `get` to get full details for a specific event:
- Required: `id` (event ID)
- Returns complete event with recurrence rules, alarms, attendees, availability

### Search Events
Use `calendar` with action `search` to find events by title, notes, or location:
- Required: `query` (search term)
- Optional: `calendar`, `from`, `to`, `limit`
- Default search range: 30 days ago to 1 year from now

### Create Event
Use `calendar` with action `create` to create a new event:
- Required: `title`, `start` (date/time)
- Optional: `end` OR `duration` (minutes), `calendar`, `location`, `notes`, `allDay`, `alarm` (minutes before), `url`, `recurrence`

### Batch Create
Use `calendar` with action `batch_create` to create multiple events in one transaction:
- Required: `events` (array of event objects, each with at least `title` and `start`)
- More efficient for bulk operations (e.g., scheduling a week of meetings)

### Update Event
Use `calendar` with action `update` to modify an existing event:
- Required: `id` (event ID from list/search)
- Optional: `title`, `start`, `end`, `location`, `notes`, `url`, `recurrence`, `futureEvents`
- For recurring events: use `futureEvents: true` to apply changes to all future occurrences
- To remove recurrence: set `recurrence.frequency` to `"none"`

### Delete Event
Use `calendar` with action `delete` to remove an event:
- Required: `id` (event ID)
- Optional: `futureEvents` (default: false, only deletes single occurrence)
- Safe for recurring events: default only removes one occurrence

## Date Formats

Accept flexible date formats:
- ISO: `2024-01-15T14:30:00`
- Date/time: `2024-01-15 14:30`
- Date only: `2024-01-15`
- Natural language: `today`, `tomorrow`, `next week`, `next Tuesday`
- Relative: `in 2 hours`, `in 3 days`

## Recurring Events

- **Default delete is single-occurrence safe**: Deleting only removes that one occurrence
- **"Cancel next Tuesday's meeting"** -> Delete single occurrence (default)
- **"Stop the weekly standup"** -> `calendar` with action `delete` and `futureEvents: true` on earliest upcoming occurrence
- **"Make this one-time"** -> `calendar` with action `update` with `recurrence: { frequency: "none" }` and `futureEvents: true`

## Examples

**List calendars:**
```
/apple-pim:calendars list
```

**List upcoming events:**
```
/apple-pim:calendars events
/apple-pim:calendars events --from tomorrow --to "next week"
/apple-pim:calendars events --nextDays 14
/apple-pim:calendars events --lastDays 7
```

**Get event details:**
```
/apple-pim:calendars get --id <event_id>
```

**Search for events:**
```
/apple-pim:calendars search "team meeting"
/apple-pim:calendars search standup --calendar Work
```

**Create an event:**
```
/apple-pim:calendars create "Lunch with John" --start "tomorrow 12pm" --duration 60
/apple-pim:calendars create "All Hands" --start "2024-01-20 10:00" --end "2024-01-20 11:00" --calendar Work --location "Conference Room A"
```

**Create multiple events:**
```
/apple-pim:calendars batch-create --events [{"title": "Standup", "start": "Monday 9am", "duration": 15}, {"title": "Standup", "start": "Tuesday 9am", "duration": 15}]
```

**Update an event:**
```
/apple-pim:calendars update --id <event_id> --title "Updated Title"
```

**Delete an event:**
```
/apple-pim:calendars delete --id <event_id>
```

## Parsing User Intent

When a user provides natural language, map to the appropriate operation:
- "Show my calendar" -> `calendar` with action `events` and default date range
- "What's on my calendar today?" -> `calendar` with action `events` with from/to set to today
- "What meetings do I have tomorrow?" -> `calendar` with action `events` with from/to set to tomorrow
- "What's my schedule this week?" -> `calendar` with action `events` with nextDays 7
- "What happened last week?" -> `calendar` with action `events` with lastDays 7
- "Find the dentist appointment" -> `calendar` with action `search` and query "dentist"
- "Schedule a meeting with Sarah" -> `calendar` with action `create` (may need to ask for details)
- "Schedule daily standups for next week" -> `calendar` with action `batch_create` with recurring pattern or multiple events
- "Cancel my 3pm meeting" -> First `calendar` with action `search`, then action `delete`
- "Move my meeting to 4pm" -> First `calendar` with action `search`, then action `update` with new start time
- "What are the details for the team offsite?" -> `calendar` with action `search`, then action `get` for full details
