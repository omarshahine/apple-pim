import Foundation
import XCTest
@testable import CalendarCLI

/// The show-as a subscribed item keeps in its stored metadata, and the choice made from it:
/// the listed Microsoft value, else the stored column, else no answer. Fixtures come from
/// `ShowAsFixture`.
final class StoredShowAsTests: XCTestCase {

    // MARK: - The Microsoft show-as wins when present and listed

    func testEachListedShowAsMapsToItsEventKitName() {
        // Column 0 (busy) on every row, as macOS stores it for these subscriptions, so a
        // pass proves the property was read rather than the column.
        XCTAssertEqual(StoredShowAs.resolve(column: 0, externalRep: ShowAsFixture.rep(busyStatus: "FREE")), "free")
        XCTAssertEqual(StoredShowAs.resolve(column: 0, externalRep: ShowAsFixture.rep(busyStatus: "TENTATIVE")), "tentative")
        XCTAssertEqual(StoredShowAs.resolve(column: 1, externalRep: ShowAsFixture.rep(busyStatus: "BUSY")), "busy")
        XCTAssertEqual(StoredShowAs.resolve(column: 0, externalRep: ShowAsFixture.rep(busyStatus: "OOF")), "unavailable")
    }

    func testBusyStatusIsReadByKeyNotByStringSearch() {
        // INTENDEDSTATUS is the organizer's intended attendee state, never read. It uses the
        // same vocabulary, so a string search would answer with whichever comes first.
        let differ = ShowAsFixture.rep(properties: [
            ("X-MICROSOFT-CDO-INTENDEDSTATUS", "BUSY"),
            ("X-MICROSOFT-CDO-BUSYSTATUS", "FREE"),
        ])
        XCTAssertEqual(StoredShowAs.resolve(column: 0, externalRep: differ), "free")

        let differReversed = ShowAsFixture.rep(properties: [
            ("X-MICROSOFT-CDO-INTENDEDSTATUS", "FREE"),
            ("X-MICROSOFT-CDO-BUSYSTATUS", "TENTATIVE"),
        ])
        XCTAssertEqual(StoredShowAs.resolve(column: 1, externalRep: differReversed), "tentative")
    }

    // MARK: - X-MICROSOFT-MSNCALENDAR-BUSYSTATUS, a synonym read after CDO

    func testMSNCalendarShowAsAloneMaps() {
        let msn = ShowAsFixture.rep(properties: [("X-MICROSOFT-MSNCALENDAR-BUSYSTATUS", "OOF")])
        XCTAssertEqual(StoredShowAs.resolve(column: 0, externalRep: msn), "unavailable")
        let msnFree = ShowAsFixture.rep(properties: [("X-MICROSOFT-MSNCALENDAR-BUSYSTATUS", "FREE")])
        XCTAssertEqual(StoredShowAs.resolve(column: 0, externalRep: msnFree), "free")
    }

    func testCDOWinsOverMSNCalendar() {
        // Listed in both orders: precedence is by name, not by position in the archive.
        for properties in [
            [("X-MICROSOFT-CDO-BUSYSTATUS", "TENTATIVE"), ("X-MICROSOFT-MSNCALENDAR-BUSYSTATUS", "FREE")],
            [("X-MICROSOFT-MSNCALENDAR-BUSYSTATUS", "FREE"), ("X-MICROSOFT-CDO-BUSYSTATUS", "TENTATIVE")],
        ] {
            XCTAssertEqual(StoredShowAs.resolve(column: 1, externalRep: ShowAsFixture.rep(properties: properties)), "tentative")
        }
    }

    func testUnmappedCDOFallsToMSNCalendar() {
        let rep = ShowAsFixture.rep(properties: [
            ("X-MICROSOFT-CDO-BUSYSTATUS", "WORKINGELSEWHERE"),
            ("X-MICROSOFT-MSNCALENDAR-BUSYSTATUS", "BUSY"),
        ])
        XCTAssertEqual(StoredShowAs.resolve(column: 1, externalRep: rep), "busy")
    }

    func testUnmappedMSNCalendarFallsToTheColumn() {
        let rep = ShowAsFixture.rep(properties: [("X-MICROSOFT-MSNCALENDAR-BUSYSTATUS", "WORKINGELSEWHERE")])
        XCTAssertEqual(StoredShowAs.resolve(column: 1, externalRep: rep), "free")
        XCTAssertEqual(StoredShowAs.resolve(column: 0, externalRep: rep), "busy")
    }

    func testAShowAsStringSharedWithAnotherPropertyStillResolves() {
        // The archiver writes each distinct string once, so two properties holding the same
        // value point at one object.
        let shared = ShowAsFixture.rep(properties: [
            ("X-MICROSOFT-CDO-INTENDEDSTATUS", "TENTATIVE"),
            ("X-MICROSOFT-CDO-BUSYSTATUS", "TENTATIVE"),
        ], dedupeStrings: true)
        XCTAssertEqual(StoredShowAs.resolve(column: 0, externalRep: shared), "tentative")
    }

    func testImmutableDataPayloadIsAlsoRead() {
        // macOS writes NSMutableData ({NS.data}); an NSData payload archives as raw data.
        XCTAssertEqual(
            StoredShowAs.resolve(column: 0, externalRep: ShowAsFixture.rep(busyStatus: "FREE", innerAsRawData: true)),
            "free")
    }

    // MARK: - Anything else falls to the stored column

    func testWorkingElsewhereAndUnlistedValuesTakeTheColumn() {
        for value in ["WORKINGELSEWHERE", "SOMETHINGNEW", "free", ""] {
            XCTAssertEqual(StoredShowAs.resolve(column: 0, externalRep: ShowAsFixture.rep(busyStatus: value)), "busy", value)
            XCTAssertEqual(StoredShowAs.resolve(column: 1, externalRep: ShowAsFixture.rep(busyStatus: value)), "free", value)
        }
    }

    func testPlaceholderRowWithoutTheProperty() {
        let noShowAs = ShowAsFixture.rep(properties: [("X-MICROSOFT-CDO-INTENDEDSTATUS", "BUSY")])
        XCTAssertEqual(StoredShowAs.resolve(column: 1, externalRep: noShowAs), "free")
        XCTAssertEqual(StoredShowAs.resolve(column: 0, externalRep: nil), "busy")
    }

    func testMalformedArchivesTakeTheColumn() {
        let cases: [(String, Data)] = [
            ("not a plist", Data("not a plist".utf8)),
            ("plist but not a keyed archive", ShowAsFixture.plist(["root": "x"])),
            ("garbage inner archive", ShowAsFixture.rep(busyStatus: "FREE", innerOverride: Data("bplist00garbage".utf8))),
            ("empty value array", ShowAsFixture.rep(properties: [("X-MICROSOFT-CDO-BUSYSTATUS", nil)])),
            ("UID past the object table", ShowAsFixture.rep(busyStatus: "FREE", danglingValueUID: true)),
            ("value is not a string", ShowAsFixture.rep(busyStatus: "FREE", valueAsNumber: true)),
        ]
        for (label, data) in cases {
            XCTAssertEqual(StoredShowAs.busyStatuses(externalRep: data), [], label)
            XCTAssertEqual(StoredShowAs.resolve(column: 0, externalRep: data), "busy", label)
        }
    }

    func testOversizedArchiveIsNotParsed() {
        let padded = ShowAsFixture.rep(busyStatus: "FREE", outerPadding: StoredShowAs.maxArchiveBytes)
        XCTAssertGreaterThan(padded.count, StoredShowAs.maxArchiveBytes)
        XCTAssertEqual(StoredShowAs.busyStatuses(externalRep: padded), [])
        XCTAssertEqual(StoredShowAs.resolve(column: 0, externalRep: padded), "busy")
    }

    func testArchiveWithTooManyObjectsIsNotParsed() {
        let crowded = ShowAsFixture.rep(busyStatus: "FREE", extraInnerObjects: StoredShowAs.maxObjects)
        XCTAssertLessThanOrEqual(crowded.count, StoredShowAs.maxArchiveBytes)
        XCTAssertEqual(StoredShowAs.busyStatuses(externalRep: crowded), [])
        // The same archive under the bound is read, so the bound is what refused it.
        XCTAssertEqual(StoredShowAs.busyStatuses(externalRep: ShowAsFixture.rep(busyStatus: "FREE", extraInnerObjects: 8)), ["FREE"])
    }

    // MARK: - Column mapping and no answer

    func testColumnIsBinaryAndAnythingElseIsUnknown() {
        XCTAssertEqual(StoredShowAs.availability(column: 0), "busy")
        XCTAssertEqual(StoredShowAs.availability(column: 1), "free")
        XCTAssertNil(StoredShowAs.availability(column: 2))
        XCTAssertNil(StoredShowAs.availability(column: -1))
        XCTAssertNil(StoredShowAs.availability(column: nil))
    }

    func testNothingUsableResolvesToNil() {
        // nil: the caller keeps EventKit's own value.
        XCTAssertNil(StoredShowAs.resolve(column: nil, externalRep: nil))
        XCTAssertNil(StoredShowAs.resolve(column: 7, externalRep: Data("junk".utf8)))
        XCTAssertNil(StoredShowAs.resolve(column: nil, externalRep: ShowAsFixture.rep(busyStatus: "WORKINGELSEWHERE")))
    }
}
