import PIMConfig
import XCTest
@testable import CalendarCLI

final class DomainEnabledTests: XCTestCase {
    func testDisabledCalendarsAreRefused() {
        let config = PIMConfiguration(calendars: DomainFilterConfig(enabled: false))
        XCTAssertThrowsError(try checkCalendarsEnabled(config: config))
    }

    func testEnabledCalendarsPass() {
        XCTAssertNoThrow(try checkCalendarsEnabled(config: PIMConfiguration()))
    }
}
