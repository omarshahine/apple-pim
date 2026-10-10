import XCTest
@testable import CalendarCLI

/// The read commands take `--engine`. Parsing only: nothing here runs a command or touches EventKit.
final class EngineWiringTests: XCTestCase {

    func testReadCommandsDefaultToAuto() throws {
        XCTAssertEqual(try ListEvents.parse([]).engine, .auto)
        XCTAssertEqual(try GetEvent.parse(["--id", "EVENT-1"]).engine, .auto)
        XCTAssertEqual(try SearchEvents.parse(["standup"]).engine, .auto)
    }

    func testReadCommandsAcceptEveryEngine() throws {
        for engine in [EngineChoice.auto, .sqlite, .eventkit] {
            XCTAssertEqual(try ListEvents.parse(["--engine", engine.rawValue]).engine, engine)
            XCTAssertEqual(try GetEvent.parse(["--id", "EVENT-1", "--engine", engine.rawValue]).engine, engine)
            XCTAssertEqual(try SearchEvents.parse(["standup", "--engine", engine.rawValue]).engine, engine)
        }
        XCTAssertThrowsError(try ListEvents.parse(["--engine", "jxa"]))
    }
}
