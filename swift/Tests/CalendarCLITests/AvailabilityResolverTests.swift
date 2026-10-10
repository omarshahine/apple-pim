import EventKit
import XCTest
@testable import CalendarCLI

/// Source selection per event: only a subscribed calendar's event that EventKit reports as
/// `notSupported` reaches the store, and only under `--engine auto` or `sqlite`.
final class AvailabilityResolverTests: XCTestCase {

    private let calA = CalendarStoreFixture.calA
    private let calB = CalendarStoreFixture.calB
    private let db = CalendarStoreFixture()

    override func tearDown() {
        db.remove()
        super.tearDown()
    }

    private var absentStore: URL { db.dir.appendingPathComponent("absent.sqlitedb") }

    private func storeWithFeed() throws -> URL {
        try db.create(items: [
            (calA, "SUB-TENTATIVE", 0, ShowAsFixture.rep(busyStatus: "TENTATIVE")),
            (calA, "SUB-COLUMN-FREE", 1, nil),
            (calB, "NATIVE-WITH-PROPERTY", 1, ShowAsFixture.rep(busyStatus: "FREE")),
        ])
    }

    // MARK: - auto

    func testAutoReadsTheStoreForASubscribedEventEventKitCannotAnswer() throws {
        let resolver = try AvailabilityResolver(engine: .auto, storePath: try storeWithFeed())

        XCTAssertEqual(try resolver.availability(isSubscribed: true, native: .notSupported,
                                                 calendarID: calA, itemID: "SUB-TENTATIVE"), "tentative")
        XCTAssertEqual(try resolver.availability(isSubscribed: true, native: .notSupported,
                                                 calendarID: calA, itemID: "SUB-COLUMN-FREE"), "free")
        XCTAssertTrue(resolver.openedStore)
    }

    func testAutoKeepsEventKitsValueWhenTheStoreHasNoUniqueRow() throws {
        let resolver = try AvailabilityResolver(engine: .auto, storePath: try storeWithFeed())
        XCTAssertEqual(try resolver.availability(isSubscribed: true, native: .notSupported,
                                                 calendarID: calA, itemID: "MISSING"), "notSupported")
        // The store was consulted, even though it had no answer.
        XCTAssertTrue(resolver.openedStore)
    }

    func testAutoFallsBackSilentlyWhenTheStoreIsUnreadable() throws {
        let resolver = try AvailabilityResolver(engine: .auto, storePath: absentStore)
        for item in ["ONE", "TWO", "THREE"] {
            XCTAssertEqual(try resolver.availability(isSubscribed: true, native: .notSupported,
                                                     calendarID: calA, itemID: item), "notSupported")
        }
        XCTAssertFalse(resolver.openedStore)
    }

    // MARK: - The gate

    func testOnlySubscribedNotSupportedEventsReachTheStore() throws {
        let resolver = try AvailabilityResolver(engine: .auto, storePath: try storeWithFeed())

        // A native calendar whose stored row carries the Microsoft property (an invitation)
        // keeps EventKit's answer, whatever it is.
        XCTAssertEqual(try resolver.availability(isSubscribed: false, native: .notSupported,
                                                 calendarID: calB, itemID: "NATIVE-WITH-PROPERTY"), "notSupported")
        XCTAssertEqual(try resolver.availability(isSubscribed: false, native: .busy,
                                                 calendarID: calB, itemID: "NATIVE-WITH-PROPERTY"), "busy")
        // A subscribed calendar EventKit can answer keeps EventKit's answer.
        XCTAssertEqual(try resolver.availability(isSubscribed: true, native: .busy,
                                                 calendarID: calA, itemID: "SUB-TENTATIVE"), "busy")
        // An event without identifiers cannot be joined.
        XCTAssertEqual(try resolver.availability(isSubscribed: true, native: .notSupported,
                                                 calendarID: nil, itemID: "SUB-TENTATIVE"), "notSupported")
        XCTAssertEqual(try resolver.availability(isSubscribed: true, native: .notSupported,
                                                 calendarID: calA, itemID: ""), "notSupported")
        XCTAssertFalse(resolver.openedStore, "the store was not opened")
    }

    // MARK: - eventkit

    func testEventKitEngineNeverOpensTheStore() throws {
        let resolver = try AvailabilityResolver(engine: .eventkit, storePath: try storeWithFeed())
        XCTAssertEqual(try resolver.availability(isSubscribed: true, native: .notSupported,
                                                 calendarID: calA, itemID: "SUB-TENTATIVE"), "notSupported")
        XCTAssertFalse(resolver.openedStore, "the store was not opened")
    }

    // MARK: - sqlite

    func testSqliteEngineRequiresAReadableStore() {
        XCTAssertThrowsError(try AvailabilityResolver(engine: .sqlite, storePath: absentStore)) { error in
            guard case CLIError.accessDenied = error else {
                return XCTFail("Expected accessDenied, got \(error)")
            }
        }
    }

    func testSqliteEngineReadsTheStoreAndSaysSo() throws {
        let resolver = try AvailabilityResolver(engine: .sqlite, storePath: try storeWithFeed())
        // The store was opened for this request, so the response says so even before
        // (or without) an event that needs it.
        XCTAssertTrue(resolver.openedStore)
        XCTAssertEqual(try resolver.availability(isSubscribed: true, native: .notSupported,
                                                 calendarID: calA, itemID: "SUB-TENTATIVE"), "tentative")
        // The gate still applies: sqlite does not override an answer EventKit has.
        XCTAssertEqual(try resolver.availability(isSubscribed: false, native: .free,
                                                 calendarID: calB, itemID: "NATIVE-WITH-PROPERTY"), "free")
    }
}
