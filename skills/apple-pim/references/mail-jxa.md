# Mail.app JXA Reference

## Two engines: SQLite (lookup) and JXA (every mutation)

Read commands (`accounts`, `mailboxes`, `messages`, `get`, `search`) default to
`--engine auto`: they query Apple Mail's **Envelope Index** SQLite database
(`~/Library/Mail/V*/MailData/Envelope Index`, opened strictly read-only) and
read bodies from on-disk `.emlx` files. This is ~10–200× faster than JXA and
works with Mail.app closed, but requires Full Disk Access. When the database
isn't readable — or for `--field content` search, or when a body's `.emlx`
hasn't been downloaded — the command silently falls back to JXA. Check
`auth-status` → `envelopeIndex.readable` to see which path is active.
Mutations (`update`, `move`, `delete`, `send`, `reply`) are always performed by
JXA/AppleScript — nothing here ever writes to Mail's database. `update`, `move`,
`delete`, `batch-update` and `batch-delete` do take `--engine` as well: under
`auto` they query the same read-only index first for the message's mailbox and
row-id, so JXA can address it directly instead of scanning mailbox by mailbox,
and they fall back to that scan whenever the lookup cannot answer. `send` and
`reply` are unaffected.

An `--account` hint that matches two accounts is **refused**, not resolved, under every
engine, and for batch commands the whole run is refused rather than each entry. Both would otherwise pick a first match: the Envelope Index returns a set, and
`Mail.accounts.whose({name:})` returns them in enumeration order. Acting on either is a
silent wrong-account read, and a wrong-account write is not reversible. The two engines word
the refusal differently on purpose — the index can suggest an account UUID because it can
resolve one, and JXA resolves nothing but a name, so it says to rename the account in Mail
or re-run under `--engine auto`.

This covers account names *you* pass. Two names the CLI derives internally still resolve by
first match: the write finder's row-id candidates, and the account `reply` reads back off the
message it is answering. With two same-named accounts a reply can therefore still bind the
wrong one and fail with "Could not locate the original message" instead of an ambiguity error.

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
