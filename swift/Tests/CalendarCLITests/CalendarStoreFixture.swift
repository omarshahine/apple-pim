import Foundation
import SQLite3

/// Throwaway WAL databases carrying the real `Calendar` / `CalendarItem` column names the
/// reader uses. Never the user's store.
final class CalendarStoreFixture {
    static let calA = "CA1E0000-0000-4000-8000-00000000000A"
    static let calB = "CA1E0000-0000-4000-8000-00000000000B"
    static let itemColumns = "ROWID INTEGER PRIMARY KEY AUTOINCREMENT, calendar_id INTEGER, availability INTEGER, external_rep BLOB, UUID TEXT"

    typealias Item = (calendar: String, item: String, availability: Int64?, externalRep: Data?)

    let dir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("calendarcli-store-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func remove() {
        try? FileManager.default.removeItem(at: dir)
    }

    private struct FixtureError: Error, CustomStringConvertible { let description: String }

    func create(items: [Item], itemColumns: String = CalendarStoreFixture.itemColumns) throws -> URL {
        let path = dir.appendingPathComponent("Calendar-\(UUID().uuidString).sqlitedb")
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK, let db else { throw FixtureError(description: "open") }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw FixtureError(description: String(cString: sqlite3_errmsg(db)))
            }
        }
        try exec("PRAGMA journal_mode = WAL")
        try exec("CREATE TABLE Calendar (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, UUID TEXT)")
        try exec("CREATE TABLE CalendarItem (\(itemColumns))")
        try exec("INSERT INTO Calendar (UUID) VALUES ('\(Self.calA)'), ('\(Self.calB)')")
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for item in items {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO CalendarItem (calendar_id, UUID, availability, external_rep) VALUES ((SELECT ROWID FROM Calendar WHERE UUID = ?), ?, ?, ?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw FixtureError(description: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, item.calendar, -1, transient)
            sqlite3_bind_text(stmt, 2, item.item, -1, transient)
            if let a = item.availability { sqlite3_bind_int64(stmt, 3, a) } else { sqlite3_bind_null(stmt, 3) }
            if let rep = item.externalRep {
                _ = rep.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(rep.count), transient) }
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw FixtureError(description: String(cString: sqlite3_errmsg(db)))
            }
        }
        return path
    }

    /// A second, writing connection: stands in for macOS updating the store.
    func write(_ path: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK, let db else { throw FixtureError(description: "writer open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError(description: String(cString: sqlite3_errmsg(db)))
        }
    }
}
