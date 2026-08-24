import ArgumentParser
import Foundation

// SQLite fast-path implementations for the read commands. Each function
// produces the same JSON shape as its JXA counterpart; callers fall back to
// JXA when anything here throws (no Full Disk Access, mailbox not found in
// the index, .emlx not on disk, etc.).

enum EngineChoice: String, ExpressibleByArgument {
    case auto
    case sqlite
    case jxa
}

/// Normalize a user-supplied message id: JXA reports Message-IDs without
/// angle brackets, the Envelope Index stores them with. Accept both.
func messageIDCandidates(_ id: String) -> [String] {
    let trimmed = id.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
        return [trimmed, String(trimmed.dropFirst().dropLast())]
    }
    return ["<\(trimmed)>", trimmed]
}

func stripAngleBrackets(_ id: String) -> String {
    var s = id
    if s.hasPrefix("<") { s.removeFirst() }
    if s.hasSuffix(">") { s.removeLast() }
    return s
}

struct SQLiteEngine {
    let index: EnvelopeIndex
    let allMailboxes: [MailboxRef]
    private let mailboxByURL: [String: MailboxRef]
    private let mailboxByRowID: [Int64: MailboxRef]

    init() throws {
        try self.init(index: EnvelopeIndex.open())
    }

    init(index: EnvelopeIndex, allMailboxes: [MailboxRef]) {
        self.index = index
        self.allMailboxes = allMailboxes
        mailboxByURL = Dictionary(uniqueKeysWithValues: allMailboxes.map { ($0.url, $0) })
        mailboxByRowID = Dictionary(uniqueKeysWithValues: allMailboxes.map { ($0.rowid, $0) })
    }

    /// Open against an already-discovered index, deriving the mailbox inventory from it.
    /// Lets tests drive the engine from a throwaway fixture database instead of the caller's
    /// real Envelope Index, without also having to hand-build the inventory.
    init(index: EnvelopeIndex) throws {
        self.init(index: index, allMailboxes: try index.mailboxes())
    }

    private func accountDisplayName(_ uuid: String) -> String {
        index.accountNames()[uuid]?.name ?? uuid
    }

    /// Mailboxes matching an optional account name and optional mailbox name
    /// (both case-insensitive; account matches display name, user name, or UUID).
    private func resolveMailboxes(account: String?, mailbox: String?) throws -> [MailboxRef] {
        var candidates = allMailboxes
        if let account {
            let uuids = try index.accountUUIDs(matching: account)
            guard !uuids.isEmpty else {
                throw EnvelopeIndexError.notFound("Account not found: \(account)")
            }
            candidates = candidates.filter { uuids.contains($0.accountUUID) }
        }
        if let mailbox {
            let target = mailbox.lowercased()
            candidates = candidates.filter { $0.name.lowercased() == target }
        }
        return candidates
    }

    /// The mailbox a row should be *reported* as living in: the one the caller scoped to when
    /// a label put it there, otherwise the store that owns the row.
    func mailboxRef(forRow row: [String: Any]) -> MailboxRef? {
        if let logicalRowID = row["logical_mailbox_rowid"] as? Int64,
           let logicalMailbox = mailboxByRowID[logicalRowID] {
            return logicalMailbox
        }
        return physicalMailboxRef(forRow: row)
    }

    /// The mailbox that physically owns the row, ignoring any label. Anything touching the
    /// on-disk store must use this: a Gmail INBOX message lives under [Gmail]/All Mail, so
    /// building an .emlx path from the logical mailbox searches a directory the file is not in.
    func physicalMailboxRef(forRow row: [String: Any]) -> MailboxRef? {
        (row["mailbox_url"] as? String).flatMap { mailboxByURL[$0] }
    }

    /// URL-keyed lookup for the WRITE path, deliberately separate from `mailboxRef(forRow:)`
    /// (which prefers the LOGICAL mailbox a Gmail label displays a message under). A write must
    /// address the PHYSICAL mailbox — the one with an on-disk store, the only one
    /// `mailbox.messages.byId(rowid)` can reach and the one `mail delete` destroys a copy in.
    ///
    /// Currently latent (no locator row source projects the logical rowid yet) but pins the
    /// invariant for when one does. See
    /// `MessageLocatorTests.testLocatorResolvesToThePHYSICALMailboxNotTheLogicalOne`.
    private func mailboxRef(forURL url: String?) -> MailboxRef? {
        url.flatMap { mailboxByURL[$0] }
    }

    // MARK: - Row mapping

    /// Shared row -> message summary mapping (the `messages` command shape).
    private func summaryDict(_ row: [String: Any], includeJunkAndAttachments: Bool,
                             includeLocation: Bool) -> [String: Any] {
        let mailbox = mailboxRef(forRow: row)
        let senderAddress = row["sender_address"] as? String ?? ""
        let senderName = (row["sender_comment"] as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        var dict: [String: Any] = [
            "messageId": stripAngleBrackets(row["message_id"] as? String ?? ""),
            "sender": formatAddress(address: senderAddress, comment: senderName),
            // The Envelope Index stores these separately and Mail's own recipient lists are
            // already structured, so flattening the sender was both lossy and inconsistent.
            // Hand back the isolated address: a display name may contain an `@`, and every
            // consumer re-parsing the joined string is a spoofing check waiting to be got
            // wrong. See `parseAddress` for what goes wrong when it is.
            "senderAddress": senderAddress,
            "senderName": senderName,
            "subject": fullSubject(prefix: row["subject_prefix"] as? String,
                                   subject: row["subject"] as? String),
            "dateReceived": epochValue(row["date_received"]).map { isoStringFromEpoch($0) } ?? NSNull(),
            "isRead": (row["read"] as? Int64 ?? 0) != 0,
            "isFlagged": (row["flagged"] as? Int64 ?? 0) != 0,
        ]
        if includeJunkAndAttachments {
            dict["isJunk"] = mailbox.map { isJunkMailboxName($0.name) } ?? false
            dict["attachmentCount"] = Int(row["attachment_count"] as? Int64 ?? 0)
        }
        if includeLocation {
            dict["mailbox"] = mailbox?.name ?? ""
            dict["account"] = mailbox.map { accountDisplayName($0.accountUUID) } ?? ""
        }
        return dict
    }

    // MARK: - Commands

    /// Best-effort account inventory derived from local mailboxes. The JXA
    /// path is authoritative (it also knows `enabled` state and accounts with
    /// no local mailboxes); this serves `--engine sqlite` and Mail-closed auto.
    func accounts() -> [String: Any] {
        let names = index.accountNames()
        var seen: Set<String> = []
        var result: [[String: Any]] = []
        for mailbox in allMailboxes where mailbox.scheme != "local" && mailbox.scheme != "file" {
            guard seen.insert(mailbox.accountUUID).inserted else { continue }
            let entry = names[mailbox.accountUUID]
            result.append([
                "name": entry?.name ?? mailbox.accountUUID,
                "id": mailbox.accountUUID,
                "userName": entry?.userName ?? "",
                "accountType": mailbox.scheme,
            ])
        }
        return ["success": true, "accounts": result, "engine": "sqlite"]
    }

    func mailboxes(account: String?) throws -> [String: Any] {
        let refs = try resolveMailboxes(account: account, mailbox: nil)
        let result = refs.map { mailbox -> [String: Any] in
            [
                "name": mailbox.name,
                "account": accountDisplayName(mailbox.accountUUID),
                "unreadCount": mailbox.unreadCount,
                "messageCount": mailbox.totalCount,
            ]
        }
        return ["success": true, "mailboxes": result, "engine": "sqlite"]
    }

    func messages(
        mailbox: String,
        account: String?,
        limit: Int,
        filter: String?,
        sinceEpoch: Double? = nil,
        oldestFirst: Bool = false
    ) throws -> [String: Any] {
        let refs = try resolveMailboxes(account: account, mailbox: mailbox)
        guard !refs.isEmpty else {
            throw EnvelopeIndexError.notFound("Mailbox not found: \(mailbox)")
        }
        var messageFilter = EnvelopeIndex.MessageFilter(mailboxRowIDs: refs.map { $0.rowid })
        messageFilter.unreadOnly = filter == "unread"
        messageFilter.flaggedOnly = filter == "flagged"
        messageFilter.sinceEpoch = sinceEpoch
        messageFilter.oldestFirst = oldestFirst

        let rows = try index.messages(filter: messageFilter, limit: limit)
        let result = rows.map { summaryDict($0, includeJunkAndAttachments: true, includeLocation: false) }
        return [
            "success": true,
            "mailbox": refs.first?.name ?? mailbox,
            "messages": result,
            "count": result.count,
            "totalInMailbox": refs.reduce(0) { $0 + $1.totalCount },
            "engine": "sqlite",
        ]
    }

    func search(query: String, field: String, mailbox: String?, account: String?,
                limit: Int, since: String?) throws -> [String: Any] {
        guard field != "content" else {
            // Bodies aren't indexed in the Envelope Index; let JXA handle it.
            throw EnvelopeIndexError.notAvailable("Content search requires the JXA engine")
        }
        var messageFilter = EnvelopeIndex.MessageFilter()
        if mailbox != nil || account != nil {
            let refs = try resolveMailboxes(account: account, mailbox: mailbox)
            messageFilter.mailboxRowIDs = refs.map { $0.rowid }
        }
        if let since {
            guard let epoch = epochFromISO8601(since) else {
                throw CLIError.invalidInput("Invalid date format for --since. Use ISO 8601: YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ")
            }
            messageFilter.sinceEpoch = epoch
        }
        messageFilter.queryText = query
        messageFilter.queryField = field

        let rows = try index.messages(filter: messageFilter, limit: limit)
        let result = rows.map { summaryDict($0, includeJunkAndAttachments: false, includeLocation: true) }
        return [
            "success": true,
            "query": query,
            "field": field,
            "messages": result,
            "count": result.count,
            "engine": "sqlite",
        ]
    }

    func get(id: String, includeSource: Bool,
             mailboxHint: String? = nil, accountHint: String? = nil) throws -> [String: Any] {
        // Resolve the hints before the lookup rather than inside it. Message-IDs are
        // sender-generated, so one message delivered to two local accounts is stored as two
        // distinct copies sharing an ID, and the hints are exactly what select the copy the
        // caller meant. Swallowing an ambiguous or unknown hint here returned the other
        // account's copy with `success: true`, which is worse than refusing to guess.
        var hintedAccountUUIDs: [String] = []
        if let accountHint {
            hintedAccountUUIDs = try index.accountUUIDs(matching: accountHint)
            guard !hintedAccountUUIDs.isEmpty else {
                throw EnvelopeIndexError.notFound("Account not found: \(accountHint)")
            }
        }
        let hintedMailboxRowIDs: [Int64] = mailboxHint.map { hint in
            allMailboxes
                .filter {
                    $0.name.caseInsensitiveCompare(hint) == .orderedSame
                        && (hintedAccountUUIDs.isEmpty
                            || hintedAccountUUIDs.contains($0.accountUUID))
                }
                .map { $0.rowid }
        } ?? []

        var rows: [[String: Any]] = []
        for candidate in messageIDCandidates(id) {
            rows = try index.findMessage(
                messageIDHeader: candidate, logicalMailboxRowIDs: hintedMailboxRowIDs)
            if !rows.isEmpty { break }
        }
        // A Message-ID can have copies in several mailboxes; prefer the copy
        // matching the caller's hints (like the JXA path's prioritized lookup),
        // keeping newest-first order among equally-good matches.
        var bestRow = rows.first
        if mailboxHint != nil || accountHint != nil {
            var bestScore = -1
            for candidate in rows {
                guard let mailbox = mailboxRef(forRow: candidate) else { continue }
                var score = 0
                if let hint = mailboxHint, mailbox.name.caseInsensitiveCompare(hint) == .orderedSame { score += 2 }
                if hintedAccountUUIDs.contains(mailbox.accountUUID) { score += 1 }
                if score > bestScore {
                    bestScore = score
                    bestRow = candidate
                }
            }
        }
        guard let row = bestRow, let rowid = row["rowid"] as? Int64 else {
            throw EnvelopeIndexError.notFound("Message not found: \(id)")
        }
        // Physical, not logical: the payload reports the mailbox the message is labeled into,
        // but the .emlx sits under the store that owns the row.
        guard let physicalMailbox = physicalMailboxRef(forRow: row),
              let emlxURL = index.emlxPath(
                forMessageRowID: rowid, mailbox: physicalMailbox) else {
            // Message metadata exists but the body isn't on disk (not yet
            // downloaded); the JXA engine can still fetch it from Mail.app.
            throw EnvelopeIndexError.notAvailable("Local .emlx not found for message; body requires the JXA engine")
        }

        let emlx = try readEmlx(at: emlxURL)
        var message = summaryDict(row, includeJunkAndAttachments: true, includeLocation: true)
        message["dateSent"] = epochValue(row["date_sent"]).flatMap { $0 > 0 ? isoStringFromEpoch($0) : nil } ?? NSNull()
        if let replyToHeader = emlx.header("Reply-To") {
            let parsed = parseAddress(replyToHeader)
            message["replyTo"] = replyToHeader
            message["replyToAddress"] = parsed.address
            message["replyToName"] = parsed.name
        } else {
            // No Reply-To: the sender stands in. Copy the clean columns rather than
            // re-parsing the string they were just flattened into.
            message["replyTo"] = message["sender"] ?? ""
            message["replyToAddress"] = message["senderAddress"] ?? ""
            message["replyToName"] = message["senderName"] ?? ""
        }
        message["content"] = emlx.content
        message["allHeaders"] = emlx.rawHeaders

        let (to, cc) = try index.recipients(messageRowID: rowid)
        message["to"] = to
        message["cc"] = cc

        let attachmentNames = try index.attachments(messageRowID: rowid)
        message["attachments"] = attachmentNames.enumerated().map { index, name in
            ["index": index, "name": name] as [String: Any]
        }
        message["attachmentCount"] = attachmentNames.count

        if includeSource, let raw = try? Data(contentsOf: emlxURL),
           let payload = try? emlxMessageData(raw) {
            // Byte-counted RFC 822 payload only — excludes Mail's plist trailer.
            message["source"] = decodeText(payload, charset: "utf-8")
        }

        return ["success": true, "message": message, "engine": "sqlite"]
    }

    func authStatusInfo() -> [String: Any] {
        var info: [String: Any] = ["readable": true]
        info["path"] = index.versionDir.appendingPathComponent("MailData/Envelope Index").path
        info["messageCount"] = (try? index.messageCount()) ?? 0
        return info
    }
}

// MARK: - Write-path message locator

// Lives here rather than beside the protocol because everything it needs is already on the
// engine and file-private: `mailboxByURL`, `accountDisplayName`, and the one open database
// handle with its cached labels probe and account-name map. A standalone locator would open
// a second handle against a file Mail.app writes continuously and duplicate both caches.
extension SQLiteEngine: MessageLocator {
    func isAvailable() -> Bool { true }

    func resolve(messageIds: [String], mailbox: String?,
                 account: String?) throws -> [String: [ResolvedRef]] {
        guard !messageIds.isEmpty else { return [:] }

        // A hard filter, and an unresolved hint yields no candidates rather than an error, so
        // `--engine auto`'s JXA scan can still complete the write.
        //
        // Its NAMESPACE is wider than the scan's, which is not a difference of degree: this
        // resolves a raw account UUID first, then the display name, then the user name
        // (case-insensitive, read through the parent-COALESCE join so IMAP child accounts
        // resolve too), while the scan it falls back to matches `account.name()` alone
        // (`Mail.accounts.whose({name: acctHint})`). A UUID or user-name hint therefore
        // accelerates here and matches no account there — the same command completes under
        // `--engine auto` and reports "Message not found" under `--engine jxa`.
        //
        // `try?` swallows `.ambiguous` on purpose — fail OPEN: an empty UUID set skips the byId
        // path and lets JXA pick exactly as it would with no locator. Correct but slow, never
        // wrong. Pinned by
        // `MessageLocatorTests.testAnAMBIGUOUSAccountHintFailsOPENToEmptyCandidates`.
        var accountUUIDs: Set<String>?
        if let account {
            accountUUIDs = Set((try? index.accountUUIDs(matching: account)) ?? [])
        }

        // Every requested id is a key, so the JXA side can tell "resolved to nothing" from
        // "never asked for" without a second contract.
        var candidateMap: [String: [ResolvedRef]] = [:]
        for id in messageIds { candidateMap[normalizeMessageIDForLookup(id)] = [] }

        var queried: Set<String> = []
        for id in messageIds {
            let normalized = normalizeMessageIDForLookup(id)
            guard queried.insert(normalized).inserted else { continue }
            if let accountUUIDs, accountUUIDs.isEmpty { continue }

            // `findMessage` filters `m.deleted = 0` and matches both bracketed and bare stored
            // forms via `messageIDCandidates`. UNION them rather than stop at the first that
            // answers — two accounts can store the same id in different forms, and JXA (which
            // matches Mail's normalized `messageId`) sees both; stopping early would hide a
            // copy from the cross-account check below.
            var rows: [[String: Any]] = []
            var seenRowIDs: Set<Int64> = []
            for candidate in messageIDCandidates(id) {
                for row in try index.findMessage(messageIDHeader: candidate) {
                    guard let rowid = row["rowid"] as? Int64,
                          seenRowIDs.insert(rowid).inserted else { continue }
                    rows.append(row)
                }
            }

            var refs: [ResolvedRef] = []
            for row in rows {
                guard let rowid = row["rowid"] as? Int64,
                      let url = row["mailbox_url"] as? String,
                      let mailboxRef = mailboxRef(forURL: url) else { continue }
                // "On My Mac" mailboxes (`local://`, and `file://` for a mailbox addressed by
                // its on-disk location — `accounts()` above skips both for the same reason)
                // hang off the APPLICATION, not an account: Mail's scripting dictionary
                // declares `account` and its POP / IMAP / iCloud subclasses and no local one,
                // while `application` carries its own `mailbox` element. A `file://` URL has no
                // account authority at all, so its rows would also share one empty account
                // UUID. Every JXA lookup here goes through `Mail.accounts()` — the
                // byId arm resolves a candidate's account before touching it, and all three
                // sweeps of the scan enumerate `accounts[a].mailboxes` — so a local candidate
                // is unreachable by construction. Skipping it keeps the candidate set faithful
                // to what JXA can see: a local-only id resolves to nothing (the same
                // fall-through as today, minus a wasted round trip), and a copy filed to On My
                // Mac no longer makes an otherwise single-account id look cross-account and
                // lose acceleration below.
                if mailboxRef.scheme == "local" || mailboxRef.scheme == "file" { continue }
                if let accountUUIDs, !accountUUIDs.contains(mailboxRef.accountUUID) { continue }
                let names = index.accountNames()[mailboxRef.accountUUID]
                refs.append(ResolvedRef(
                    normalizedMessageId: normalized,
                    rowid: rowid,
                    mailboxURL: url,
                    mailboxName: mailboxRef.name,
                    mailboxPathComponents: mailboxRef.pathComponents,
                    accountUUID: mailboxRef.accountUUID,
                    accountName: names?.name))
            }

            // A Message-ID spanning more than one ACCOUNT is not accelerated. Order decides
            // WHICH PHYSICAL COPY a write acts on, and both drift guards are blind to a wrong
            // pick — both copies carry the same Message-ID.
            //
            // v3.11 is account-OUTER (exhausts one account's priority list before the next);
            // reproducing that needs Mail's account order, which the Envelope Index does not
            // carry. So this declines to an empty list and lets the account-outer scan pick, as
            // today. `--account` is a hard filter above, so a scoped write stays accelerated.
            if Set(refs.map { $0.accountUUID ?? "" }).count > 1 {
                candidateMap[normalized] = []
                continue
            }

            // `findMessage` orders by date_received; re-rank into the sweep's own order.
            let ranked = refs.sorted { a, b in
                if let mailbox {
                    let aHit = a.mailboxName.caseInsensitiveCompare(mailbox) == .orderedSame
                    let bHit = b.mailboxName.caseInsensitiveCompare(mailbox) == .orderedSame
                    if aHit != bHit { return aHit }
                }
                let aRank = priorityRank(forMailboxName: a.mailboxName)
                let bRank = priorityRank(forMailboxName: b.mailboxName)
                if aRank != bRank { return aRank < bRank }
                return a.rowid < b.rowid
            }

            // The same rule one level down: inside the one surviving account the order is
            // still selection, so a CONTESTED id is accelerated only when this list's head is
            // the copy the scan itself reaches first. See `headMatchesJXASweep`.
            guard headMatchesJXASweep(ranked, mailboxHint: mailbox) else {
                candidateMap[normalized] = []
                continue
            }

            // HEAD ONLY: the guard certifies `ranked[0]` alone. The JXA candidate loop falls
            // through a candidate on three normal paths — the account will not resolve, it
            // exposes no mailbox to address the rowid through, and Layer-1 messageId mismatch
            // — so a tail entry could land the write on a copy no guard certified. Costs
            // nothing real: the tail only ever bought speed on a stale head, and a head miss
            // falls through to the JXA scan (v3.11).
            candidateMap[normalized] = Array(ranked.prefix(1))
        }

        return candidateMap
    }
}

/// True when `ranked`'s head is the copy v3.11's own within-account scan reaches first. Emits
/// the head alone, so certifying it is exactly certifying the whole list.
///
/// Rests on three properties of Mail's own scan. Two were observed directly on macOS 26.5 /
/// Mail 16.0: `account.mailboxes()` is FLAT on every account type to hand (Gmail's special
/// mailboxes come back as renamed top-level leaves, with no "[Gmail]" container), and
/// `whose({name: …})` FOLDS CASE (`{name: 'inbox'}` matches INBOX). The third — what order
/// `account.mailboxes()` enumerates copies the priority list cannot separate — is open. The
/// rule assumes none of the three, because an account whose server files mailboxes under a
/// parent is reachable on another machine: the head is trusted only when it is a DIRECT CHILD
/// (so nesting can neither help nor hurt it) and it wins against the whole tail under BOTH the
/// exact and case-folding readings — a proof against those two readings, not against any
/// conceivable semantics. Everything else declines to an empty list and the scan decides, as
/// today.
///
/// The direct-child requirement therefore declines a class it need not: a copy the index
/// records under "[Gmail]/All Mail" is a top-level leaf to Mail, so the scan does reach it.
/// Narrowing that means deciding when the index's server-side path may be read as Mail's own
/// naming — a separate change, and one worth making only for CONTESTED ids, which the Gmail
/// hot path is not.
///
/// A single deep candidate is NOT declined (the carried-labels Gmail case, which is the
/// everyday write this accelerates) — with one copy there is no selection to get wrong.
private func headMatchesJXASweep(_ ranked: [ResolvedRef], mailboxHint: String?) -> Bool {
    guard ranked.count > 1 else { return true }
    let head = ranked[0]
    let tail = ranked.dropFirst()

    guard head.mailboxPathComponents.count == 1 else { return false }

    if let hint = mailboxHint,
       head.mailboxName.caseInsensitiveCompare(hint) == .orderedSame {
        // The hint loop runs before the priority sweep, so a hinted head wins there — but only
        // if Mail's specifier matches the same string this sort matched. The sort above
        // compares the hint case-insensitively (`--mailbox inbox` behaves like `--mailbox
        // INBOX`, as `resolveMailboxes` does on the read side) while Mail's own
        // `whose({name:…})` is a separate implementation, so the hint is trusted only on an
        // EXACT match — which holds whether or not that specifier folds case — and only when
        // no other candidate answers to it either way.
        return head.mailboxName == hint
            && tail.allSatisfy { $0.mailboxName.caseInsensitiveCompare(hint) != .orderedSame }
    }

    // No hint: the priority sweep decides. The head (a direct child) is reached at
    // `priorityRank`/`priorityRankFoldingCase`; a tail candidate's earliest possible reach is
    // the same rank under the same reading (nesting only delays it). So certification needs a
    // strict win against the MINIMUM of the whole tail under BOTH readings — not the runner-up,
    // since folding can promote a later element ahead of it (example:
    // `[Archive(4), Receipts(unranked), Inbox(folds to 0)]`).
    let headExact = priorityRank(forMailboxName: head.mailboxName)
    let headFolding = priorityRankFoldingCase(forMailboxName: head.mailboxName)
    let tailExact = tail.map { priorityRank(forMailboxName: $0.mailboxName) }.min() ?? Int.max
    let tailFolding = tail.map { priorityRankFoldingCase(forMailboxName: $0.mailboxName) }
        .min() ?? Int.max

    return headExact < tailExact && headFolding < tailFolding
}
