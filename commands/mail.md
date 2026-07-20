---
description: Manage macOS Mail.app - list, read, search, send, reply, update flags, move, delete, and verify sender authentication
argument-hint: "[accounts|mailboxes|messages|get|search|send|reply|update|move|delete|auth_check] [options]"
allowed-tools:
  - mcp__plugin_apple-pim_apple-pim__mail
---

# Mail Management

Manage macOS Mail.app messages. Reads (`accounts`, `mailboxes`, `messages`, `get`, `search`) use a fast direct-SQLite path against Mail's local Envelope Index (milliseconds, works with Mail.app closed, needs Full Disk Access) and fall back to JXA automatically. Mutations and `content` search go through Mail.app via JXA/AppleScript, which requires Mail.app to be running.

## Available Operations

When the user runs this command, determine which operation they need and use the `mail` tool with the appropriate action:

### List Accounts
Use `mail` with action `accounts` to show all configured mail accounts.

### List Mailboxes
Use `mail` with action `mailboxes` to list mailboxes with unread and total message counts:
- Optional: `account` (filter by account name)

### List Messages
Use `mail` with action `messages` to list messages in a mailbox:
- Default mailbox: INBOX
- Parameters: `mailbox`, `account`, `limit` (default: 25), `filter` (unread, flagged, all)

### Get Message
Use `mail` with action `get` to get a single message with full body content:
- Required: `id` (RFC 2822 message ID)
- Optional: `mailbox`, `account` (hints for faster lookup)
- Optional: `format` (`plain` default, or `markdown` for HTML-to-markdown conversion)

### Search Messages
Use `mail` with action `search` to find messages by subject, sender, or content:
- Required: `query` (search term)
- Optional: `field` (subject, sender, content, all), `mailbox`, `account`, `limit`, `since` (ISO 8601 date)

### Send Message
Use `mail` with action `send` to send an email through Mail.app:
- Required: `to` (array of recipient addresses), `subject` (email subject), `body` (plain text body)
- Optional: `cc`, `bcc`, `from` (sender address for account selection)
- Uses AppleScript to compose and send via Mail.app's outgoing message

### Reply to Message
Use `mail` with action `reply` to reply to a message with proper threading:
- Required: `id` (RFC 2822 message ID), `body` (reply text)
- Optional: `mailbox`, `account` (hints for faster lookup)
- Uses Mail.app's `reply` verb which sets In-Reply-To, References headers, and quotes the original

### Auth Check (Sender Verification)
Use `mail` with action `auth_check` to verify sender authentication:
- Required: `id` (RFC 2822 message ID)
- Optional: `trustedSenders` (path to trusted-senders.json, default: ~/.config/apple-pim/trusted-senders.json)
- Optional: `mailbox`, `account` (hints for faster lookup)
- Parses Authentication-Results headers (DKIM + SPF), cross-references against trusted sender config
- Returns verdict: `verified`, `suspicious`, `untrusted`, or `unknown`

### Update Message
Use `mail` with action `update` to change message flags:
- Required: `id` (message ID)
- Optional: `read` (true/false), `flagged` (true/false), `junk` (true/false)

### Batch Update
Use `mail` with action `batch_update` to update flags on multiple messages at once:
- Required: `ids` (array of message IDs)
- Optional: `read`, `flagged`, `junk`, `mailbox`, `account`
- Efficient for triaging: "mark all these as read"

### Move Message
Use `mail` with action `move` to move a message to a different mailbox:
- Required: `id` (message ID), `toMailbox` (destination)
- Optional: `toAccount` (destination account)

### Delete Message
Use `mail` with action `delete` to delete a single message (moves to Trash):
- Required: `id` (message ID)

### Batch Delete
Use `mail` with action `batch_delete` to delete multiple messages at once:
- Required: `ids` (array of message IDs)
- Optional: `mailbox`, `account` (hints for faster lookup)

## Examples

**List accounts:**
```
/apple-pim:mail accounts
```

**List mailboxes:**
```
/apple-pim:mail mailboxes
/apple-pim:mail mailboxes --account "iCloud"
```

**List messages:**
```
/apple-pim:mail messages
/apple-pim:mail messages --mailbox INBOX --limit 10
/apple-pim:mail messages --filter unread
/apple-pim:mail messages --filter flagged
```

**Read a message:**
```
/apple-pim:mail get --id <message-id>
/apple-pim:mail get --id <message-id> --format markdown
```

**Search messages:**
```
/apple-pim:mail search "invoice"
/apple-pim:mail search "John" --field sender
/apple-pim:mail search "project update" --mailbox INBOX
```

**Send an email:**
```
/apple-pim:mail send --to "user@example.com" --subject "Hello" --body "Message text"
/apple-pim:mail send --to "user@example.com" --cc "other@example.com" --subject "Update" --body "FYI"
/apple-pim:mail send --to "user@example.com" --from "alias@example.com" --subject "From alias" --body "Sent from specific account"
```

**Reply to a message:**
```
/apple-pim:mail reply --id <message-id> --body "Thanks for the update!"
```

**Check sender authentication:**
```
/apple-pim:mail auth_check --id <message-id>
/apple-pim:mail auth_check --id <message-id> --trusted-senders ~/.config/apple-pim/trusted-senders.json
```

**Mark as read:**
```
/apple-pim:mail update --id <message-id> --read true
```

**Mark multiple as read:**
```
/apple-pim:mail batch-update --ids [<id1>, <id2>, <id3>] --read true
```

**Flag a message:**
```
/apple-pim:mail update --id <message-id> --flagged true
```

**Move to archive:**
```
/apple-pim:mail move --id <message-id> --to-mailbox Archive
```

**Delete a message:**
```
/apple-pim:mail delete --id <message-id>
```

**Delete multiple messages:**
```
/apple-pim:mail batch-delete --ids [<id1>, <id2>]
```

## Parsing User Intent

When a user provides natural language, map to the appropriate operation:
- "Check my mail" -> `mail` with action `messages` and default INBOX
- "Show unread messages" -> `mail` with action `messages` and filter: unread
- "How many unread emails do I have?" -> `mail` with action `mailboxes` to show unread counts
- "Show flagged messages" -> `mail` with action `messages` and filter: flagged
- "Find emails from John" -> `mail` with action `search` and field: sender
- "Search for invoices" -> `mail` with action `search` and query "invoice"
- "Read that email" -> `mail` with action `get` with the message ID
- "Mark it as read" -> `mail` with action `update` with read: true
- "Mark all these as read" -> `mail` with action `batch_update` with read: true
- "Flag this for later" -> `mail` with action `update` with flagged: true
- "Archive this" -> `mail` with action `move` to Archive mailbox
- "Delete that email" -> `mail` with action `delete`
- "Clean up my inbox" -> List messages, then `mail` with action `batch_delete` or `move` as appropriate
- "Mark these as junk" -> `mail` with action `batch_update` with junk: true
- "Send an email to..." -> `mail` with action `send` with to, subject, body
- "Reply to that email" -> `mail` with action `reply` with id and body
- "Is this email legit?" -> `mail` with action `auth_check` with the message ID
- "Verify that sender" -> `mail` with action `auth_check` with the message ID

## Important Notes

- **Mail.app must be running** for all operations. If not running, the CLI returns a clear error.
- **Message IDs** are RFC 2822 message IDs (stable across mailbox moves).
- **Batch operations** process messages sequentially but in a single tool call for convenience.
- **Send/Reply** use AppleScript via Mail.app, sending from whatever account is configured in Mail.app.
- **Auth Check** requires a `trusted-senders.json` config file mapping senders to expected DKIM domains.
- This tool accesses Mail.app's local state -- "On My Mac" mailboxes, locally cached messages, and local search.
