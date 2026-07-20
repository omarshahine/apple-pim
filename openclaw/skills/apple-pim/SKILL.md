---
name: apple-pim
description: Native macOS personal information management for calendars, reminders, contacts, and local Mail.app. Use when the user wants to schedule meetings, create events, check their calendar, create or complete reminders, look up contacts, find someone's phone number or email, manage tasks and to-do lists, triage local Mail.app messages, or troubleshoot EventKit, Contacts, or Mail.app permissions on macOS.
---

# Apple PIM: Personal Information Manager (EventKit, Contacts & Mail)

## Requirements

- **macOS only.** Requires Apple frameworks (EventKit, Contacts, Mail.app) — does not run on Linux or Windows.
- **Native CLIs**: `calendar-cli`, `reminder-cli`, `contacts-cli`, `mail-cli`. Build locally from source via `./setup.sh` (Swift toolchain required); installs to `~/.local/bin/`. Authoritative declaration is in the plugin manifest under `requires.binaries` and `platforms`.
- **TCC permissions** for Calendars, Reminders, Contacts (via Privacy & Security). Mail features additionally require Mail.app running and Automation permission granted to your terminal/IDE.

## Overview

Apple provides frameworks and scripting interfaces for personal information management:
- **EventKit**: Calendars and Reminders
- **Contacts**: Address book management
- **Mail.app**: Local email — reads via direct SQLite (Envelope Index, milliseconds), mutations via JXA

EventKit and Contacts require explicit user permission via privacy prompts. Mail.app requires Automation permission and must be running.

## Tools

This plugin provides 5 tools:

| Tool | Actions | Domain |
|------|---------|--------|
| `apple_pim_calendar` | `list`, `events`, `get`, `search`, `create`, `update`, `delete`, `batch_create` | Calendar events via EventKit |
| `apple_pim_reminder` | `lists`, `items`, `get`, `search`, `create`, `complete`, `update`, `delete`, `batch_create`, `batch_complete`, `batch_delete` | Reminders via EventKit |
| `apple_pim_contact` | `groups`, `list`, `search`, `get`, `create`, `update`, `delete` | Contacts framework |
| `apple_pim_mail` | `accounts`, `mailboxes`, `messages`, `get`, `search`, `send`, `reply`, `update`, `move`, `delete`, `batch_update`, `batch_delete`, `auth_check` | Mail.app via JXA/AppleScript |
| `apple_pim_system` | `status`, `authorize`, `config_show`, `config_init` | Authorization & configuration |

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
| `notDetermined` | Never requested | Use `apple_pim_system` with action `authorize` to trigger prompt |
| `authorized` | Full access granted | Ready to use |
| `denied` | User refused access | Must enable in System Settings manually |
| `restricted` | System policy (MDM, parental) | Cannot override |
| `writeOnly` | Limited write access (macOS 17+) | Upgrade to Full Access in Settings |

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
  "contacts": { "enabled": true },
  "mail": { "enabled": true }
}
```

### Filter Modes

| Mode | Behavior |
|------|----------|
| `all` | No filtering — all calendars/lists are visible (default) |
| `allowlist` | Only calendars/lists named in `items` are visible |
| `blocklist` | All calendars/lists are visible EXCEPT those named in `items` |

### Multi-Agent Isolation

All 5 tools accept optional `configDir` and `profile` parameters for per-call workspace isolation:

```
apple_pim_calendar({ action: "list", configDir: "~/agents/travel/apple-pim" })
apple_pim_calendar({ action: "list", profile: "work" })
```

In OpenClaw multi-agent setups (v3.1.0+), config is auto-discovered from `{workspaceDir}/apple-pim/config.json` — no explicit `configDir` or wrapper scripts needed.

**Priority chain**: Tool parameter > workspace convention > plugin config > env var > default (`~/.config/apple-pim/`)

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

Override path with `trustedSenders` parameter: `apple_pim_mail({ action: "auth_check", id: "<msg-id>", trustedSenders: "~/custom/senders.json" })`

## Best Practices

### Calendar Management
1. **Use default calendar for new events** when user doesn't specify
2. **Preserve recurrence rules** when updating recurring events
3. **Handle `.thisEvent` vs `.futureEvents`** span for recurring event edits
4. **Use `batch_create`** when creating multiple events for efficiency

### EKSpan for Recurring Events

| Span | Effect | When to Use |
|------|--------|-------------|
| `.thisEvent` | Affects only the single occurrence | Default for delete and update |
| `.futureEvents` | Affects this and all future occurrences | Use when ending a series |

- **Delete**: Default is `.thisEvent`. Pass `futureEvents: true` to use `.futureEvents`.
- **Update**: Default is `.thisEvent`. Pass `futureEvents: true` to apply to future occurrences.
- **Remove recurrence**: Pass `recurrence: { frequency: "none" }` with `futureEvents: true`.

### Reminder Management
1. **Default to incomplete reminders** when listing
2. **Use filters**: `overdue` for urgent, `today` for daily planning, `week` for review
3. **Use batch operations** (`batch_complete`, `batch_delete`) for multiple items

### Contact Management
1. **Preserve existing data** when updating (only modify changed fields)
2. **Handle labeled values carefully** — don't lose non-primary entries

### Mail Management
1. **Mail.app must be running** for mutations, sends, and `content` search (reads use the direct SQLite path and work with Mail.app closed when Full Disk Access is granted)
2. **Use batch operations** (`batch_update`, `batch_delete`) for inbox triage
3. **Message IDs are RFC 2822** — stable across mailbox moves
4. **Use mailbox/account hints** for faster lookups
5. **Send** uses AppleScript — supports `to`, `cc`, `bcc`, `from` (account selection), `subject`, `body`
6. **Reply** preserves threading — looks up message by RFC 2822 ID, then uses Mail.app's `reply` verb
7. **Auth check** verifies DKIM/SPF against `~/.config/apple-pim/trusted-senders.json` — returns `verified`, `suspicious`, `untrusted`, or `unknown`

### Attachment Policy (Send / Reply)

File attachments are **disabled by default** to prevent local-file exfiltration via prompt-injection. Any `attachment` argument passed to `send` or `reply` will be rejected unless the user has opted in.

**To enable**, create `~/.config/apple-pim/mail-attachments.json`:

```json
{
  "enabled": true,
  "allowedRoots": ["~/Downloads", "~/Documents/agent-attachments"]
}
```

Even when enabled, the following are **always refused**:

- Path components matching `.ssh`, `.aws`, `.gnupg`, `.kube`, `.docker`, `.secrets`, `Keychains`
- Filenames `id_rsa`, `id_ed25519`, `.netrc`, `.pgpass`, `.env`, `authorized_keys`, etc.
- Filenames matching `*.pem`, `*.key`, `*.p12`, `*.pfx`, or containing `secret`, `password`, `credential`, `token`

Paths are normalized via `realpath` before checking, so symlinks and `..` traversal can't escape the allowlist. Override the policy file location with `APPLE_PIM_MAIL_ATTACHMENTS_CONFIG`.

### Error Handling
1. **Check authorization first** with `apple_pim_system` action `status`
2. **Use `apple_pim_system` action `authorize`** for `notDetermined` domains
3. **Guide users to System Settings** for `denied` domains

## Troubleshooting

### Permission Issues
- Use `apple_pim_system` with action `status` to check all domains
- Use `apple_pim_system` with action `authorize` to trigger prompts
- Check System Settings > Privacy & Security

### Binary Not Found
- Run `./setup.sh --install` to build and install CLIs to `~/.local/bin/`
- Or set `binDir` in plugin config to point to your build directory

### Configuration Issues
- **Unexpected filtering**: Use `apple_pim_system` action `config_show` to verify active config
- **Missing calendars/lists**: Use `apple_pim_system` action `config_init` to discover available items
