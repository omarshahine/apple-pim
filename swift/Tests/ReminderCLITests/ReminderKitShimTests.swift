import Foundation
import XCTest
import ReminderKitShim

/// The shim's own guards. None of these reach ReminderKit's store: identifiers are checked
/// before any ReminderKit object is created, and loading the framework writes nothing.
final class ReminderKitShimTests: XCTestCase {

    func testFrameworkLoads() throws {
        try APRKShim.load()
    }

    func testMalformedIdentifiersAreRejectedBeforeReminderKitIsUsed() {
        let cases: [(String, () throws -> Void)] = [
            ("flag", { try APRKShim.setFlagged(true, reminderID: "not-a-uuid") }),
            ("subtask", { _ = try APRKShim.addSubtask(withTitle: "x", parentID: "nope") }),
            ("move", { try APRKShim.moveReminderID("AAAAAAAA-0000-0000-0000-000000000001", parentID: "x'; DROP") }),
            ("section", { try APRKShim.assignReminderID("AAAAAAAA-0000-0000-0000-000000000001", sectionID: "../etc") }),
            ("tags", { try APRKShim.replaceTags(["a"], reminderID: "") }),
        ]
        for (name, call) in cases {
            XCTAssertThrowsError(try call(), name) { error in
                let ns = error as NSError
                XCTAssertEqual(ns.domain, APRKShimErrorDomain, name)
                XCTAssertEqual(ns.code, 4, name)
            }
        }
    }

    func testEmptySubtaskTitleIsRejected() {
        XCTAssertThrowsError(try APRKShim.addSubtask(withTitle: "", parentID: "AAAAAAAA-0000-0000-0000-000000000001"))
    }
}
