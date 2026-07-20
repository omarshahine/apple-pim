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
      "requireDkim": true,
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
8. **Auth check** (`mail` with action `auth_check`) verifies DKIM/SPF against `~/.config/apple-pim/trusted-senders.json` — returns `verified`, `suspicious`, `untrusted`, or `unknown`

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
- EventKit stores dates in UTC
- Display in local time zone
- Be explicit about time zones in user output

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
