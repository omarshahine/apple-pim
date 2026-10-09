import PIMConfig
import XCTest
@testable import ReminderCLI

final class DomainEnabledTests: XCTestCase {
    func testDisabledRemindersAreRefused() {
        let config = PIMConfiguration(reminders: DomainFilterConfig(enabled: false))
        XCTAssertThrowsError(try checkRemindersEnabled(config: config))
    }

    func testEnabledRemindersPass() {
        XCTAssertNoThrow(try checkRemindersEnabled(config: PIMConfiguration()))
    }
}
