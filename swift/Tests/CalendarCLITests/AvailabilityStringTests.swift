import EventKit
import XCTest
@testable import CalendarCLI

/// Every event carries EventKit's own availability.
final class AvailabilityStringTests: XCTestCase {

    func testEveryPublishedAvailabilityHasItsEventKitName() {
        XCTAssertEqual(availabilityString(.notSupported), "notSupported")
        XCTAssertEqual(availabilityString(.busy), "busy")
        XCTAssertEqual(availabilityString(.free), "free")
        XCTAssertEqual(availabilityString(.tentative), "tentative")
        XCTAssertEqual(availabilityString(.unavailable), "unavailable")
    }

    func testEventToDictEmitsTheEventsAvailability() {
        // No access request: building an unsaved event touches no calendar data and no TCC.
        // An event with no calendar ignores the availability setter and reports
        // notSupported, so the field must carry exactly that; the name mapping for the
        // other values is pinned above.
        let event = EKEvent(eventStore: EKEventStore())
        event.title = "Fixture"
        event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        event.endDate = Date(timeIntervalSince1970: 1_800_003_600)

        let dict = eventToDict(event)
        XCTAssertEqual(dict["availability"] as? String, "notSupported")
    }

    func testEventToDictPrefersAResolvedValueOverEventKits() {
        // The resolver hands in a value for events EventKit cannot answer.
        let event = EKEvent(eventStore: EKEventStore())
        event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        event.endDate = Date(timeIntervalSince1970: 1_800_003_600)

        XCTAssertEqual(eventToDict(event, availability: "free")["availability"] as? String, "free")
    }
}
