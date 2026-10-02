import Foundation
import SQLite3

// Read-only access to the local Calendar store, used only to recover the availability of
// subscribed-calendar events that EventKit reports as `notSupported`. EventKit still
// finds and expands every event; the store supplies nothing but that one value.
// Requires Full Disk Access, like Mail's Envelope Index; callers keep EventKit's value
// when the store can't be opened (`auth-status` reports `calendarStore.readable`).

enum CalendarStoreError: Error, LocalizedError {
    case notAvailable(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable(let msg): return msg
        case .queryFailed(let msg): return msg
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class CalendarStore {
    /// One row per (calendar, item) identity: `EKCalendar.calendarIdentifier` is
    /// `Calendar.UUID` and `EKEvent.calendarItemIdentifier` is `CalendarItem.UUID`.
    /// `LIMIT 2` is enough to tell a unique row from a duplicate.
    private static let lookupSQL = """
        SELECT i.availability, i.external_rep
        FROM CalendarItem i JOIN Calendar c ON c.ROWID = i.calendar_id
        WHERE c.UUID = ?1 AND i.UUID = ?2
        LIMIT 2
        """

    static func defaultPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb")
    }

    let path: URL
    private var db: OpaquePointer?

    /// Opens read-only and starts the one read transaction every lookup through this
    /// instance shares, so a request sees a single snapshot of the store.
    /// Throws `notAvailable` when the file cannot be opened or read, or lacks the columns
    /// the lookup needs.
    init(path: URL) throws {
        self.path = path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close_v2(handle) }
            throw CalendarStoreError.notAvailable("Cannot open the Calendar store read-only: \(msg)")
        }
        db = handle
        sqlite3_busy_timeout(handle, 500)
        exec("PRAGMA query_only = 1")

        // The schema check: the lookup must prepare against this store.
        var stmt: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, Self.lookupSQL, -1, &stmt, nil)
        sqlite3_finalize(stmt)
        // One snapshot per request. A deferred transaction takes it at the first read, so
        // read now. This store answers many lookups per request.
        guard prepared == SQLITE_OK,
              exec("BEGIN") == SQLITE_OK,
              exec("SELECT count(*) FROM Calendar") == SQLITE_OK
        else {
            let msg = String(cString: sqlite3_errmsg(handle))
            sqlite3_close_v2(handle)
            db = nil
            throw CalendarStoreError.notAvailable("Cannot read the Calendar store: \(msg)")
        }
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    /// `auth-status` view of an opened store. Opening it already ran the lookup's prepare,
    /// so readable means the lookup can run.
    func authStatusInfo() -> [String: Any] {
        ["readable": true, "path": path.path]
    }

    @discardableResult
    private func exec(_ sql: String) -> Int32 {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// The stored availability of one item, or nil when there is no unique row or the row
    /// holds nothing usable. Throws only when the store itself fails mid-read.
    func storedAvailability(calendarUUID: String, itemUUID: String) throws -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.lookupSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CalendarStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, calendarUUID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, itemUUID, -1, SQLITE_TRANSIENT)

        var rows: [(column: Int64?, externalRep: Data?)] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw CalendarStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            let column: Int64? = sqlite3_column_type(stmt, 0) == SQLITE_INTEGER
                ? sqlite3_column_int64(stmt, 0) : nil
            // Type first: sqlite3_column_bytes converts a non-BLOB value. An oversized blob
            // is never copied; it reads as "no metadata", like any archive StoredShowAs refuses.
            var rep: Data?
            if sqlite3_column_type(stmt, 1) == SQLITE_BLOB {
                let size = Int(sqlite3_column_bytes(stmt, 1))
                if size <= StoredShowAs.maxArchiveBytes, let bytes = sqlite3_column_blob(stmt, 1) {
                    rep = Data(bytes: bytes, count: size)
                }
            }
            rows.append((column, rep))
        }
        guard rows.count == 1, let row = rows.first else { return nil }
        return StoredShowAs.resolve(column: row.column, externalRep: row.externalRep)
    }
}
