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

    init() throws {
        index = try EnvelopeIndex.open()
        allMailboxes = try index.mailboxes()
        mailboxByURL = Dictionary(uniqueKeysWithValues: allMailboxes.map { ($0.url, $0) })
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

    private func mailboxRef(forURL url: String?) -> MailboxRef? {
        url.flatMap { mailboxByURL[$0] }
    }

    // MARK: - Row mapping

    /// Shared row -> message summary mapping (the `messages` command shape).
    private func summaryDict(_ row: [String: Any], includeJunkAndAttachments: Bool,
                             includeLocation: Bool) -> [String: Any] {
        let mailbox = mailboxRef(forURL: row["mailbox_url"] as? String)
        var dict: [String: Any] = [
            "messageId": stripAngleBrackets(row["message_id"] as? String ?? ""),
            "sender": formatAddress(address: row["sender_address"] as? String ?? "",
                                    comment: row["sender_comment"] as? String ?? ""),
            "subject": fullSubject(prefix: row["subject_prefix"] as? String,
                                   subject: row["subject"] as? String),
            "dateReceived": (row["date_received"] as? Int64).map { isoStringFromEpoch(Double($0)) } ?? NSNull(),
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

    func accounts() -> [String: Any] {
        let names = index.accountNames()
        var seen: Set<String> = []
        var result: [[String: Any]] = []
        for mailbox in allMailboxes where mailbox.scheme == "imap" || mailbox.scheme == "ews" {
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

    func messages(mailbox: String, account: String?, limit: Int, filter: String?) throws -> [String: Any] {
        let refs = try resolveMailboxes(account: account, mailbox: mailbox)
        guard !refs.isEmpty else {
            throw EnvelopeIndexError.notFound("Mailbox not found: \(mailbox)")
        }
        var messageFilter = EnvelopeIndex.MessageFilter(mailboxRowIDs: refs.map { $0.rowid })
        messageFilter.unreadOnly = filter == "unread"
        messageFilter.flaggedOnly = filter == "flagged"

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

    func get(id: String, includeSource: Bool) throws -> [String: Any] {
        var rows: [[String: Any]] = []
        for candidate in messageIDCandidates(id) {
            rows = try index.findMessage(messageIDHeader: candidate)
            if !rows.isEmpty { break }
        }
        guard let row = rows.first, let rowid = row["rowid"] as? Int64 else {
            throw EnvelopeIndexError.notFound("Message not found: \(id)")
        }
        guard let mailbox = mailboxRef(forURL: row["mailbox_url"] as? String),
              let emlxURL = index.emlxPath(forMessageRowID: rowid, mailbox: mailbox) else {
            // Message metadata exists but the body isn't on disk (not yet
            // downloaded); the JXA engine can still fetch it from Mail.app.
            throw EnvelopeIndexError.notAvailable("Local .emlx not found for message; body requires the JXA engine")
        }

        let emlx = try readEmlx(at: emlxURL)
        var message = summaryDict(row, includeJunkAndAttachments: true, includeLocation: true)
        message["dateSent"] = (row["date_sent"] as? Int64).flatMap { $0 > 0 ? isoStringFromEpoch(Double($0)) : nil } ?? NSNull()
        message["replyTo"] = emlx.header("Reply-To") ?? message["sender"] ?? ""
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

        if includeSource, let raw = try? Data(contentsOf: emlxURL) {
            // Skip the byte-count line; the remainder starts with the RFC 822 source.
            if let newline = raw.firstIndex(of: 0x0A) {
                message["source"] = decodeText(Data(raw[raw.index(after: newline)...]), charset: "utf-8")
            }
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
