import Foundation
import XCTest
@testable import CalendarCLI

/// The read-only reader over the local Calendar store, run against throwaway WAL databases
/// that carry the real `Calendar` / `CalendarItem` column names. Never the user's store.
final class CalendarStoreTests: XCTestCase {

    private let calA = CalendarStoreFixture.calA
    private let calB = CalendarStoreFixture.calB
    private let db = CalendarStoreFixture()

    override func tearDown() {
        db.remove()
        super.tearDown()
    }

    // MARK: - Lookup

    func testUniqueRowResolvesThroughTheShowAs() throws {
        let path = try db.create(items: [
            (calA, "ITEM-1", 0, ShowAsFixture.rep(busyStatus: "TENTATIVE")),
            (calA, "ITEM-2", 1, nil),
        ])
        let store = try CalendarStore(path: path)
        XCTAssertEqual(try store.storedAvailability(calendarUUID: calA, itemUUID: "ITEM-1"), "tentative")
        // A row with no metadata answers from its column.
        XCTAssertEqual(try store.storedAvailability(calendarUUID: calA, itemUUID: "ITEM-2"), "free")
    }

    func testMissingRowIsNoAnswer() throws {
        let store = try CalendarStore(path: try db.create(items: [(calA, "ITEM-1", 1, nil)]))
        XCTAssertNil(try store.storedAvailability(calendarUUID: calA, itemUUID: "ITEM-404"))
    }

    func testDuplicateRowIsNoAnswer() throws {
        // Two rows for one identity cannot be told apart, so neither is used.
        let store = try CalendarStore(path: try db.create(items: [
            (calA, "ITEM-1", 1, ShowAsFixture.rep(busyStatus: "FREE")),
            (calA, "ITEM-1", 0, ShowAsFixture.rep(busyStatus: "BUSY")),
        ]))
        XCTAssertNil(try store.storedAvailability(calendarUUID: calA, itemUUID: "ITEM-1"))
    }

    func testItemIsMatchedWithinItsCalendarOnly() throws {
        let store = try CalendarStore(path: try db.create(items: [
            (calB, "ITEM-1", 1, ShowAsFixture.rep(busyStatus: "FREE")),
        ]))
        XCTAssertNil(try store.storedAvailability(calendarUUID: calA, itemUUID: "ITEM-1"))
        XCTAssertEqual(try store.storedAvailability(calendarUUID: calB, itemUUID: "ITEM-1"), "free")
    }

    func testRowWithNothingUsableIsNoAnswer() throws {
        let store = try CalendarStore(path: try db.create(items: [(calA, "ITEM-1", nil, Data("junk".utf8))]))
        XCTAssertNil(try store.storedAvailability(calendarUUID: calA, itemUUID: "ITEM-1"))
    }

    func testNonBlobMetadataIsIgnored() throws {
        // external_rep is a BLOB on every observed row; any other storage class is "no
        // metadata", so the row answers from its column.
        let path = try db.create(items: [(calA, "ITEM-1", 1, nil), (calA, "ITEM-2", 0, nil)])
        try db.write(path, "UPDATE CalendarItem SET external_rep = 12345 WHERE UUID = 'ITEM-1'")
        try db.write(path, "UPDATE CalendarItem SET external_rep = 'FREE' WHERE UUID = 'ITEM-2'")
        let store = try CalendarStore(path: path)
        XCTAssertEqual(try store.storedAvailability(calendarUUID: calA, itemUUID: "ITEM-1"), "free")
        XCTAssertEqual(try store.storedAvailability(calendarUUID: calA, itemUUID: "ITEM-2"), "busy")
    }

    // MARK: - Opening

    func testMissingFileIsNotReadable() {
        XCTAssertThrowsError(try CalendarStore(path: db.dir.appendingPathComponent("absent.sqlitedb")))
    }

    func testSchemaWithoutTheNeededColumnsIsNotReadable() throws {
        // A macOS that renames or drops a column must read as "no store", not fail per event.
        let path = try db.create(items: [], itemColumns: "ROWID INTEGER PRIMARY KEY AUTOINCREMENT, calendar_id INTEGER, UUID TEXT, availability INTEGER")
        XCTAssertThrowsError(try CalendarStore(path: path))
        let status = authStatusPayload(authorization: "authorized", storePath: path)
        XCTAssertEqual((status["calendarStore"] as? [String: Any])?["readable"] as? Bool, false)
    }

    func testStatusReportsAReadableStore() throws {
        let path = try db.create(items: [(calA, "ITEM-1", 1, nil)])
        let status = try CalendarStore(path: path).authStatusInfo()
        XCTAssertEqual(status["readable"] as? Bool, true)
        XCTAssertEqual(status["path"] as? String, path.path)
    }

    func testAuthStatusCarriesStoreReadability() throws {
        let readable = try db.create(items: [])

        let ok = authStatusPayload(authorization: "authorized", storePath: readable)
        XCTAssertEqual(ok["authorization"] as? String, "authorized")
        XCTAssertEqual((ok["calendarStore"] as? [String: Any])?["readable"] as? Bool, true)

        let missing = authStatusPayload(authorization: "authorized",
                                        storePath: db.dir.appendingPathComponent("absent.sqlitedb"))
        XCTAssertEqual((missing["calendarStore"] as? [String: Any])?["readable"] as? Bool, false)
    }

    func testOneStoreReadsOneSnapshot() throws {
        // Every row of one request comes from the same snapshot, even if macOS writes
        // between two lookups. A new store (the next request) sees the write.
        let path = try db.create(items: [(calA, "ITEM-1", 1, ShowAsFixture.rep(busyStatus: "FREE"))])
        let store = try CalendarStore(path: path)
        XCTAssertEqual(try store.storedAvailability(calendarUUID: calA, itemUUID: "ITEM-1"), "free")

        try db.write(path, "UPDATE CalendarItem SET availability = 0, external_rep = NULL")

        XCTAssertEqual(try store.storedAvailability(calendarUUID: calA, itemUUID: "ITEM-1"), "free")
        XCTAssertEqual(try CalendarStore(path: path).storedAvailability(calendarUUID: calA, itemUUID: "ITEM-1"), "busy")
    }
}
