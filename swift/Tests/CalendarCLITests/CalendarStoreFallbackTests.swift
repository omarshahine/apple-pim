import XCTest
@testable import CalendarCLI

/// What survives a Calendar store failure, and what must not.
final class CalendarStoreFallbackTests: XCTestCase {

    func testStoreFailuresFallThroughUnderAutoAndEventKit() throws {
        // Under auto the event keeps EventKit's value; eventkit never reads the store.
        for error in [
            CalendarStoreError.notAvailable("Cannot open the Calendar store read-only"),
            .queryFailed("disk I/O error"),
        ] {
            XCTAssertNoThrow(try rethrowFatalStoreError(.auto, error))
            XCTAssertNoThrow(try rethrowFatalStoreError(.eventkit, error))
        }
    }

    func testStoreFailuresAreFatalUnderSqlite() throws {
        for error in [
            CalendarStoreError.notAvailable("Cannot open the Calendar store read-only"),
            .queryFailed("disk I/O error"),
        ] {
            XCTAssertThrowsError(try rethrowFatalStoreError(.sqlite, error)) { thrown in
                guard case CLIError.accessDenied(let message) = thrown else {
                    return XCTFail("Expected accessDenied, got \(thrown)")
                }
                XCTAssertTrue(message.hasPrefix("SQLite engine failed: "), message)
                XCTAssertTrue(message.contains(error.localizedDescription), message)
                XCTAssertTrue(message.hasSuffix(
                    "(retry with --engine auto or eventkit, or grant Full Disk Access)"), message)
            }
        }
    }
}
