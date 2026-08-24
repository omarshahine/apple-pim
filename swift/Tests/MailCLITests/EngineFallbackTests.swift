import XCTest
@testable import MailCLI

/// What survives a SQLite fast-path failure, and what must not.
final class EngineFallbackTests: XCTestCase {

    func testAmbiguousAccountIsFatalUnderEveryEngine() throws {
        // The JXA fallback resolves accounts by first match, so letting ambiguity fall
        // through under `auto` answers an ambiguous scope with an arbitrary account and
        // reports success — exactly what the ambiguity check exists to prevent.
        for engine in [EngineChoice.auto, .sqlite, .jxa] {
            XCTAssertThrowsError(
                try rethrowFatalFastPathError(
                    engine, EnvelopeIndexError.ambiguous("Account matches multiple"))
            ) { error in
                guard case CLIError.invalidInput(let message) = error else {
                    return XCTFail("Expected invalidInput for \(engine), got \(error)")
                }
                // Caller-input error, not an access/permission problem: no Full Disk
                // Access advice, because granting it would not change the answer.
                XCTAssertTrue(message.contains("Account matches multiple"))
                XCTAssertFalse(message.contains("Full Disk Access"))
            }
        }
    }

    func testEngineFailuresStillFallThroughUnderAuto() throws {
        // Everything that is genuinely an engine limitation keeps its fallback.
        for error in [
            EnvelopeIndexError.notAvailable("no Full Disk Access"),
            .notFound("Mailbox not found: INBOX"),
            .queryFailed("no such table"),
        ] {
            XCTAssertNoThrow(try rethrowFatalFastPathError(.auto, error))
            XCTAssertNoThrow(try rethrowFatalFastPathError(.jxa, error))
            XCTAssertThrowsError(try rethrowFatalFastPathError(.sqlite, error))
        }
    }
}
