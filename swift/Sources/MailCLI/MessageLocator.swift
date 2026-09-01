import Foundation

// Write-path message lookup acceleration: resolves Message-IDs against the local Envelope
// Index and hands JXA a ranked list of ROWIDs it can address with `mailbox.messages.byId`,
// instead of a per-mailbox `whose({messageId: ...})` scan. SQLite performs no part of the
// write — every candidate is re-verified by Message-ID on the JXA side before use, and a
// locator that cannot answer emits an empty map, leaving today's scan unchanged.

/// One Envelope-Index copy of a message: where it lives and how to address it from JXA.
struct ResolvedRef {
    let normalizedMessageId: String
    let rowid: Int64
    let mailboxURL: String
    /// Leaf mailbox name as the Envelope Index stores it. Swift-side, the candidate sort and
    /// both arms of `headMatchesJXASweep` read it to rank one copy against another. Emitted
    /// only as the per-message lookup telemetry's `mb`; never used to address anything, since
    /// Mail renames some mailboxes it shows.
    let mailboxName: String
    /// Percent-decoded mailbox path from the account root, e.g. ["[Gmail]", "All Mail"].
    /// Swift-side only — `headMatchesJXASweep` reads it to tell a top-level copy from one the
    /// server files deeper. Not emitted: JXA addresses a candidate by account plus rowid.
    let mailboxPathComponents: [String]
    let accountUUID: String?
    let accountName: String?
}

/// Batch-resolves RFC 2822 Message-IDs to ordered rowid candidates.
///
/// `account` is a hard filter (unspecified searches everywhere; specified-and-unknown yields no
/// candidates, matching the JXA scan). `mailbox` is a sort preference, not a filter.
///
/// Candidate ORDER selects which physical copy a write acts on, so an id whose copies the JXA
/// scan might reach in a different order resolves to an EMPTY list instead — see
/// `SQLiteEngine.resolve` / `headMatchesJXASweep`. A survivor resolves to its HEAD alone,
/// already chosen, never a set to pick between.
protocol MessageLocator {
    func resolve(messageIds: [String], mailbox: String?, account: String?) throws -> [String: [ResolvedRef]]
    /// False when no Envelope Index is behind this locator, so nothing can be accelerated.
    func isAvailable() -> Bool
}

/// Trim, then drop angle brackets. This keys the rowid map the emitted JXA reads, so it has to
/// agree with the `normalizeMessageId` twin emitted into that script, or the script looks
/// candidates up under a key that is not there.
///
/// On one input class it does not agree, knowingly: `.whitespaces` excludes newlines, while
/// the twin trims `/^\s+|\s+$/`, which includes them. A Message-ID carrying a leading or
/// trailing newline is therefore keyed here with the newline still attached — and with its
/// brackets, since the strip runs after the trim and no longer sees them — while the script
/// looks it up with both gone. The cost is acceleration, never a wrong write: a missing key
/// yields zero candidates, the same as an id the index declined, and the scan the command
/// falls back to is handed the raw id, exactly as the legacy finders hand it over.
///
/// Deliberately separate from `stripAngleBrackets`, which sits on the read output path.
func normalizeMessageIDForLookup(_ raw: String) -> String {
    stripAngleBrackets(raw.trimmingCharacters(in: .whitespaces))
}

/// Resolves nothing. Used when the caller asked for JXA, and when no Envelope Index can be
/// opened (typically no Full Disk Access) under `--engine auto`.
struct NoopLocator: MessageLocator {
    func resolve(messageIds: [String], mailbox: String?, account: String?) throws -> [String: [ResolvedRef]] {
        var result: [String: [ResolvedRef]] = [:]
        for id in messageIds { result[normalizeMessageIDForLookup(id)] = [] }
        return result
    }

    func isAvailable() -> Bool { false }
}

/// Build the locator a write command should use.
///
/// SQLite never performs the write, so `--engine sqlite` cannot mean "refuse to write" —
/// it means "refuse to run degraded", and says so rather than silently taking the slow path.
/// - `jxa`: no locator, no database opened.
/// - `auto`: locator when one can be opened, silently Noop otherwise.
/// - `sqlite`: locator required; an open failure is reported to the caller.
///
/// The account-ambiguity refusal is NOT part of what the `.jxa` arm gives up, though it was
/// once. `SQLiteEngine.resolve` raises it by asking the Envelope Index whether a name spans
/// two logical accounts, which the `.jxa` arm cannot do — it opens no database by contract —
/// so an ambiguous hint used to fall through to the JXA scan's first-match resolution, for
/// reads and writes alike. It is now detected on the JXA side instead, with no database:
/// `resolveAccountsByHint` (AccountAmbiguity.swift) treats a multi-result
/// `Mail.accounts.whose({name:})` as the ambiguity it is and refuses. Both engines therefore
/// refuse the same `--account`, as `rethrowFatalFastPathError` has always claimed they should.
///
/// Scoped to hints the CALLER supplied. Two account names the code derives for itself are
/// deliberately still first-match, and neither is reachable from `--account`:
/// `getAccountByName` in the write finder resolves the Envelope Index's own name for a rowid
/// candidate, and `buildReplyAppleScript` emits `first account whose name is ...` for a name
/// read back off the message it is replying to. The reply one is the weaker of the two: with
/// two same-named accounts it can bind the wrong one and then fail its own lookup, surfacing
/// as "Could not locate the original message" rather than as an ambiguity. Left alone because
/// closing it means teaching the AppleScript reply path to address accounts by something
/// other than name, which is a different change from this one.
func makeMessageLocator(engine: EngineChoice) throws -> MessageLocator {
    guard engine != .jxa else { return NoopLocator() }
    do {
        return try SQLiteEngine()
    } catch {
        try rethrowFatalFastPathError(engine, error)
        return NoopLocator()
    }
}

/// The JS rowid map for a write command, plus the backend label its telemetry reports.
///
/// Never fails the command under `auto`/`jxa`: a locator that cannot answer degrades to an
/// empty map, and the JXA scan runs unchanged.
func resolveRowidMap(for messageIds: [String], mailbox: String?, account: String?,
                     engine: EngineChoice) throws -> (js: String, backend: String) {
    let locator = try makeMessageLocator(engine: engine)
    let backend = locator.isAvailable() ? "sqlite" : "jxa-only"
    do {
        let refs = try locator.resolve(messageIds: messageIds, mailbox: mailbox, account: account)
        return (buildRowidMapJS(refs), backend)
    } catch {
        try rethrowFatalFastPathError(engine, error)
        return (buildRowidMapJS([:]), "jxa-only")
    }
}

/// The `findMsg` helper every write command embeds: resolve the ids it is about to act on,
/// then generate the unified finder around the resulting rowid map.
///
/// One seam for all five commands rather than the same two calls repeated in each `run()`.
/// Which finder a write uses is not a per-command choice — the legacy finders carry no rowid
/// fast path and no post-`byId` messageId verify — so there is one place to read it and one
/// place a test can hold.
func unifiedWriteFinderJXA(for messageIds: [String], mailbox: String?, account: String?,
                           engine: EngineChoice) throws -> String {
    let resolved = try resolveRowidMap(
        for: messageIds, mailbox: mailbox, account: account, engine: engine)
    return generateUnifiedFindMsgJXA(
        rowidMapJS: resolved.js, backend: resolved.backend, mailbox: mailbox, account: account)
}

/// Serialize resolved candidates as the `rowidMap` JS object literal:
/// `{"<bracket-stripped id>": [{r, mb, acctId, acct}, …]}`, candidates in rank order.
///
/// `r` plus the account is the whole address — `messages.byId` resolves a ROWID globally
/// within the account — so no mailbox path travels to JXA; `mb` rides along for telemetry.
///
/// Not routed through `escapeForJXA`: `JSONSerialization` output is already valid JS literal
/// syntax. A serialization failure returns `{}` so the script degrades to the pure-JXA scan
/// rather than carrying broken JS into `osascript`.
func buildRowidMapJS(_ refs: [String: [ResolvedRef]]) -> String {
    var map: [String: [[String: Any]]] = [:]
    for (id, candidates) in refs {
        map[id] = candidates.map { ref in
            var obj: [String: Any] = ["r": ref.rowid, "mb": ref.mailboxName]
            if let uuid = ref.accountUUID { obj["acctId"] = uuid }
            if let name = ref.accountName { obj["acct"] = name }
            return obj
        }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return json
}
