# Mail.app JXA Reference

## Two engines: SQLite (reads) and JXA (everything else)

Read commands (`accounts`, `mailboxes`, `messages`, `get`, `search`) default to
`--engine auto`: they query Apple Mail's **Envelope Index** SQLite database
(`~/Library/Mail/V*/MailData/Envelope Index`, opened strictly read-only) and
read bodies from on-disk `.emlx` files. This is ~10–200× faster than JXA and
works with Mail.app closed, but requires Full Disk Access. When the database
isn't readable — or for `--field content` search, or when a body's `.emlx`
hasn't been downloaded — the command silently falls back to JXA. Check
`auth-status` → `envelopeIndex.readable` to see which path is active.
Mutations (`update`, `move`, `delete`, `send`, `reply`) are always JXA/AppleScript.

## Why JXA?

Mail.app has no native Swift framework (unlike EventKit/Contacts). JXA (JavaScript for Automation) provides:
- Native JSON output via `JSON.stringify()`
- Full access to Mail.app's scripting dictionary
- Array-level property access for batch operations

The Swift CLI (`mail-cli`) wraps JXA via `Process` calling `osascript -l JavaScript`.

## Key Constraint (JXA engine)

**Mail.app must be running** for the JXA engine (all mutations, content search,
and reads when Full Disk Access is missing). Unlike EventKit/Contacts which work headlessly, Mail.app is a GUI application. The CLI checks `NSWorkspace.shared.runningApplications` upfront and returns a clear error.

## Message Properties

| Property | Type | Description |
|----------|------|-------------|
| `messageId` | String | RFC 2822 message ID (stable identifier) |
| `subject` | String | Message subject |
| `sender` | String | Sender address |
| `dateReceived` | Date | When received |
| `dateSent` | Date | When sent |
| `readStatus` | Bool | Read/unread |
| `flaggedStatus` | Bool | Flagged/unflagged |
| `junkMailStatus` | Bool | Junk/not junk |
| `content` | String | Plain text body |
| `mailbox` | Mailbox | Parent mailbox |

## Batch Property Fetching

JXA's scripting bridge supports array-level property access -- much faster than per-message iteration:

```javascript
// FAST: One IPC call per property, returns array
const subjects = mbox.messages.subject();
const senders = mbox.messages.sender();
const dates = mbox.messages.dateReceived();

// SLOW: N IPC calls (one per message)
for (const msg of mbox.messages()) {
    msg.subject(); // individual IPC call
}
```

## Message ID

Uses RFC 2822 `messageId` property as the stable identifier. This persists across mailbox moves, unlike internal Mail.app IDs. Use `.whose({messageId: targetId})` for lookups.

## Permissions

Mail.app requires Automation permission:
- System Settings > Privacy & Security > Automation
- The terminal/app must be allowed to control Mail.app
- First run triggers a system permission dialog

## Scope vs Fastmail MCP

| Capability | mail-cli (local) | Fastmail MCP (cloud) |
|------------|-----------------|---------------------|
| Read messages | Yes (ms via SQLite) | Yes (server round-trip) |
| Search | Local index (ms) | Server-side |
| Update flags | Yes | Yes |
| Move/delete | Yes | Yes |
| Send email | No | Yes |
| Compose drafts | No | Yes |
| Folder management | No | Yes |
| "On My Mac" mailboxes | Yes | No |
| Offline access | Yes | No |
| Batch flag updates | Yes | Yes |
| Batch delete | Yes | Yes |
