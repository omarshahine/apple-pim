import Foundation
import SQLite3

// Direct read-only access to Apple Mail's Envelope Index SQLite database.
// This is the fast path for read commands: no Mail.app round-trip, works even
// when Mail is not running. Requires Full Disk Access; callers fall back to
// JXA when the database can't be opened.

enum EnvelopeIndexError: Error, LocalizedError {
    case notAvailable(String)
    case queryFailed(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable(let msg): return msg
        case .queryFailed(let msg): return msg
        case .notFound(let msg): return msg
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class EnvelopeIndex {
    private var db: OpaquePointer?
    /// e.g. ~/Library/Mail/V10
    let versionDir: URL

    // MARK: - Discovery / lifecycle

    /// Locate the newest ~/Library/Mail/V*/MailData/Envelope Index.
    static func discoverDatabase(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let mailDir = home.appendingPathComponent("Library/Mail")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: mailDir, includingPropertiesForKeys: nil) else { return nil }
        let versioned = entries.compactMap { url -> (Int, URL)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("V"), let version = Int(name.dropFirst()) else { return nil }
            return (version, url)
        }
        for (_, dir) in versioned.sorted(by: { $0.0 > $1.0 }) {
            let dbPath = dir.appendingPathComponent("MailData/Envelope Index")
            if FileManager.default.isReadableFile(atPath: dbPath.path) {
                return dbPath
            }
        }
        return nil
    }

    static func open(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> EnvelopeIndex {
        guard let dbPath = discoverDatabase(home: home) else {
            throw EnvelopeIndexError.notAvailable(
                "Envelope Index not found or not readable under ~/Library/Mail/V*. "
                + "The SQLite read path requires Full Disk Access.")
        }
        return try EnvelopeIndex(databasePath: dbPath)
    }

    init(databasePath: URL) throws {
        versionDir = databasePath.deletingLastPathComponent().deletingLastPathComponent()
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(databasePath.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close_v2(handle) }
            throw EnvelopeIndexError.notAvailable("Cannot open Envelope Index read-only: \(msg)")
        }
        db = handle
        sqlite3_busy_timeout(handle, 500)
        exec("PRAGMA query_only = 1")
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Low-level query

    /// Bindable parameter: Int64, Double, or String.
    enum Bind {
        case int(Int64)
        case real(Double)
        case text(String)
    }

    /// Run a query, returning rows keyed by column name. NULLs are omitted.
    func query(_ sql: String, _ binds: [Bind] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw EnvelopeIndexError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (i, bind) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch bind {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            }
        }

        var rows: [[String: Any]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw EnvelopeIndexError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            var row: [String: Any] = [:]
            for col in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, col))
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, col)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, col)
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(stmt, col) {
                        row[name] = String(cString: text)
                    }
                default: break // NULL and BLOB omitted
                }
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - Mailboxes / accounts

    func mailboxes() throws -> [MailboxRef] {
        try query("SELECT ROWID, url, total_count, unread_count FROM mailboxes").compactMap { row in
            guard let rowid = row["ROWID"] as? Int64, let url = row["url"] as? String else { return nil }
            return parseMailboxRef(
                rowid: rowid, url: url,
                totalCount: Int(row["total_count"] as? Int64 ?? 0),
                unreadCount: Int(row["unread_count"] as? Int64 ?? 0))
        }
    }

    /// Account UUID -> (displayName, userName) via the system Accounts store
    /// (same Full Disk Access umbrella as the mail directory). Best-effort:
    /// returns an empty map when unreadable, and callers fall back to UUIDs.
    private var cachedAccountNames: [String: (name: String, userName: String?)]?

    func accountNames() -> [String: (name: String, userName: String?)] {
        if let cachedAccountNames { return cachedAccountNames }
        var map: [String: (name: String, userName: String?)] = [:]
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Accounts/Accounts4.sqlite").path
        var handle: OpaquePointer?
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle {
            defer { sqlite3_close_v2(handle) }
            var stmt: OpaquePointer?
            let sql = "SELECT ZIDENTIFIER, ZACCOUNTDESCRIPTION, ZUSERNAME FROM ZACCOUNT WHERE ZIDENTIFIER IS NOT NULL"
            if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let idText = sqlite3_column_text(stmt, 0) else { continue }
                    let uuid = String(cString: idText)
                    let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                    let user = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                    map[uuid] = (name: name ?? uuid, userName: user)
                }
            }
        } else if let handle {
            sqlite3_close_v2(handle)
        }
        cachedAccountNames = map
        return map
    }

    /// Resolve a user-supplied account name (display name, user name, or UUID)
    /// to the account UUIDs it matches.
    func accountUUIDs(matching name: String) throws -> [String] {
        let target = name.lowercased()
        let names = accountNames()
        let allUUIDs = Set(try mailboxes().map { $0.accountUUID })
        return allUUIDs.filter { uuid in
            if uuid.lowercased() == target { return true }
            guard let entry = names[uuid] else { return false }
            return entry.name.lowercased() == target || entry.userName?.lowercased() == target
        }.sorted()
    }

    // MARK: - Messages

    private static let messageColumns = """
        m.ROWID AS rowid, g.message_id_header AS message_id,
        a.address AS sender_address, a.comment AS sender_comment,
        m.subject_prefix AS subject_prefix, s.subject AS subject,
        m.date_received AS date_received, m.date_sent AS date_sent,
        m.read AS read, m.flagged AS flagged, b.url AS mailbox_url,
        (SELECT COUNT(*) FROM attachments att WHERE att.message = m.ROWID) AS attachment_count
        """

    private static let messageJoins = """
        FROM messages m
        JOIN message_global_data g ON m.global_message_id = g.ROWID
        JOIN mailboxes b ON m.mailbox = b.ROWID
        LEFT JOIN subjects s ON m.subject = s.ROWID
        LEFT JOIN addresses a ON m.sender = a.ROWID
        """

    struct MessageFilter {
        var mailboxRowIDs: [Int64]?
        var unreadOnly = false
        var flaggedOnly = false
        var sinceEpoch: Double?
        /// LIKE match against subject / sender / both.
        var queryText: String?
        var queryField: String = "all"
    }

    func messages(filter: MessageFilter, limit: Int) throws -> [[String: Any]] {
        var conditions = ["m.deleted = 0", "g.message_id_header IS NOT NULL"]
        var binds: [Bind] = []

        if let rowIDs = filter.mailboxRowIDs {
            guard !rowIDs.isEmpty else { return [] }
            let placeholders = rowIDs.map { _ in "?" }.joined(separator: ",")
            conditions.append("m.mailbox IN (\(placeholders))")
            binds.append(contentsOf: rowIDs.map { Bind.int($0) })
        }
        if filter.unreadOnly { conditions.append("m.read = 0") }
        if filter.flaggedOnly { conditions.append("m.flagged = 1") }
        if let since = filter.sinceEpoch {
            conditions.append("m.date_received >= ?")
            binds.append(.real(since))
        }
        if let text = filter.queryText, !text.isEmpty {
            let like = "%\(text)%"
            switch filter.queryField {
            case "subject":
                conditions.append("s.subject LIKE ?")
                binds.append(.text(like))
            case "sender":
                conditions.append("(a.address LIKE ? OR a.comment LIKE ?)")
                binds.append(.text(like))
                binds.append(.text(like))
            default: // "all": subject OR sender, matching the JXA predicate
                conditions.append("(s.subject LIKE ? OR a.address LIKE ? OR a.comment LIKE ?)")
                binds.append(.text(like))
                binds.append(.text(like))
                binds.append(.text(like))
            }
        }

        let sql = """
            SELECT \(Self.messageColumns)
            \(Self.messageJoins)
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY m.date_received DESC
            LIMIT ?
            """
        binds.append(.int(Int64(limit)))
        return try query(sql, binds)
    }

    /// All non-deleted copies of a message by RFC 2822 Message-ID, newest first.
    func findMessage(messageIDHeader: String) throws -> [[String: Any]] {
        let sql = """
            SELECT \(Self.messageColumns)
            \(Self.messageJoins)
            WHERE g.message_id_header = ? AND m.deleted = 0
            ORDER BY m.date_received DESC
            """
        return try query(sql, [.text(messageIDHeader)])
    }

    /// (to, cc) recipients for a message ROWID. type 0 = to, 1 = cc.
    func recipients(messageRowID: Int64) throws -> (to: [[String: Any]], cc: [[String: Any]]) {
        let rows = try query("""
            SELECT r.type AS type, a.address AS address, a.comment AS comment
            FROM recipients r JOIN addresses a ON r.address = a.ROWID
            WHERE r.message = ? ORDER BY r.position
            """, [.int(messageRowID)])
        var to: [[String: Any]] = []
        var cc: [[String: Any]] = []
        for row in rows {
            let entry: [String: Any] = [
                "name": (row["comment"] as? String) ?? "",
                "address": (row["address"] as? String) ?? "",
            ]
            if (row["type"] as? Int64 ?? 0) == 1 { cc.append(entry) } else { to.append(entry) }
        }
        return (to, cc)
    }

    func attachments(messageRowID: Int64) throws -> [String] {
        try query("SELECT name FROM attachments WHERE message = ? ORDER BY ROWID",
                  [.int(messageRowID)])
            .compactMap { $0["name"] as? String }
    }

    func messageCount() throws -> Int {
        let rows = try query("SELECT COUNT(*) AS n FROM messages WHERE deleted = 0")
        return Int(rows.first?["n"] as? Int64 ?? 0)
    }

    // MARK: - .emlx location

    /// Find the on-disk .emlx file for a message. Layout:
    /// V10/<acctUUID>/<Comp1>.mbox/<Comp2>.mbox/<mailboxUUID>/Data/<digits>/Messages/<rowid>.emlx
    /// where <digits> are the digits of rowid/1000, least-significant last
    /// (see emlxSubpath), and the file may be `<rowid>.partial.emlx`.
    func emlxPath(forMessageRowID rowid: Int64, mailbox: MailboxRef) -> URL? {
        var mboxDir = versionDir.appendingPathComponent(mailbox.accountUUID)
        for component in mailbox.pathComponents {
            mboxDir = mboxDir.appendingPathComponent(component + ".mbox")
        }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: mboxDir, includingPropertiesForKeys: nil) else { return nil }

        let subpath = emlxSubpath(forRowID: rowid).joined(separator: "/")
        // The store directory under the .mbox is a UUID; glob rather than guess.
        for child in children where child.hasDirectoryPath {
            var messagesDir = child.appendingPathComponent("Data")
            if !subpath.isEmpty { messagesDir = messagesDir.appendingPathComponent(subpath) }
            messagesDir = messagesDir.appendingPathComponent("Messages")
            for filename in ["\(rowid).emlx", "\(rowid).partial.emlx"] {
                let candidate = messagesDir.appendingPathComponent(filename)
                if FileManager.default.isReadableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}
