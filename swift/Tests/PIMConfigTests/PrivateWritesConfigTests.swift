import Foundation
import XCTest
@testable import PIMConfig

/// `reminders.privateWrites`: the one switch for reminder-cli's private ReminderKit writes.
final class PrivateWritesConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> PIMConfiguration {
        try JSONDecoder().decode(PIMConfiguration.self, from: Data(json.utf8))
    }

    func testOffByDefault() throws {
        XCTAssertFalse(try decode("{}").reminders.privateWrites)
        XCTAssertFalse(try decode(#"{"reminders":{"enabled":true}}"#).reminders.privateWrites)
    }

    func testOnWhenSet() throws {
        XCTAssertTrue(try decode(#"{"reminders":{"privateWrites":true}}"#).reminders.privateWrites)
    }

    func testEncodedOnlyWhenOn() throws {
        let off = String(data: try JSONEncoder().encode(DomainFilterConfig()), encoding: .utf8)!
        XCTAssertFalse(off.contains("privateWrites"), "other domains' sections are unchanged")
        let on = String(data: try JSONEncoder().encode(DomainFilterConfig(privateWrites: true)), encoding: .utf8)!
        XCTAssertTrue(on.contains("\"privateWrites\":true"))
    }

    func testProfileReplacingRemindersTurnsItOffUnlessRepeated() {
        var base = PIMConfiguration()
        base.reminders.privateWrites = true
        let profile = PIMProfileOverride(reminders: DomainFilterConfig(mode: .allowlist, items: ["Errands"]))
        XCTAssertFalse(ConfigLoader.merge(base: base, profile: profile).reminders.privateWrites,
                       "fail closed: a profile's reminders section replaces the base one")
    }
}
