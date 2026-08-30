---
name: apple-pim
description: |
  Native macOS personal information management for calendars, reminders, contacts, and local Mail.app. Use when the user wants to schedule meetings, create events, check their calendar, create or complete reminders, look up contacts, find someone's phone number or email, manage tasks and to-do lists, triage local Mail.app messages, or troubleshoot EventKit, Contacts, or Mail.app permissions on macOS.
license: MIT
compatibility: |
  macOS only. Requires TCC permissions for Calendars, Reminders, and Contacts via Privacy & Security settings. Mail features require Mail.app running with Automation permission granted.
metadata:
  author: Omar Shahine
  version: 3.2.0
  mcp-server: apple-pim
---

# Apple PIM (EventKit, Contacts & Mail)

## Overview

Apple provides frameworks and scripting interfaces for personal information management:
- **EventKit**: Calendars and Reminders
- **Contacts**: Address book management
- **Mail.app**: Local email — reads via direct SQLite (Envelope Index, milliseconds), mutations via JXA/AppleScript

EventKit and Contacts require explicit user permission via privacy prompts. Mail.app requires Automation permission and must be running.

For detailed API property tables and code examples, see:
- `references/eventkit-api.md` — EKEvent, EKReminder, EKCalendar, recurrence rules, alarms
- `references/contacts-api.md` — CNContact, labeled values, groups
- `references/mail-jxa.md` — JXA message properties, batch fetching, Mail.app vs Fastmail scope

## Authorization & Permissions

### Permission Model

Each PIM domain requires separate macOS authorization:

| Domain | Framework | Permission Section |
|--------|-----------|-------------------|
| Calendars | EventKit | Privacy & Security > Calendars |
| Reminders | EventKit | Privacy & Security > Reminders |
| Contacts | Contacts | Privacy & Security > Contacts |
| Mail (mutations) | Automation (JXA) | Privacy & Security > Automation |
| Mail (fast reads) | Full Disk Access | Privacy & Security > Full Disk Access |

### Authorization States

| State | Meaning | Action |
|-------|---------|--------|
| `notDetermined` | Never requested | Use `apple-pim` with action `authorize` to trigger prompt |
| `authorized` | Full access granted | Ready to use |
| `denied` | User refused access | Must enable in System Settings manually |
| `restricted` | System policy (MDM, parental) | Cannot override |
| `writeOnly` | Limited write access (macOS 17+) | Upgrade to Full Access in Settings |

### SSH Sessions

Permissions must be granted on the Mac where the CLI runs. SSH does not inherit GUI-level permission dialogs. Grant permissions locally first.

## Configuration (PIMConfig)

The PIM CLIs share a configuration system for filtering calendars/reminder lists and setting defaults.

### Config File Locations

| Path | Purpose |
|------|---------|
| `~/.config/apple-pim/config.json` | Base configuration |
| `~/.config/apple-pim/profiles/{name}.json` | Named profile overrides |

### Example Config

```json
{
  "calendars": {
    "enabled": true,
    "mode": "blocklist",
    "items": ["US Holidays", "Birthdays"],
    "default": "Personal"
  },
  "reminders": {
    "enabled": true,
    "mode": "allowlist",
    "items": ["Tasks", "Shopping", "Work"],
    "default": "Tasks"
  },
  "contacts": {
    "enabled": true
  },
  "mail": {
    "enabled": true
  }
}
```

### Domain Filter Config

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | Whether the domain is active (default: `true`) |
| `mode` | string | Filter mode: `all`, `allowlist`, or `blocklist` (default: `all`) |
| `items` | string[] | Calendar/list names for allowlist or blocklist |
| `default` | string | Default calendar or list for creating new items |

### Filter Modes

| Mode | Behavior |
|------|----------|
| `all` | No filtering — all calendars/lists are visible (default) |
| `allowlist` | Only calendars/lists named in `items` are visible |
| `blocklist` | All calendars/lists are visible EXCEPT those named in `items` |

### Profiles

Profiles allow different configurations for different contexts (e.g., work vs personal).

**Selection priority**: `--profile` CLI flag > `APPLE_PIM_PROFILE` env var > base config only.

**Merge semantics**: A profile replaces entire domain sections. If a profile defines `calendars`, it completely replaces the base `calendars` config (not a field-by-field merge).

### Discovery Tools

- **`apple-pim` with action `config_show`**: Returns the current resolved config after profile merging. Shows domains, filters, defaults, and paths.
- **`apple-pim` with action `config_init`**: Lists all available calendars and reminder lists from macOS with their sources and system defaults. Does NOT write any files.

Both accept an optional `profile` parameter.

### Defaults Resolution

When creating events or reminders, the default calendar/list is resolved in this order:
1. Explicit `--calendar` or `--list` parameter
2. Config `default` value for the domain
3. System default calendar/list from EventKit

### Note

There is no MCP tool for writing config files. Users must manually create or edit `~/.config/apple-pim/config.json`. Use `apple-pim` with action `config_init` to discover available calendars/lists, then guide the user on creating the config.

### Trusted Senders (auth_check)

The `auth_check` action verifies sender identity by parsing Authentication-Results headers (DKIM + SPF) against a trusted senders config.

**Config file**: `~/.config/apple-pim/trusted-senders.json`

```json
{
  "version": 1,
  "trustedSenders": [
    {
      "name": "Alice",
      "emails": ["alice@example.com"],
      "expectedDkimDomains": ["example.com"],
      "requireSpf": true
    }
  ]
}
```

Override path with `trustedSenders` parameter: `mail({ action: "auth_check", id: "<msg-id>", trustedSenders: "~/custom/senders.json" })`

## Best Practices

### Calendar Management
1. **Use default calendar for new events** when user doesn't specify
2. **Preserve recurrence rules** when updating recurring events
3. **Handle `.thisEvent` vs `.futureEvents`** span for recurring event edits (see EKSpan below)
4. **Check `allowsContentModifications`** before attempting writes
5. **Use `calendar` with action `batch_create`** when creating multiple events for efficiency

### EKSpan for Recurring Events

EventKit uses `EKSpan` to control which occurrences are affected by save/delete operations:

| Span | Effect | When to Use |
|------|--------|-------------|
| `.thisEvent` | Affects only the single occurrence | Default for delete and update. Use when cancelling one meeting. |
| `.futureEvents` | Affects this and all future occurrences | Use when ending a series or changing the pattern going forward. |

- **Delete**: Default is `.thisEvent`. Pass `--future-events` to use `.futureEvents`.
- **Update**: Default is `.thisEvent`. Pass `--future-events` to apply changes to all future occurrences.
- **Remove recurrence**: Pass `recurrence: { frequency: "none" }` with `--future-events` to convert a recurring event into a single event.

### Recurrence Output

When reading events/reminders, the `recurrence` array includes:
- `frequency`: daily, weekly, monthly, yearly
- `interval`: repeat every N periods
- `daysOfTheWeek`: which days (e.g., `["monday", "wednesday", "friday"]`)
- `daysOfTheMonth`: which days of month (e.g., `[1, 15]`)
- `endDate` or `occurrenceCount`: when the series ends

### Reminder Management
1. **Default to incomplete reminders** when listing
2. **Use filters for focused views**: `overdue` for urgent items, `today` for daily planning, `week` for weekly review
3. **Set completionDate** when marking complete
4. **Respect priority levels** (1=high is flagged in UI)
5. **Use dueDateComponents** not absolute dates for better handling
6. **Use batch operations** (`reminder` with action `batch_complete`, `batch_delete`) when acting on multiple items
7. **`url` is an EventKit field Apple Reminders never renders** — a link written only to
   `EKReminder.url` is invisible to the user. The CLI therefore mirrors it into the notes as
   a `🔗 <url>` line, which Reminders does display and data-detect. Clearing the URL removes
   that line; updating other fields preserves both. Pass `urlInNotes: false` (or
   `--no-url-in-notes` on the CLI) when you want the value stored for machine use only

8. **`alarm` on a reminder moves the reminder; it is not an early heads-up** — Apple Reminders
   has one notion of a reminder's time and draws the *earliest* alarm, falling back to the due
   date only when a reminder has no alarms. `alarm: [15]` on a reminder due at 3:00 makes it
   read and fire at 2:45, and the 3:00 due time appears nowhere in the app. Adding a companion
   alarm at the due date does not restore it (earliest still wins), and an absolute alarm
   resolves to the same instant. Use `alarm: [0]` to alert at the due date — that is what
   Reminders itself writes — or set the due date to the time the user actually wants. The CLI
   returns a `warnings` array whenever a write moves the visible time; surface it
9. **A timed due date gets an alert automatically** — Reminders.app attaches an alarm at the
   due moment to every timed reminder created in its UI (measured in a live library: 116 of
   178 timed reminders carry it) and attaches nothing to an all-day one (115 of 119 carry
   nothing). The CLI now writes the same shape, so a reminder created here is
   indistinguishable from one created in the app. All-day dues get nothing — an alert on a
   date with no time resolves to midnight. An explicit `alarm` is left exactly as passed.
   Opt out with `dueAlert: false` (`--no-due-alert`). On update this applies only when `due`
   is also being set, so an unrelated edit never grows an alarm
10. **`startDate` mirrors the due date and is returned on reads** — Reminders offers no separate
   start-date control, so the CLI keeps the two in sync on every write. A reminder that ends up
   with a start date but no due date renders as *dateless* in Reminders while still occupying a
   date slot in EventKit; the returned `startDate` is how you diagnose that

### What EventKit cannot reach

These are Reminders/Calendar features with no EventKit API. **Say so and stop — do not
improvise an adjacent thing.** Writing `#tag` into a title, creating five flat reminders to
stand in for a checklist, or putting "SUBTASK:" in the notes produces data the user did not ask
for and has to clean up by hand.

| Feature | Status |
| --- | --- |
| Subtasks / nesting | **Verified dead.** `parentID` (type `EKObjectID`) accepts a `setValue` in memory but does not survive `eventStore.save()`; every object ID comes back temporary, and AppleScript's `container` is read-only. Only the Reminders UI can create the relationship |
| Tags | No API — a `#tag` in a title or note is inert text, not a tag |
| Flag | No API. Distinct from priority, which *is* supported |
| Attached images / files | No API. Part of why a link has to live in `notes` to be reachable |
| Sections within a list | No API |
| Smart Lists | No API |
| Remind me when messaging | No API |
| Assignee on a shared list | No API |

Calendar's `url` field is **not** on this list: Calendar renders `EKEvent.url` as a live link in
the event inspector, so `url` on an event reaches the user as-is and needs no mirroring. Only
Reminders hides it.

### Contact Management
1. **Use unified contacts** for consistent view across accounts
2. **Preserve existing data** when updating (only modify changed fields)
3. **Handle labeled values carefully** - don't lose non-primary entries
4. **Request minimum necessary keys** for performance

### Mail Management
1. **Mail.app must be running** for mutations, sends, and `content` search (reads use the direct SQLite path and work with Mail.app closed when Full Disk Access is granted)
2. **Use batch operations** (`mail` with action `batch_update`, `batch_delete`) for inbox triage
3. **Use filters** (unread, flagged) for efficient message listing
4. **Message IDs are RFC 2822** — stable across mailbox moves
5. **Use mailbox/account hints** when available for faster lookups
6. **Send** (`mail` with action `send`) uses AppleScript — supports `to`, `cc`, `bcc`, `from` (account selection), `subject`, `body`
7. **Reply** (`mail` with action `reply`) preserves threading — looks up message by RFC 2822 ID, then uses Mail.app's `reply` verb
8. **Auth check** (`mail` with action `auth_check`) verifies DKIM/SPF against `~/.config/apple-pim/trusted-senders.json` — returns `verified`, `suspicious`, `untrusted`, or `unknown`, plus `evaluated`. A missing config file no longer stops the check: authentication is still evaluated, nobody is enrolled, and the result says so. A config file that exists but will not parse is a hard error
9. **Read `evaluated` before trusting a verdict** — `unknown` with `evaluated: false` means the DKIM/SPF checks never ran (no headers, no trusted `authserv-id`), which is a different situation from running them and being unsure. Treating the first as the second means acting on a check that did not happen
10. **Use `senderAddress` for decisions, `sender` for display** — `sender` joins the display name and the address into one string, and the display name is chosen by the sender. `messages`, `search`, and `get` all return `senderAddress`/`senderName` separately (`get` adds `replyToAddress`/`replyToName`); route, filter, and match on the address

### Error Handling
1. **Check authorization first** with `apple-pim` action `status` when encountering errors
2. **Use `apple-pim` action `authorize`** to request access for `notDetermined` domains
3. **Guide users to System Settings** for `denied` domains
4. **Validate dates** before creating events/reminders
5. **Check for conflicts** when scheduling
6. **Provide clear feedback** on operation success/failure

## Common Patterns

### Date Parsing
Support flexible input:
- ISO 8601: `2024-01-15T14:30:00`
- Natural language: "tomorrow at 3pm"
- Relative: "in 2 hours", "next Tuesday"

### Time Zone Handling
- EventKit stores dates in UTC. Every calendar event also carries `localStart`/`localEnd`
- **Reason and group by `localStart`/`localEnd`, never by `startDate`/`endDate`.** Past a
  cutoff in the day the two name a different *calendar day*, and grouping by the UTC field
  shifts those events one day forward — the most common way a calendar answer goes wrong
  while looking entirely reasonable
- The cutoff is wherever local time reaches 24:00 minus the UTC offset: **5:00 PM during PDT**
  (UTC-7), 4:00 PM during PST (UTC-8), and different again in another zone. It is not
  "evening" as a category — a 4:00 PM PDT event and its `startDate` agree on the day
- The same instant, both ways:
  ```
  localStart = 2026-03-31 7:00 PM     <- the day this event belongs to
  startDate  = 2026-04-01T02:00:00Z   <- same moment, next calendar day
  ```
  An availability answer built on `startDate` calls March 31 free and April 1 busy. Both are
  wrong, and nothing in the output looks off
- Partial correctness is what makes this survive. Every morning and afternoon event has
  matching dates, so spot-checking one confirms the wrong habit; only the late-day events are
  misfiled, and those are exactly the ones an evening-availability question is about
- The trap is worst when the date is *incidental* to the question. Answering "is April 1
  free?" invites a careful check; answering "which evenings in April are free?" invites
  grouping in bulk, which is exactly where the UTC field slips in
- Requesting `start`/`startDate` via `fields` auto-includes `localStart` for this reason.
  Do not strip it back out
- Display in the local time zone and name the zone in user output

### Searching
- Name search: `CNContact.predicateForContacts(matchingName:)`
- ID lookup: `CNContact.predicateForContacts(withIdentifiers:)`
- Date range: `eventStore.predicateForEvents(withStart:end:calendars:)`

## Troubleshooting

### Permission Issues
- Use `apple-pim` with action `status` to check all domains at once
- Use `apple-pim` with action `authorize` to trigger permission prompts
- Check System Settings > Privacy & Security
- Terminal/app must be granted access
- Restart app after granting permission

### Configuration Issues
- **Unexpected filtering**: Use `apple-pim` with action `config_show` to verify the active config. Check if an unexpected profile is being applied via `APPLE_PIM_PROFILE` env var.
- **Missing calendars/lists**: Use `apple-pim` with action `config_init` to see all available calendars/lists from macOS, then compare with action `config_show` to see what's being filtered.
- **Profile not applying**: Check profile selection priority: `--profile` flag > `APPLE_PIM_PROFILE` env var > base config. Profile files must be at `~/.config/apple-pim/profiles/{name}.json`.
- **Malformed config**: If `config.json` has invalid JSON, CLIs fall back to default behavior (all domains enabled, no filtering). Use `apple-pim` with action `config_show` to verify — it reports the config path and whether it was loaded successfully.

### Missing Data
- Ensure keys are requested when fetching contacts
- Check calendar source/account sync status
- Verify iCloud sync is working

### Performance
- Limit date ranges for event queries
- Use predicates to filter server-side
- Fetch only needed contact keys
- Use batch operations for multi-item actions
