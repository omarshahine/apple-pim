# Apple PIM: Calendar, Reminders, Contacts, Mail

*PIM = Personal Information Manager.*

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

### Apple Mail channel

The plugin also registers an inbound mail **channel** (`apple-mail`). It polls the local
Mail.app store, authenticates each sender, and admits messages by authentication strength.
It is inert until `channels.apple-mail` exists in `openclaw.json`.

```jsonc
{
  "channels": {
    "apple-mail": {
      "dmPolicy": "allowlist",
      // Who may drive the agent.
      "allowFrom": ["omar@shahine.com", "lora@shahine.com"],
      // Minimum strength an identifier needs before it authorizes a sender.
      // "asserted" (default) requires the sender's domain to have authenticated.
      // "verified" additionally requires an expectedDkimDomains entry for each address
      // below; until one exists, that sender is readable but never actioned.
      "minIdentifierAuthentication": "verified",
      // Carries expectedDkimDomains (address -> legitimate signing domains) and
      // trustedAuthservIds (which Authentication-Results headers are believed).
      "trustedSendersPath": "~/.config/lobster/trusted-senders.json",
      // Addresses the agent sends as. Required: this is the inbound and outbound loop guard.
      "selfAddresses": ["lobster@example.com"],
      // Always-permitted reply recipients.
      "operatorAddresses": ["omar@shahine.com"],
      // Recipients the agent may originate mail to. Egress is default-deny without this.
      "egressAllowlist": [],
      // Not always INBOX: mail is often archived on arrival.
      "mailbox": "INBOX",
      "pollIntervalSeconds": 60
    }
  }
}
```

Two lists, two jobs, and they are deliberately not the same file:

- **`allowFrom`** answers *who may drive the agent*. Policy.
- **`trustedSendersPath`** answers *what proves they are who they claim*. Only addresses with
  an `expectedDkimDomains` entry can ever reach `verified`, because that entry is the
  operator assertion binding an address to its legitimate signers. DMARC alignment proves a
  **domain**, never a mailbox.

They will list overlapping addresses. That duplication is intended, and the drift between
them is checked rather than merely documented: adding someone to `allowFrom` without
enrolling them caps that address at `asserted`, so under `minIdentifierAuthentication:
"verified"` their mail is readable but never actioned. The channel reports every such entry
at startup:

```
apple-mail [allowlisted_not_enrolled]: lora@shahine.com is in channels.apple-mail.allowFrom
but has no expectedDkimDomains entry in ~/.config/lobster/trusted-senders.json. ...
```

It also warns when `selfAddresses` is empty (the loop guard cannot fire), when no
`trustedAuthservIds` covers the account (nothing authenticates, everything drops), and when
an enrolled sender names no signing domains (that address can never reach `verified`).

Scenario-by-scenario behavior, inbound and outbound, is in
[`docs/mail-channel-scenarios.md`](../docs/mail-channel-scenarios.md).

**Reading does not need Mail.app; replying does.** Polling and authentication read the
Envelope Index and the `.emlx` files directly, so they work with Mail.app closed, but the
process needs **Full Disk Access** to read them at all. `reply` goes through Apple Events,
needs **Automation** access to Mail.app, and launches Mail.app on demand. Without those
permissions the channel does not fall back to a degraded mode: polls and replies simply
fail.

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

Full docs: [github.com/omarshahine/apple-pim](https://github.com/omarshahine/apple-pim)

## License

MIT (c) Omar Shahine
