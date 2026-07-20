# Apple PIM: Calendar, Reminders, Contacts, Mail

*PIM = Personal Information Manager.*

[![GitHub](https://img.shields.io/github/v/release/omarshahine/apple-pim)](https://github.com/omarshahine/apple-pim)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://github.com/omarshahine/apple-pim/blob/main/LICENSE)

**GitHub**: [github.com/omarshahine/apple-pim](https://github.com/omarshahine/apple-pim)

Native macOS integration for Calendar, Reminders, Contacts, and Mail using EventKit, Contacts, SQLite, and JXA frameworks. Works with **Claude Code** (via MCP) and **OpenClaw** (via native tool registration).

## Features

- **Calendar Management**: List calendars, create/read/update/delete events, search by date/title, attendee support (add/replace attendees via CalDAV invitation emails)
- **Reminder Management**: List reminder lists, create/complete/update/delete reminders, search
- **Contact Management**: List groups, create/read/update/delete contacts, search by name/email/phone, birthday support (with or without year)
- **Mail Integration**: List accounts/mailboxes, read/search/send/reply/move/delete messages, update flags, attachment support (metadata, save-to-disk, send/reply with attachments), verify sender authentication
- **Fast Local Mail Reads**: Read commands query Apple Mail's local Envelope Index (SQLite) directly — 10–200× faster than AppleScript automation, and they work even when Mail.app is closed. Automatic fallback to JXA when Full Disk Access isn't granted. See [Direct SQLite read path](#direct-sqlite-read-path---engine-sqlite)
- **Recurrence Rules**: Create recurring events and reminders (daily, weekly, monthly, yearly)
- **Batch Operations**: Create multiple events or reminders in a single efficient transaction
- **Per-Domain Control**: Enable or disable entire domains (calendars, reminders, contacts, mail) independently
- **Multi-Agent Isolation**: Per-call config/profile overrides for workspace isolation
- **Works with Claude Code and OpenClaw**: Same Swift CLIs, different integration layers

## Prerequisites

- macOS 13.0 or later
- Swift 5.9 or later (comes with Xcode 15+)
- Node.js 18+ (for MCP server or OpenClaw plugin)
- **Mail.app** must be running for mail mutations, sends, and content search (it is not launched automatically). Mail *reads* use the local SQLite index and work with Mail.app closed.

## Installation

### Swift CLI Tools (Required for both platforms)

```bash
# Build the Swift CLIs
./setup.sh

# Optional: install to PATH for system-wide access
./setup.sh --install

# Add to your shell profile (if not already there)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

The `--install` flag **copies** the binaries into `~/.local/bin/`, so the
install keeps working even if you later move, rename, or clean this
checkout. After a rebuild, re-run `./setup.sh --install` to refresh them.

Developing the CLIs themselves? `./setup.sh --install --link` symlinks
instead, so every `swift build -c release` updates the installed commands
in place — at the cost that moving or renaming the repo breaks the links.

Verify any install with:

```bash
scripts/doctor.sh        # add --fix to reap a stuck helper process
```

### Claude Code Plugin

Inside Claude Code, run:

```
/plugin marketplace add omarshahine/apple-pim
/plugin install apple-pim@apple-pim
```

Then build the Swift CLIs (once, from a shell — the glob tolerates any
marketplace name and version):

```bash
bash ~/.claude/plugins/cache/*/apple-pim/*/setup.sh --install
```

Restart Claude Code to load the MCP server. The `pim-assistant` agent triggers automatically when you mention scheduling, reminders, contacts, or email.

### OpenClaw Plugin

```bash
# Install from ClawHub
openclaw plugins install apple-pim-cli

# Or install from npm
npm install -g apple-pim-cli
```

Under the hood, the plugin spawns native macOS Swift binaries (calendar-cli, reminder-cli, contacts-cli, mail-cli) that interact with EventKit, Contacts, and Mail.app via Apple's frameworks.

**Prerequisites**: Swift CLIs must be on PATH (run `./setup.sh --install` first).

Optionally, configure the binary location if the CLIs are not on PATH:

```bash
# In your OpenClaw config:
# plugins.entries.apple-pim-cli.config.binDir = "/path/to/swift/.build/release"
```

### Post-Installation (both platforms)

**Grant permissions**: On first use, macOS will prompt for Calendar, Reminders, and Contacts access. Grant these permissions in System Settings > Privacy & Security.

**Mail.app Automation**: For mail features, you also need to grant Automation permission:
- System Settings > Privacy & Security > Automation
- Allow Terminal (or your IDE) to control **Mail.app**

**Full Disk Access (optional, recommended)**: Mail *read* commands use a fast
direct-SQLite path (see "Direct SQLite read path" below) that requires Full
Disk Access for Terminal (or the MCP host). Without it, reads silently fall
back to the slower Mail.app Automation path.

### Development Installation

```bash
git clone https://github.com/omarshahine/apple-pim.git
cd apple-pim
./setup.sh
```

Then inside Claude Code, add the local checkout as a marketplace:

```
/plugin marketplace add /absolute/path/to/apple-pim
/plugin install apple-pim@apple-pim
```

For OpenClaw (loads TypeScript directly, no build step):

```bash
openclaw plugins install -l ./openclaw
```

## Configuration

The plugin includes a full access control system (PIMConfig) that lets you restrict which calendars, reminder lists, and domains each agent can see. This is useful for:
- **Access control** — allowlist or blocklist specific calendars and reminder lists
- **Privacy** — hide calendars you don't need the agent to see
- **Reducing noise** — only show relevant reminder lists
- **Avoiding conflicts** — disable mail here if you use a separate email MCP
- **Multi-agent setups** — give each agent a profile with different access
- **Read-only calendars** — let agents see but not modify certain calendars

### Interactive Setup (Claude Code)

```
/apple-pim:configure
```

### CLI Config Commands

```bash
# Show current effective configuration
calendar-cli config show
reminder-cli config show

# Initialize config from available calendars/lists
calendar-cli config init
reminder-cli config init
```

### Manual Configuration

Config files are stored at `~/.config/apple-pim/`:

```
~/.config/apple-pim/
├── config.json              # Base configuration
└── profiles/
    ├── work.json            # Work agent profile
    └── personal.json        # Personal agent profile
```

**Base config** (`~/.config/apple-pim/config.json`):

```json
{
  "calendars": {
    "enabled": true,
    "mode": "allowlist",
    "items": ["Personal", "Work"]
  },
  "reminders": {
    "enabled": true,
    "mode": "allowlist",
    "items": ["Reminders", "Shopping"]
  },
  "contacts": {
    "enabled": true,
    "mode": "all",
    "items": []
  },
  "mail": {
    "enabled": true
  },
  "default_calendar": "Personal",
  "default_reminder_list": "Reminders"
}
```

### Configuration Options

| Option | Values | Description |
|--------|--------|-------------|
| `enabled` | `true`, `false` | Enable or disable an entire domain |
| `mode` | `allowlist`, `blocklist`, `all` | How to filter items (calendars/reminders/contacts) |
| `items` | List of names | Calendar/list names to allow or block (emoji prefixes are matched fuzzy) |
| `default_calendar` | Calendar name | Where new events are created when no calendar is specified |
| `default_reminder_list` | List name | Where new reminders are created when no list is specified |

### Filter Modes

- **allowlist**: Only listed items are accessible
- **blocklist**: All EXCEPT listed items are accessible
- **all**: No filtering (default if no config file exists)

Filtering applies per domain: calendars filter by calendar name, reminders by list name, contacts by account container name (e.g. "iCloud", "Work Exchange", "Personal Gmail"). Use `contacts-cli containers` to see available account names.

### Profiles

Profiles let you give different agents different access to your PIM data. Each profile overrides specific domain sections from the base config — fields not in the profile are inherited from the base.

**Profile selection** (in priority order):
1. `--profile work` CLI flag (on the subcommand)
2. `APPLE_PIM_PROFILE=work` environment variable
3. Tool parameter `profile: "work"` (OpenClaw only)
4. No profile — base config only

**Example profile** (`~/.config/apple-pim/profiles/work.json`):

```json
{
  "calendars": {
    "enabled": true,
    "mode": "allowlist",
    "items": ["Work"]
  },
  "contacts": {
    "enabled": true,
    "mode": "allowlist",
    "items": ["Work Exchange"]
  },
  "mail": {
    "enabled": false
  },
  "default_calendar": "Work"
}
```

### Domain Enable/Disable

Set `enabled: false` on any domain to disable it. When disabled, CLI commands for that domain return an access denied error.

### Sender Authentication (mail auth-check)

The `auth_check` action verifies email sender identity by parsing DKIM and SPF results from `Authentication-Results` headers and cross-referencing against a trusted senders list.

**Config file**: `~/.config/apple-pim/trusted-senders.json`

```json
{
  "version": 1,
  "trustedSenders": [
    {
      "name": "Alice",
      "emails": ["alice@example.com"],
      "expectedDkimDomains": ["example.com", "messagingengine.com"],
      "requireDkim": true,
      "requireSpf": true
    },
    {
      "name": "Bob (relaxed SPF)",
      "emails": ["bob@company.com"],
      "expectedDkimDomains": ["company.com"],
      "requireDkim": true,
      "requireSpf": false
    }
  ]
}
```

**Fields per sender:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | required | Display name for the verdict |
| `emails` | string[] | required | Email addresses to match (case-insensitive) |
| `expectedDkimDomains` | string[] | `[]` | DKIM signing domains to accept (matches exact or subdomain) |
| `requireDkim` | boolean | `true` | Require DKIM pass + domain match for "verified" verdict |
| `requireSpf` | boolean | `true` | Require SPF pass for "verified" verdict |

**Verdicts:**

| Verdict | Meaning |
|---------|---------|
| `verified` | DKIM and SPF checks pass per sender config |
| `suspicious` | Sender is trusted but authentication failed or domain mismatch |
| `untrusted` | Sender email not found in trusted-senders.json |
| `unknown` | Cannot determine (missing headers, parse failure, no config file) |

**Usage:**

```bash
# CLI
mail-cli auth-check --id "<message-id@example.com>"
mail-cli auth-check --id "<message-id>" --trusted-senders ~/custom/senders.json

# MCP tool
mcp__plugin_apple-pim_apple-pim__mail({ action: "auth_check", id: "<message-id>" })

# OpenClaw tool
apple_pim_mail({ action: "auth_check", id: "<message-id>" })
```

The `--trusted-senders` flag overrides the default config path. If the file doesn't exist, the verdict is `unknown` with a warning.

### Date Output Format

Set `APPLE_PIM_DATE_FORMAT` to control how CalendarCLI formats dates in JSON output. This helps LLM agents avoid wasting tokens computing day-of-week from raw ISO dates.

| Preset | Example |
|--------|---------|
| `utc` (default) | `2026-03-20T14:00:00Z` |
| `local` | `2026-03-20T07:00:00-07:00` |
| `day-utc` | `Friday, 2026-03-20T14:00:00Z` |
| `day-local` | `Friday, 2026-03-20T07:00:00-07:00` |

```bash
# Set in your shell profile or agent environment
export APPLE_PIM_DATE_FORMAT=day-local
```

No env var = `utc` (current behavior, fully backwards compatible). CalendarCLI only; ReminderCLI uses a different date codepath.

### Notes

- Config is read fresh on each CLI invocation — changes take effect immediately
- No config file = all domains enabled, all items accessible (backwards compatible)
- Write operations to blocked calendars/lists fail with a descriptive error message
- Profile names are validated — path traversal attempts are rejected

## Multi-Agent Setup

When running multiple agents, each can have its own profile or config directory for isolated PIM access. See [docs/multi-agent-setup.md](docs/multi-agent-setup.md) for the full guide.

**Quick start**: Create profiles in `~/.config/apple-pim/profiles/` and assign them per agent:

```bash
# Environment variable
APPLE_PIM_PROFILE=travel

# OpenClaw tool parameter (per-call isolation)
apple_pim_calendar({ action: "list", profile: "travel" })
apple_pim_calendar({ action: "list", configDir: "~/agents/travel/apple-pim" })
```

## Usage

### Claude Code Commands

```
/apple-pim:calendars list                    # List all calendars
/apple-pim:calendars events                  # Events for next 7 days
/apple-pim:calendars search "team meeting"
/apple-pim:reminders lists                   # List all reminder lists
/apple-pim:reminders items --filter overdue
/apple-pim:contacts search "John"
/apple-pim:mail messages --filter unread
```

Natural language works via the `pim-assistant` agent:
- "What's on my calendar tomorrow?"
- "Remind me to call the dentist"
- "What's John's email address?"

### OpenClaw Tools

| Tool | Example |
|------|---------|
| `apple_pim_calendar` | `apple_pim_calendar({ action: "events", nextDays: 7 })` |
| `apple_pim_reminder` | `apple_pim_reminder({ action: "items", filter: "today" })` |
| `apple_pim_contact` | `apple_pim_contact({ action: "search", query: "John" })` |
| `apple_pim_mail` | `apple_pim_mail({ action: "messages", filter: "unread" })` |
| `apple_pim_system` | `apple_pim_system({ action: "status" })` |

### Direct CLI

```bash
calendar-cli list
calendar-cli events --from today --to tomorrow
calendar-cli create --title "Lunch" --start "tomorrow 12pm" --duration 60
reminder-cli lists
reminder-cli items --list "Personal" --filter overdue
contacts-cli containers                             # List contact account containers
contacts-cli search "John"
contacts-cli search "John" --profile work           # Scoped to work contacts only
mail-cli messages --mailbox INBOX --limit 10
mail-cli send --to "user@example.com" --subject "Hello" --body "Message"
mail-cli send --to "user@example.com" --subject "Report" --body "See attached" --attachment ~/report.pdf
mail-cli reply --id "<message-id>" --body "Thanks!"
mail-cli save-attachment --id "<message-id>" --dest-dir ~/Downloads
mail-cli auth-check --id "<message-id>"

# Native SMTP send (no Mail.app — see "Direct SMTP path" below)
mail-cli secrets set smtp.icloud.password
mail-cli smtp-send --to "user@example.com" --subject "Hello" \
  --from "me@icloud.com" --html-file ./body.html

calendar-cli create --title "Meeting" --start "tomorrow 2pm" --attendees '[{"email":"a@example.com"}]'
```

### Direct SQLite read path (`--engine sqlite`)

Read commands (`accounts`, `mailboxes`, `messages`, `get`, `search`) default to
`--engine auto`: they read Apple Mail's local **Envelope Index** SQLite database
(`~/Library/Mail/V*/MailData/Envelope Index`) directly, falling back to JXA if
the database isn't readable. Message bodies come straight from the on-disk
`.emlx` files. This is ~10–200× faster than the JXA path (subject search across
an 80k-message mailbox: **~80ms vs ~15s**) and works even when Mail.app is not
running. Mutations (`update`, `move`, `delete`, `send`, `reply`) always go
through Mail.app.

- The database is only ever opened **read-only** (`SQLITE_OPEN_READONLY` +
  `PRAGMA query_only`); the fast path never writes to Mail's data.
- Requires **Full Disk Access** for the invoking process (Terminal or the MCP
  host). Without it, `--engine auto` silently uses JXA — check
  `mail-cli auth-status` (`envelopeIndex.readable`) to see which path you get.
- `--field content` search is not indexed locally and always uses JXA.
- Force a specific path with `--engine sqlite` or `--engine jxa`; responses
  from the fast path include `"engine": "sqlite"`.

### Direct SMTP path (`mail-cli smtp-send`)

`mail-cli send` composes through **Mail.app** via JXA — which means the outgoing
message shows up in Mail.app's Sent folder, uses your configured accounts, and
inherits the system's send pipeline. Good default, but it has two real
limitations: it requires Mail.app to be running, and Mail 16 on iCloud-type
accounts silently drops AppleScript's `html content` property
([FB11734014](https://developer.apple.com/forums/thread/738842)) so HTML
sends arrive as empty plain text.

`mail-cli smtp-send` is the native Swift alternative: hand-rolled SMTP state
machine with a `multipart/alternative` MIME builder. No Mail.app dependency,
no third-party Swift deps. Two TLS transports:

- **Implicit TLS (default)** — `NWConnection` + `NWProtocolTLS` on port 465
  (iCloud, Gmail, Fastmail, most modern hosts).
- **STARTTLS** — `--tls-mode starttls` (defaults to port 587) for corporate
  Exchange, self-hosted Postfix, and university/ISP relays that only expose
  587. Backed by a POSIX socket upgraded to TLS via Secure Transport, since
  `NWConnection` can't upgrade plaintext → TLS in place.

When the HTML body is supplied without `--body`, a plain-text fallback is
auto-derived from the HTML so the message is always `multipart/alternative`
(better for screen readers, notification previews, and spam scoring).

**Setup (one-time):**

```bash
# Store an app-specific password (interactive, no echo).
# Apple ID → Sign-In and Security → App-Specific Passwords → Generate.
mail-cli secrets set smtp.icloud.password

# Or read from ~/.openclaw/secrets.json if the OpenClaw store exists.
# Password resolution: $SMTP_ICLOUD_PASSWORD → ~/.openclaw/secrets.json → ~/.config/apple-pim/secrets.json

# Set connection defaults so you don't pass --from on every call (optional):
mail-cli config set-smtp --username "me@icloud.com"  # if/when the config command is added
# Until then, pass --from explicitly or put `smtp.username` in ~/.config/apple-pim/config.json.
```

**Send:**

```bash
# Dry run — prints rendered RFC 5322 bytes and exits 0:
mail-cli smtp-send --dry-run --to you@example.com --from me@icloud.com \
  --subject "Dry run" --body "hello"

# Real send with HTML body and plain-text fallback:
mail-cli smtp-send --to you@example.com --from me@icloud.com \
  --subject "Digest" --html-file ./body.html --body "Plain fallback"

# With attachment:
mail-cli smtp-send --to you@example.com --from me@icloud.com \
  --subject "Report" --html-file ./body.html --attachment ~/report.pdf

# STARTTLS relay on port 587 (corporate Exchange / Postfix):
mail-cli smtp-send --tls-mode starttls --host smtp.work.example --port 587 \
  --to you@example.com --from me@work.example --subject "Hi" --body "hello"

# Also APPEND the message to the IMAP Sent folder (default-on for iCloud):
mail-cli smtp-send --imap-append-sent --to you@example.com --from me@icloud.com \
  --subject "Archived in Sent" --body "hi"

# Verbose mode logs the SMTP conversation to stderr (password redacted):
mail-cli smtp-send --verbose --to you@example.com --from me@icloud.com \
  --subject "Debug" --body "hi"
```

**STARTTLS, Sent-folder, and HTML fallback options:**

| Flag | Effect |
|---|---|
| `--tls-mode implicit\|starttls` | TLS transport. `implicit` (default) = port 465; `starttls` = port 587. Also settable via `smtp.tls_mode` in config. |
| `--tls-insecure-skip-verify` | Skip TLS cert verification (STARTTLS only; for self-signed test servers). |
| `--imap-append-sent` / `--no-imap-append-sent` | APPEND the sent message to the IMAP Sent folder so it appears in Mail.app/iCloud. Defaults **on** for iCloud SMTP (`*.mail.me.com`), **off** otherwise. Configure non-iCloud servers via the `imap` config block. |

**IMAP Sent-folder config** (`~/.config/apple-pim/config.json`) — only needed for non-iCloud, or to override defaults:

```json
{
  "imap": {
    "host": "imap.mail.me.com",
    "port": 993,
    "sent_folder": "Sent Messages",
    "username": "me@icloud.com",
    "secret_key": "imap.icloud.password",
    "append_sent": true
  }
}
```

Folder names differ by provider: iCloud `"Sent Messages"`, Gmail `"[Gmail]/Sent Mail"`, generic `"Sent"`. If `imap.secret_key` is omitted, the SMTP password is reused (iCloud uses the same app-specific password for both). APPEND failures are **non-fatal** — the message was already delivered by SMTP, so the failure surfaces as a warning plus an `"imap_append": {"success": false, ...}` field in the JSON result.

**Secrets management:**

```bash
mail-cli secrets set   smtp.icloud.password          # prompt silently
mail-cli secrets get   smtp.icloud.password          # print (for scripts)
mail-cli secrets list                                # keys only, never values
mail-cli secrets unset smtp.icloud.password

# Force the OpenClaw-shared store instead of the standalone one:
mail-cli secrets set smtp.icloud.password --store openclaw
```

#### Known Limitations

| Limitation | Detail |
|---|---|
| **Sent-folder APPEND is opt-in for non-iCloud** | `--imap-append-sent` APPENDs to the IMAP Sent folder (default-on for iCloud). For other providers you must configure the `imap` block. Without it, the message won't appear in Mail.app's Sent view and a stderr note is emitted. |
| **AUTH LOGIN only** | AUTH PLAIN / CRAM-MD5 / OAUTHBEARER not implemented. Sufficient for iCloud app-specific passwords. |
| **App-specific password required for iCloud** | The regular Apple ID password will return `535 5.7.8 Authentication failed`. Generate one at [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords. |
| **`--from` must match the authenticated account** | iCloud (and most relays) will silently rewrite or reject messages whose `From:` doesn't match the authenticating user. |

## Tools Reference

5 domain-level tools, each with an `action` parameter:

| Tool | Actions | Domain |
|------|---------|--------|
| `calendar` / `apple_pim_calendar` | `list`, `events`, `get`, `search`, `create`, `update`, `delete`, `batch_create` | Calendar events via EventKit |
| `reminder` / `apple_pim_reminder` | `lists`, `items`, `get`, `search`, `create`, `complete`, `update`, `delete`, `batch_create`, `batch_complete`, `batch_delete` | Reminders via EventKit |
| `contact` / `apple_pim_contact` | `containers`, `groups`, `list`, `search`, `get`, `create`, `update`, `delete` | Contacts framework |
| `mail` / `apple_pim_mail` | `accounts`, `mailboxes`, `messages`, `get`, `search`, `send`, `reply`, `save_attachment`, `update`, `move`, `delete`, `batch_update`, `batch_delete`, `auth_check` | Mail.app via JXA/AppleScript |
| `apple-pim` / `apple_pim_system` | `status`, `authorize`, `config_show`, `config_init` | Authorization & configuration |

### Recurrence Rules

```json
{
  "frequency": "weekly",
  "interval": 1,
  "daysOfTheWeek": ["monday", "wednesday", "friday"],
  "endDate": "2025-12-31"
}
```

**Supported frequencies**: `daily`, `weekly`, `monthly`, `yearly`

### Batch Operations

```json
{
  "events": [
    {"title": "Standup", "start": "2025-01-27 09:00"},
    {"title": "Team Sync", "start": "2025-01-27 14:00"}
  ]
}
```

## Architecture

The shared `lib/` layer contains all handler logic, schemas, and sanitization. Both the MCP server and OpenClaw plugin are thin adapters over this shared code.

```
Claude Code  <--MCP-->  mcp-server/server.js  ---+
                                                  |
OpenClaw  <--tools-->  openclaw/src/index.ts  ----+--> lib/ (shared handlers, schemas, sanitize)
                                                  |
Direct CLI  <--shell-->  --------------------------+--> Swift CLIs (EventKit / Contacts / JXA)
                                                            |
                                                       PIMConfig
                                                  (~/.config/apple-pim/)
```

### Directory Structure

```
apple-pim/
├── lib/                      # Shared handler logic (used by MCP + OpenClaw)
│   ├── cli-runner.js         # CLI spawn + binary discovery
│   ├── schemas.js            # Tool JSON Schemas
│   ├── sanitize.js           # Datamarking for prompt injection defense
│   ├── mail-format.js        # Email markdown formatting
│   ├── tool-args.js          # CLI argument builders
│   └── handlers/
│       ├── calendar.js       # handleCalendar()
│       ├── reminder.js       # handleReminder()
│       ├── contact.js        # handleContact()
│       ├── mail.js           # handleMail()
│       └── apple-pim.js      # handleApplePim()
├── swift/                    # Native Swift CLI tools
│   ├── Sources/
│   │   ├── PIMConfig/        # Shared config library
│   │   ├── CalendarCLI/      # EventKit calendar operations
│   │   ├── ReminderCLI/      # EventKit reminder operations
│   │   ├── ContactsCLI/      # Contacts framework operations
│   │   └── MailCLI/          # Mail.app via JXA
│   └── Tests/
├── mcp-server/               # Claude Code MCP adapter
│   ├── server.js             # MCP tool registration (imports lib/)
│   ├── build.mjs             # esbuild config
│   └── dist/server.js        # Bundled artifact
├── openclaw/                 # OpenClaw plugin package (NPM: apple-pim-cli)
│   ├── src/index.ts          # Tool registration with per-call isolation
│   ├── openclaw.plugin.json  # Plugin manifest + config schema
│   ├── lib -> ../lib         # Symlink to shared code
│   └── skills/apple-pim/     # OpenClaw skill knowledge
├── evals/                    # Agent eval framework (137 tests)
│   ├── helpers/              # Mock CLI, scenario runner, grading
│   ├── fixtures/             # Canned CLI JSON responses
│   ├── scenarios/            # YAML eval case definitions
│   └── tests/                # Vitest test files (4 categories)
├── commands/                 # Claude Code slash commands
├── agents/                   # pim-assistant agent
├── skills/                   # Claude Code skill knowledge
├── docs/                     # Documentation
│   └── multi-agent-setup.md  # Multi-agent isolation guide
└── setup.sh                  # Build + install script
```

## Troubleshooting

### Permission Denied

Check System Settings > Privacy & Security:
- **Calendars**: Ensure Terminal/Claude Code has access
- **Reminders**: Ensure Terminal/Claude Code has access
- **Contacts**: Ensure Terminal/Claude Code has access

You may need to restart your app after granting permissions.

### Mail.app Issues

- **Mail.app must be running** — the plugin does not launch it automatically
- **Automation permission** — System Settings > Privacy & Security > Automation: allow Terminal to control Mail.app
- **30-second timeout** — JXA scripts have a 30-second timeout. Use `--limit` to reduce result count. For search, use `--since` to narrow by date (recommended for large mailboxes)
- **Message IDs** — Mail tools use RFC 2822 `messageId` (stable across moves). Pass `--mailbox` and `--account` hints for faster lookups

### CLI Not Found

```bash
# Build and install to PATH
./setup.sh --install

# Verify
which calendar-cli
calendar-cli list
```

### MCP Server Not Connecting (Claude Code)

1. Ensure you ran `./setup.sh` to install npm dependencies
2. Check `/mcp` in Claude Code to see server status
3. Restart Claude Code after installing the plugin

### OpenClaw Tools Not Registering

1. Verify CLIs are on PATH: `which calendar-cli`
2. Check `openclaw plugins list` for the plugin
3. If not on PATH, set `binDir` in plugin config

### Date Parsing Issues

The CLI accepts various date formats:
- ISO 8601: `2024-01-15T14:30:00`
- ISO 8601 with timezone offset: `2024-01-15T14:30:00-07:00`, `2024-01-15T14:30:00+05:30`
- Date/time: `2024-01-15 14:30`
- Date only: `2024-01-15`
- Natural language: `today`, `tomorrow`, `next week`, `in 2 hours`

Timezone offsets are preserved end-to-end through the CLI layer, so `2024-01-15T19:00:00-07:00` creates the event at the correct local time.

## Development

### Testing CLIs Directly

```bash
cd swift/.build/release

./calendar-cli list
./calendar-cli events --from today --to tomorrow
./reminder-cli lists
./reminder-cli items --list "Personal"
./contacts-cli search "John"
./mail-cli accounts
```

### Using Profiles

```bash
# CLI flag
calendar-cli list --profile work

# Environment variable
export APPLE_PIM_PROFILE=work
calendar-cli events --from today --to tomorrow

# View effective config
calendar-cli config show --profile travel
```

### Agent Evals

The eval framework tests how well the tool layer serves AI agents. The four core categories run against mock CLI fixtures with zero TCC permissions and no real macOS data. A separate model-in-the-loop suite (`calendar-reasoning`) exercises date/time reasoning with a real `claude -p` call graded by an LLM judge — it requires `ANTHROPIC_API_KEY` and is non-deterministic.

```bash
# Run all eval tests (mock + model-in-the-loop)
npm run eval

# Watch mode during development
npm run eval:watch
```

**Eval categories:**

| Category | Tests | What it verifies |
|----------|-------|------------------|
| Tool Call Correctness | 58 | CLI argument construction for every input variant |
| Response Interpretation | 22 | Verification visibility, datamarking, injection detection |
| Multi-turn Sequences | 8 | Correct tool call ordering for multi-step workflows |
| Safety Properties | 49 | Destructive warnings, ID validation, schema coverage |
| Calendar Reasoning (model) | 8 | Day-of-week math, cross-midnight events, query strategy (requires `ANTHROPIC_API_KEY`) |

To add new eval cases, edit YAML files in `evals/scenarios/` and add fixture JSON in `evals/fixtures/`. No test code changes needed.

### Rebuilding After Changes

```bash
# Swift CLIs
cd swift && swift build -c release

# MCP server bundle (after editing lib/ or mcp-server/)
cd mcp-server && npm run build

# OpenClaw loads .ts directly — no rebuild needed
```

## License

MIT
