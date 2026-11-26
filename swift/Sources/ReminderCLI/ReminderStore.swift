import ArgumentParser
import Foundation
import SQLite3

// Read-only access to the Reminders Core Data store, for the metadata EventKit does not
// expose: sections, subtasks, tags, flags, urgent state, rich links and attachments.
//
// The store is written by remindd and synced through CloudKit. This file never writes it:
// every connection is opened SQLITE_OPEN_READONLY with `PRAGMA query_only`. Writes that
// change this metadata go through ReminderKit (see PrivateWrites.swift), never SQLite.
//
// The store lives in the Reminders group container, which macOS protects with Full Disk
// Access. Without it the open fails, and callers report that instead of failing the read:
// EventKit still answers every read command, only the extra fields are missing.
//
// Core Data names relationship columns by model order (ZREMINDER1, ZREMINDER2, ...) and
// numbers entities alphabetically per model version, so neither is hardcoded. Entity
// numbers come from Z_PRIMARYKEY by name, and the column linking each object entity to
// its reminder is probed from the data.

enum ReminderStoreError: Error, LocalizedError {
    case unavailable(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let msg): return msg
        case .queryFailed(let msg): return msg
        }
    }
}

private let SQLITE_TRANSIENT_STORE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One read-only connection to one `Data-*.sqlite` file.
final class ReminderStoreDatabase {
    private var db: OpaquePointer?
    let path: URL
    private var columnCache: [String: Set<String>] = [:]
    private var entityCache: [String: Int64]?
    private var relationshipCache: [String: String?] = [:]

    init(path: URL) throws {
        self.path = path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close_v2(handle) }
            throw ReminderStoreError.unavailable("Cannot open Reminders store read-only: \(msg)")
        }
        db = handle
        sqlite3_busy_timeout(handle, 1000)
        sqlite3_exec(handle, "PRAGMA query_only = 1", nil, nil, nil)
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    enum Bind {
        case int(Int64)
        case text(String)
    }

    /// Rows keyed by column name. NULLs are omitted; BLOBs come back as `Data`.
    func query(_ sql: String, _ binds: [Bind] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ReminderStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, bind) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch bind {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_STORE)
            }
        }
        var rows: [[String: Any]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw ReminderStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            var row: [String: Any] = [:]
            for col in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, col))
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, col)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, col)
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(stmt, col) { row[name] = String(cString: text) }
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(stmt, col))
                    if count > 0, let bytes = sqlite3_column_blob(stmt, col) {
                        row[name] = Data(bytes: bytes, count: count)
                    }
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    func columns(_ table: String) -> Set<String> {
        if let cached = columnCache[table] { return cached }
        let names = (try? query("PRAGMA table_info(\(table))"))?.compactMap { $0["name"] as? String } ?? []
        let set = Set(names)
        columnCache[table] = set
        return set
    }

    func hasTable(_ table: String) -> Bool { !columns(table).isEmpty }

    /// Core Data entity number for an entity name, from Z_PRIMARYKEY.
    func entity(_ name: String) -> Int64? {
        if entityCache == nil {
            var map: [String: Int64] = [:]
            for row in (try? query("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY")) ?? [] {
                if let ent = row["Z_ENT"] as? Int64, let n = row["Z_NAME"] as? String { map[n] = ent }
            }
            entityCache = map
        }
        return entityCache?[name]
    }

    /// The ZREMCDOBJECT column that links rows of `entityName` to their reminder.
    /// Returns nil when no row of that entity points at a reminder, which also means there
    /// is nothing of that kind to report.
    func reminderRelationshipColumn(for entityName: String) -> String? {
        if let cached = relationshipCache[entityName] { return cached }
        var found: String?
        if let ent = entity(entityName) {
            let available = columns("ZREMCDOBJECT")
            let candidates = ["ZREMINDER"] + (1...9).map { "ZREMINDER\($0)" }
            for column in candidates where available.contains(column) {
                let hit = (try? query(
                    "SELECT 1 AS hit FROM ZREMCDOBJECT WHERE Z_ENT = ? AND \(column) IS NOT NULL LIMIT 1",
                    [.int(ent)])) ?? []
                if !hit.isEmpty { found = column; break }
            }
        }
        relationshipCache[entityName] = found
        return found
    }

    /// `column` when the table has it, else `NULL AS column`, so a schema drift drops one
    /// field instead of failing the whole read.
    func select(_ column: String, from table: String, prefix: String = "", alias: String? = nil) -> String {
        let name = alias ?? column
        return columns(table).contains(column) ? "\(prefix)\(column) AS \(name)" : "NULL AS \(name)"
    }
}

// MARK: - Value types

struct ReminderSectionRef: Equatable {
    let id: String
    let name: String
    let listId: String

    func toDict() -> [String: Any] { ["id": id, "name": name] }
}

struct ReminderAttachmentInfo: Equatable {
    let type: String        // image, file, audio
    let filename: String?
    let uti: String?
    let size: Int64?
    let width: Int64?
    let height: Int64?
    let path: String?

    func toDict() -> [String: Any] {
        var dict: [String: Any] = ["type": type]
        if let filename { dict["filename"] = filename }
        if let uti { dict["uti"] = uti }
        if let size { dict["size"] = size }
        if let width { dict["width"] = width }
        if let height { dict["height"] = height }
        dict["path"] = path ?? NSNull()
        return dict
    }
}

/// What the Reminders store knows about one reminder beyond EventKit.
struct ReminderMetadata: Equatable {
    var id: String
    var title: String?
    var listId: String?
    var flagged: Bool = false
    var urgent: Bool = false
    var parentId: String?
    var subtaskIds: [String] = []
    var section: ReminderSectionRef?
    var tags: [String] = []
    var richLinks: [String] = []
    var attachments: [ReminderAttachmentInfo] = []
    /// Fields this store's schema cannot supply (`flagged`, `urgent`, `parentId`, `tags`,
    /// `section`). Their values above are placeholders, so they are left out of the JSON and
    /// a private write that would have to verify one refuses to run.
    var unreadable: Set<String> = []

    /// Fields merged into a reminder's JSON. `title` and `listId` stay internal: EventKit
    /// already reports them. Unreadable fields are omitted rather than reported as false or
    /// empty, and listed under `unreadableFields`.
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "richLinks": richLinks,
            "attachments": attachments.map { $0.toDict() },
        ]
        if !unreadable.contains("flagged") { dict["flagged"] = flagged }
        if !unreadable.contains("urgent") { dict["urgent"] = urgent }
        if !unreadable.contains("tags") { dict["tags"] = tags }
        if !unreadable.contains("parentId") {
            dict["parentId"] = parentId ?? NSNull()
            dict["isSubtask"] = parentId != nil
            dict["subtaskIds"] = subtaskIds
        }
        if !unreadable.contains("section") { dict["section"] = section?.toDict() ?? NSNull() }
        if !unreadable.isEmpty { dict["unreadableFields"] = unreadable.sorted() }
        return dict
    }
}

/// Stands in, under strict resolution, for a membership whose entries disagree and cannot be
/// ordered. It is not a section ID, so a verification comparing memberships sees it change.
let undecidedSectionMembership = "?undecided"

// MARK: - Section memberships

/// One entry of a list's `ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA` JSON.
struct SectionMembershipEntry {
    let memberID: String
    let groupID: String?
    let isObsolete: Bool
    let modifiedOn: Double?
}

/// Which section each reminder is effectively in, from a list's membership JSON.
///
/// ReminderKit keeps one membership per member; when entries for the same member disagree
/// the newest `modifiedOn` wins, and a newest obsolete entry means "no section". When dates
/// cannot order a disagreement, `strict` (write verification) returns
/// `undecidedSectionMembership` rather than a guess, and display keeps the last live entry.
/// Keys are uppercased member IDs.
func effectiveSectionMemberships(_ data: Data?, strict: Bool = false) -> [String: String?] {
    guard let data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = object["memberships"] as? [[String: Any]] else { return [:] }

    var byMember: [String: [SectionMembershipEntry]] = [:]
    var order: [String] = []
    for item in raw {
        guard let member = item["memberID"] as? String, !member.isEmpty else { continue }
        let key = member.uppercased()
        let entry = SectionMembershipEntry(
            memberID: member,
            groupID: (item["groupID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isObsolete: (item["isObsolete"] as? Bool) ?? false,
            modifiedOn: (item["modifiedOn"] as? NSNumber).flatMap {
                CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue
            })
        if byMember[key] == nil { order.append(key) }
        byMember[key, default: []].append(entry)
    }

    func group(_ entry: SectionMembershipEntry) -> String? {
        entry.isObsolete ? nil : entry.groupID
    }
    func agree(_ entries: [SectionMembershipEntry]) -> Bool {
        Set(entries.map { (group($0) ?? "").uppercased() }).count == 1
    }
    func undecided(_ entries: [SectionMembershipEntry]) -> String? {
        strict ? undecidedSectionMembership : entries.reversed().compactMap(group).first
    }

    var resolved: [String: String?] = [:]
    for key in order {
        var entries = byMember[key]!
        if !agree(entries) {
            let dates = entries.compactMap(\.modifiedOn)
            guard dates.count == entries.count, let newestDate = dates.max() else {
                resolved[key] = .some(undecided(entries))
                continue
            }
            let newest = entries.filter { $0.modifiedOn == newestDate }
            if !agree(newest) {
                resolved[key] = .some(undecided(newest))
                continue
            }
            entries = newest
        }
        resolved[key] = .some(group(entries.last!))
    }
    return resolved
}

// MARK: - Store

/// The Reminders stores on this Mac, read-only. One file per account; `Data-local.sqlite`
/// and empty account stores are skipped.
final class ReminderMetadataStore {
    let databases: [ReminderStoreDatabase]
    private let attachmentRoots: [URL]
    private var attachmentIndex: [String: String]?

    static let defaultStoresDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores")

    static let fullDiskAccessHint =
        "Sections, subtasks, tags, flags, urgent state, rich links and attachments are read from "
        + "the Reminders database, which macOS protects with Full Disk Access. Grant Full Disk "
        + "Access to the app that runs reminder-cli (your terminal, or Apple PIM Helper.app when "
        + "the plugin routes through it) in System Settings > Privacy & Security > Full Disk Access."

    /// Open every readable account store. Throws `.unavailable` with a reason when none can
    /// be read, which is what happens without Full Disk Access.
    static func open(storesDirectory: URL? = nil) throws -> ReminderMetadataStore {
        let dir = storesDirectory
            ?? ProcessInfo.processInfo.environment["APPLE_PIM_REMINDERS_STORE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? defaultStoresDirectory
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        } catch {
            throw ReminderStoreError.unavailable(
                "Cannot read the Reminders database directory. " + fullDiskAccessHint)
        }
        let candidates = entries
            .filter { $0.lastPathComponent.hasPrefix("Data-") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var databases: [ReminderStoreDatabase] = []
        var lastError: Error?
        for url in candidates {
            do {
                let db = try ReminderStoreDatabase(path: url)
                guard db.hasTable("ZREMCDREMINDER"), db.hasTable("ZREMCDBASELIST") else { continue }
                let count = (try? db.query("SELECT COUNT(*) AS n FROM ZREMCDBASELIST"))?.first?["n"] as? Int64 ?? 0
                if count > 0 { databases.append(db) }
            } catch {
                lastError = error
            }
        }
        guard !databases.isEmpty else {
            if let lastError {
                throw ReminderStoreError.unavailable(
                    "\(lastError.localizedDescription). " + fullDiskAccessHint)
            }
            throw ReminderStoreError.unavailable(
                "No Reminders database found. Is iCloud Reminders enabled? " + fullDiskAccessHint)
        }
        let filesRoot = dir.deletingLastPathComponent().appendingPathComponent("Files")
        return ReminderMetadataStore(databases: databases, attachmentFilesRoot: filesRoot)
    }

    init(databases: [ReminderStoreDatabase], attachmentFilesRoot: URL? = nil) {
        self.databases = databases
        if let root = attachmentFilesRoot,
           let accounts = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            attachmentRoots = accounts.map { $0.appendingPathComponent("Attachments") }
        } else {
            attachmentRoots = []
        }
    }

    // MARK: Reminders

    /// Metadata for the given EventKit reminder identifiers (`calendarItemIdentifier`, which
    /// is the store's ZCKIDENTIFIER). Unknown IDs are absent from the result. Keys are the
    /// IDs as passed in.
    func metadata(for ids: [String]) throws -> [String: ReminderMetadata] {
        guard !ids.isEmpty else { return [:] }
        var byUpper: [String: String] = [:]
        for id in ids { byUpper[id.uppercased()] = id }
        var result: [String: ReminderMetadata] = [:]
        for db in databases {
            let found = try metadata(in: db, ids: Array(byUpper.keys))
            for (upper, meta) in found {
                guard let original = byUpper[upper], result[original] == nil else { continue }
                var copy = meta
                copy.id = original
                result[original] = copy
            }
        }
        return result
    }

    private func chunks<T>(_ array: [T], size: Int = 400) -> [[T]] {
        stride(from: 0, to: array.count, by: size).map { Array(array[$0..<min($0 + size, array.count)]) }
    }

    private func placeholders(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }

    private func metadata(in db: ReminderStoreDatabase, ids: [String]) throws -> [String: ReminderMetadata] {
        let t = "ZREMCDREMINDER"
        var unreadable: Set<String> = []
        if !db.columns(t).contains("ZFLAGGED") { unreadable.insert("flagged") }
        if !db.columns(t).contains("ZISURGENTSTATEENABLEDFORCURRENTUSER") { unreadable.insert("urgent") }
        if !db.columns(t).contains("ZPARENTREMINDER") { unreadable.insert("parentId") }
        if db.entity("REMCDHashtag") == nil { unreadable.insert("tags") }
        if !db.hasTable("ZREMCDBASESECTION") || !db.columns("ZREMCDBASELIST").contains("ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA") {
            unreadable.insert("section")
        }
        var rowsByPK: [Int64: ReminderMetadata] = [:]
        var listPKByReminderPK: [Int64: Int64] = [:]

        for chunk in chunks(ids) {
            let sql = """
                SELECT r.Z_PK AS pk, r.ZCKIDENTIFIER AS ckid, \(db.select("ZTITLE", from: t, prefix: "r.", alias: "title")),
                \(db.select("ZFLAGGED", from: t, prefix: "r.", alias: "flagged")),
                \(db.select("ZISURGENTSTATEENABLEDFORCURRENTUSER", from: t, prefix: "r.", alias: "urgent")),
                \(db.select("ZLIST", from: t, prefix: "r.", alias: "listpk")),
                (SELECT l.ZCKIDENTIFIER FROM ZREMCDBASELIST l WHERE l.Z_PK = r.ZLIST) AS listckid,
                \(db.columns(t).contains("ZPARENTREMINDER")
                    ? "(SELECT p.ZCKIDENTIFIER FROM ZREMCDREMINDER p WHERE p.Z_PK = r.ZPARENTREMINDER AND p.ZMARKEDFORDELETION = 0) AS parentckid"
                    : "NULL AS parentckid")
                FROM ZREMCDREMINDER r
                WHERE r.ZMARKEDFORDELETION = 0 AND upper(r.ZCKIDENTIFIER) IN (\(placeholders(chunk.count)))
                """
            for row in try db.query(sql, chunk.map { .text($0) }) {
                guard let pk = row["pk"] as? Int64, let ckid = row["ckid"] as? String else { continue }
                var meta = ReminderMetadata(id: ckid.uppercased())
                meta.title = row["title"] as? String
                meta.listId = row["listckid"] as? String
                meta.flagged = (row["flagged"] as? Int64 ?? 0) != 0
                meta.urgent = (row["urgent"] as? Int64 ?? 0) != 0
                meta.parentId = row["parentckid"] as? String
                meta.unreadable = unreadable
                rowsByPK[pk] = meta
                if let listPK = row["listpk"] as? Int64 { listPKByReminderPK[pk] = listPK }
            }
        }
        guard !rowsByPK.isEmpty else { return [:] }
        let pks = Array(rowsByPK.keys)

        // Subtasks: children whose ZPARENTREMINDER is one of these reminders.
        if db.columns(t).contains("ZPARENTREMINDER") {
            for chunk in chunks(pks) {
                let sql = """
                    SELECT ZPARENTREMINDER AS parent, ZCKIDENTIFIER AS ckid FROM ZREMCDREMINDER
                    WHERE ZMARKEDFORDELETION = 0 AND ZPARENTREMINDER IN (\(placeholders(chunk.count)))
                    ORDER BY Z_PK
                    """
                for row in try db.query(sql, chunk.map { .int($0) }) {
                    if let parent = row["parent"] as? Int64, let ckid = row["ckid"] as? String {
                        rowsByPK[parent]?.subtaskIds.append(ckid)
                    }
                }
            }
        }

        // Tags.
        if let ent = db.entity("REMCDHashtag"), let rel = db.reminderRelationshipColumn(for: "REMCDHashtag") {
            let labelJoin = db.hasTable("ZREMCDHASHTAGLABEL") && db.columns("ZREMCDOBJECT").contains("ZHASHTAGLABEL")
            let nameExpr = labelJoin
                ? "COALESCE(h.ZNAME, \(db.columns("ZREMCDOBJECT").contains("ZNAME") ? "o.ZNAME" : "NULL"))"
                : (db.columns("ZREMCDOBJECT").contains("ZNAME") ? "o.ZNAME" : "NULL")
            for chunk in chunks(pks) {
                let sql = """
                    SELECT o.\(rel) AS owner, \(nameExpr) AS name FROM ZREMCDOBJECT o
                    \(labelJoin ? "LEFT JOIN ZREMCDHASHTAGLABEL h ON o.ZHASHTAGLABEL = h.Z_PK" : "")
                    WHERE o.Z_ENT = ? AND o.ZMARKEDFORDELETION = 0 AND o.\(rel) IN (\(placeholders(chunk.count)))
                    ORDER BY o.Z_PK
                    """
                for row in try db.query(sql, [.int(ent)] + chunk.map { .int($0) }) {
                    if let owner = row["owner"] as? Int64, let name = row["name"] as? String, !name.isEmpty,
                       rowsByPK[owner]?.tags.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) == false {
                        rowsByPK[owner]?.tags.append(name)
                    }
                }
            }
        }

        // Rich links.
        if let ent = db.entity("REMCDURLAttachment"), let rel = db.reminderRelationshipColumn(for: "REMCDURLAttachment"),
           db.columns("ZREMCDOBJECT").contains("ZURL") {
            for chunk in chunks(pks) {
                let sql = """
                    SELECT \(rel) AS owner, ZURL AS url FROM ZREMCDOBJECT
                    WHERE Z_ENT = ? AND ZMARKEDFORDELETION = 0 AND ZURL IS NOT NULL AND ZURL != ''
                    AND \(rel) IN (\(placeholders(chunk.count))) ORDER BY Z_PK
                    """
                for row in try db.query(sql, [.int(ent)] + chunk.map { .int($0) }) {
                    if let owner = row["owner"] as? Int64, let url = row["url"] as? String {
                        rowsByPK[owner]?.richLinks.append(url)
                    }
                }
            }
        }

        // Attachments (metadata only).
        let o = "ZREMCDOBJECT"
        for (entityName, type) in [("REMCDImageAttachment", "image"), ("REMCDFileAttachment", "file"), ("REMCDAudioAttachment", "audio")] {
            guard let ent = db.entity(entityName), let rel = db.reminderRelationshipColumn(for: entityName) else { continue }
            for chunk in chunks(pks) {
                let sql = """
                    SELECT \(rel) AS owner, \(db.select("ZFILENAME", from: o, alias: "filename")),
                    \(db.select("ZUTI", from: o, alias: "uti")), \(db.select("ZFILESIZE", from: o, alias: "size")),
                    \(db.select("ZWIDTH", from: o, alias: "width")), \(db.select("ZHEIGHT", from: o, alias: "height")),
                    \(db.select("ZSHA512SUM", from: o, alias: "sha"))
                    FROM ZREMCDOBJECT WHERE Z_ENT = ? AND ZMARKEDFORDELETION = 0
                    AND \(rel) IN (\(placeholders(chunk.count))) ORDER BY Z_PK
                    """
                for row in try db.query(sql, [.int(ent)] + chunk.map { .int($0) }) {
                    guard let owner = row["owner"] as? Int64 else { continue }
                    let sha = row["sha"] as? String
                    rowsByPK[owner]?.attachments.append(ReminderAttachmentInfo(
                        type: type,
                        filename: row["filename"] as? String,
                        uti: row["uti"] as? String,
                        size: row["size"] as? Int64,
                        width: row["width"] as? Int64,
                        height: row["height"] as? Int64,
                        path: sha.flatMap { attachmentPath(sha: $0) }))
                }
            }
        }

        // Sections, from each list's membership JSON.
        let listPKs = Array(Set(listPKByReminderPK.values))
        let sectionsByList = try sectionsAndMemberships(in: db, listPKs: listPKs)
        for (pk, listPK) in listPKByReminderPK {
            guard let info = sectionsByList[listPK], let ckid = rowsByPK[pk]?.id else { continue }
            if let groupID = info.memberships[ckid] ?? nil,
               let section = info.sections.first(where: { $0.id.caseInsensitiveCompare(groupID) == .orderedSame }) {
                rowsByPK[pk]?.section = section
            }
        }

        var result: [String: ReminderMetadata] = [:]
        for meta in rowsByPK.values { result[meta.id] = meta }
        return result
    }

    private struct ListSectionInfo {
        var sections: [ReminderSectionRef]
        var memberships: [String: String?]
    }

    private func sectionsAndMemberships(in db: ReminderStoreDatabase, listPKs: [Int64], strict: Bool = false) throws -> [Int64: ListSectionInfo] {
        guard !listPKs.isEmpty, db.hasTable("ZREMCDBASESECTION") else { return [:] }
        var info: [Int64: ListSectionInfo] = [:]
        let lcols = db.columns("ZREMCDBASELIST")
        for chunk in chunks(listPKs) {
            let membershipCol = lcols.contains("ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA")
                ? "ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA" : "NULL"
            let lists = try db.query(
                "SELECT Z_PK AS pk, ZCKIDENTIFIER AS ckid, \(membershipCol) AS memberships FROM ZREMCDBASELIST WHERE Z_PK IN (\(placeholders(chunk.count)))",
                chunk.map { .int($0) })
            for row in lists {
                guard let pk = row["pk"] as? Int64 else { continue }
                let data = (row["memberships"] as? Data) ?? (row["memberships"] as? String)?.data(using: .utf8)
                info[pk] = ListSectionInfo(
                    sections: [],
                    memberships: effectiveSectionMemberships(data, strict: strict))
            }
            let scols = db.columns("ZREMCDBASESECTION")
            let order = scols.contains("ZCREATIONDATE") ? "ORDER BY s.ZCREATIONDATE, s.Z_PK" : "ORDER BY s.Z_PK"
            let sections = try db.query("""
                SELECT s.ZLIST AS listpk, s.ZCKIDENTIFIER AS ckid, s.ZDISPLAYNAME AS name,
                (SELECT l.ZCKIDENTIFIER FROM ZREMCDBASELIST l WHERE l.Z_PK = s.ZLIST) AS listckid
                FROM ZREMCDBASESECTION s
                WHERE s.ZMARKEDFORDELETION = 0 AND s.ZLIST IN (\(placeholders(chunk.count))) \(order)
                """, chunk.map { .int($0) })
            for row in sections {
                guard let listPK = row["listpk"] as? Int64, let ckid = row["ckid"] as? String else { continue }
                info[listPK, default: ListSectionInfo(sections: [], memberships: [:])].sections.append(
                    ReminderSectionRef(id: ckid, name: (row["name"] as? String) ?? "",
                                       listId: (row["listckid"] as? String) ?? ""))
            }
        }
        return info
    }

    // MARK: Lists

    /// Sections of the given EventKit list identifiers (`calendarIdentifier`, the list's
    /// ZCKIDENTIFIER), keyed by the IDs as passed in.
    func sections(forLists listIds: [String]) throws -> [String: [ReminderSectionRef]] {
        var byUpper: [String: String] = [:]
        for id in listIds { byUpper[id.uppercased()] = id }
        var result: [String: [ReminderSectionRef]] = [:]
        for db in databases {
            for chunk in chunks(Array(byUpper.keys)) {
                let rows = try db.query(
                    "SELECT Z_PK AS pk, ZCKIDENTIFIER AS ckid FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND upper(ZCKIDENTIFIER) IN (\(placeholders(chunk.count)))",
                    chunk.map { .text($0) })
                var ckidByPK: [Int64: String] = [:]
                for row in rows {
                    if let pk = row["pk"] as? Int64, let ckid = row["ckid"] as? String { ckidByPK[pk] = ckid }
                }
                let info = try sectionsAndMemberships(in: db, listPKs: Array(ckidByPK.keys))
                for (pk, ckid) in ckidByPK {
                    guard let original = byUpper[ckid.uppercased()], result[original] == nil else { continue }
                    result[original] = info[pk]?.sections ?? []
                }
            }
        }
        return result
    }

    /// Effective (strict) section membership of every reminder in a list, keyed by uppercased
    /// reminder ID. Used to prove a section write changed only the reminder it targeted.
    func strictSectionMemberships(forList listId: String) throws -> [String: String?] {
        for db in databases {
            let rows = try db.query(
                "SELECT Z_PK AS pk FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND upper(ZCKIDENTIFIER) = ?",
                [.text(listId.uppercased())])
            guard let pk = rows.first?["pk"] as? Int64 else { continue }
            let info = try sectionsAndMemberships(in: db, listPKs: [pk], strict: true)
            return info[pk]?.memberships ?? [:]
        }
        return [:]
    }

    // MARK: Attachments

    private func attachmentPath(sha: String) -> String? {
        if attachmentIndex == nil {
            var index: [String: String] = [:]
            for root in attachmentRoots {
                for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                    let stem = file.deletingPathExtension().lastPathComponent.lowercased()
                    index[stem] = file.path
                }
            }
            attachmentIndex = index
        }
        return attachmentIndex?[sha.lowercased()]
    }
}

// MARK: - Merging into command output

/// How read commands use the Reminders store.
enum MetadataMode: String, CaseIterable {
    /// Read the store when it opens; otherwise say why in the output and carry on.
    case auto
    /// Skip the store entirely.
    case off
    /// Fail the command when the store cannot be read.
    case required
}

/// Opens the store at most once per process.
enum SharedReminderStore {
    private static var cached: Result<ReminderMetadataStore, Error>?

    static func get() -> Result<ReminderMetadataStore, Error> {
        if let cached { return cached }
        let result = Result { try ReminderMetadataStore.open() }
        cached = result
        return result
    }
}

/// Adds store metadata to reminder dictionaries that carry an `id`. Returns the enriched
/// reminders and the `metadata` status object for the response, or nil for `.off`.
func enrichReminders(_ reminders: [[String: Any]], mode: MetadataMode,
                     store: Result<ReminderMetadataStore, Error>? = nil) throws -> ([[String: Any]], [String: Any]?) {
    guard mode != .off else { return (reminders, nil) }
    switch store ?? SharedReminderStore.get() {
    case .failure(let error):
        if mode == .required { throw error }
        return (reminders, ["available": false, "reason": error.localizedDescription])
    case .success(let opened):
        do {
            let ids = reminders.compactMap { $0["id"] as? String }
            let found = try opened.metadata(for: ids)
            let enriched = reminders.map { reminder -> [String: Any] in
                guard let id = reminder["id"] as? String, let meta = found[id] else { return reminder }
                return reminder.merging(meta.toDict()) { current, _ in current }
            }
            return (enriched, ["available": true, "source": "reminders-store"])
        } catch {
            if mode == .required { throw error }
            return (reminders, ["available": false, "reason": "Reminders store query failed: \(error.localizedDescription)"])
        }
    }
}

/// Adds each list's sections (from the store) to list dictionaries that carry an `id`.
func enrichLists(_ lists: [[String: Any]], mode: MetadataMode,
                 store: Result<ReminderMetadataStore, Error>? = nil) throws -> ([[String: Any]], [String: Any]?) {
    guard mode != .off else { return (lists, nil) }
    switch store ?? SharedReminderStore.get() {
    case .failure(let error):
        if mode == .required { throw error }
        return (lists, ["available": false, "reason": error.localizedDescription])
    case .success(let opened):
        do {
            let sections = try opened.sections(forLists: lists.compactMap { $0["id"] as? String })
            let enriched = lists.map { list -> [String: Any] in
                guard let id = list["id"] as? String else { return list }
                var copy = list
                copy["sections"] = (sections[id] ?? []).map { $0.toDict() }
                return copy
            }
            return (enriched, ["available": true, "source": "reminders-store"])
        } catch {
            if mode == .required { throw error }
            return (lists, ["available": false, "reason": "Reminders store query failed: \(error.localizedDescription)"])
        }
    }
}

extension MetadataMode: ExpressibleByArgument {}

struct MetadataOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp(
        "Read sections, subtasks, tags, flags, urgent state, rich links and attachments from the "
        + "Reminders database (needs Full Disk Access): auto (default; reports why when unavailable "
        + "and returns EventKit fields only), off, or required (fail when unavailable)"))
    var metadata: MetadataMode = .auto
}
