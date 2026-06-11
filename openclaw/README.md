# Apple PIM

OpenClaw plugin for native macOS Calendar, Reminders, Contacts, and Mail. It wraps four Swift CLIs (`calendar-cli`, `reminder-cli`, `contacts-cli`, `mail-cli`) built locally from EventKit, Contacts, and JXA. Once you approve the matching macOS permission prompts, the agent gets read/write access to all four domains, including mail send and delete.

**macOS only.** The registry downloads no binaries. You build the CLIs from source via `./setup.sh`.

## Install

1. Install the plugin from ClawHub (or `/plugin install apple-pim@apple-pim` in Claude Code).
2. Build the Swift CLIs from the plugin source:

   ```bash
   ./setup.sh --install
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
   source ~/.zshrc
   ```

3. Approve the macOS TCC and Automation prompts the first time each domain is used. For Mail, **Mail.app must be running** (it is not launched automatically).

Requires macOS 13+ and Swift 5.9+ (Xcode 15+).

## Tools

| Tool | Domain |
|------|--------|
| `apple_pim_calendar` | List, create, read, update, delete events; search by date/title; attendees; recurrence; batch create |
| `apple_pim_reminder` | List lists, create, complete, update, delete reminders; search; recurrence; batch create |
| `apple_pim_contact` | List groups, create, read, update, delete contacts; search by name/email/phone; birthdays |
| `apple_pim_mail` | List accounts/mailboxes, read, search, send, reply, move, delete; flags; attachments; verify sender auth |
| `apple_pim_system` | Permission status and diagnostics |

## Configuration

| Key | Description |
|-----|-------------|
| `binDir` | Directory containing the four CLIs. Auto-detected from PATH if unset (typically `~/.local/bin`). |
| `profile` | Config profile name for filtering calendars / lists / contacts. See `~/.config/apple-pim/profiles/`. |
| `configDir` | Override the PIM config root (default `~/.config/apple-pim/`). |
| `mailAttachmentsConfig` | Path to the mail attachment policy JSON. |

### Mail attachment safety

Mail send/reply attachments are **default-denied**. To allow them, point
`mailAttachmentsConfig` at a JSON file that opts in:

```json
{ "enabled": true, "allowedRoots": ["~/Downloads"] }
```

Even when enabled, sensitive paths (`~/.ssh`, `~/.aws`, etc.) and files like
`id_rsa`, `*.pem`, and `*secret*` are always refused.

## Notes

- **Per-call isolation**: `profile` and `configDir` can be overridden per call for multi-agent workspace isolation.
- **Per-domain control**: each domain (calendar, reminder, contact, mail) can be enabled or disabled independently.
- Same Swift CLIs power both the Claude Code plugin (via MCP) and this OpenClaw plugin (via native tool registration).

Full docs: [github.com/omarshahine/Apple-PIM-Agent-Plugin](https://github.com/omarshahine/Apple-PIM-Agent-Plugin)

## License

MIT (c) Omar Shahine
