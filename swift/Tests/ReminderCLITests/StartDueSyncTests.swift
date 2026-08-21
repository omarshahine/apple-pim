import XCTest
@testable import ReminderCLI

final class StartDueSyncTests: XCTestCase {

    // MARK: - mirroredStart

    func testMirroredStartCopiesFullDateAndTime() {
        var due = DateComponents()
        due.year = 2026; due.month = 9; due.day = 3
        due.hour = 9; due.minute = 30

        let start = mirroredStart(from: due)
        XCTAssertEqual(start.year, 2026)
        XCTAssertEqual(start.month, 9)
        XCTAssertEqual(start.day, 3)
        XCTAssertEqual(start.hour, 9)
        XCTAssertEqual(start.minute, 30)
    }

    /// Reminders.app stores an all-day reminder as a due date with no time
    /// alongside a start date at midnight.
    func testMirroredStartFillsMidnightForAllDayDueDate() {
        var due = DateComponents()
        due.year = 2026; due.month = 12; due.day = 1

        let start = mirroredStart(from: due)
        XCTAssertEqual(start.hour, 0)
        XCTAssertEqual(start.minute, 0)
        XCTAssertEqual(start.day, 1)
    }

    /// Regression: dropping the time zone made EventKit renormalize BOTH
    /// fields into local time on save, silently rewriting the due date's
    /// wall-clock representation.
    func testMirroredStartPreservesTimeZone() {
        var due = DateComponents()
        due.year = 2026; due.month = 9; due.day = 3
        due.hour = 9; due.minute = 30
        due.timeZone = TimeZone(identifier: "America/New_York")

        let start = mirroredStart(from: due)
        XCTAssertEqual(start.timeZone, TimeZone(identifier: "America/New_York"))
    }

    func testMirroredStartKeepsNilTimeZoneNil() {
        var due = DateComponents()
        due.year = 2026; due.month = 9; due.day = 3
        XCTAssertNil(mirroredStart(from: due).timeZone)
    }

    // MARK: - sameStoredDate

    func testSameStoredDateTreatsMissingTimeAsMidnight() {
        var dateOnly = DateComponents()
        dateOnly.year = 2026; dateOnly.month = 12; dateOnly.day = 1

        var midnight = dateOnly
        midnight.hour = 0
        midnight.minute = 0

        XCTAssertTrue(sameStoredDate(dateOnly, midnight))
    }

    func testSameStoredDateDetectsDifferentDay() {
        var a = DateComponents()
        a.year = 2026; a.month = 8; a.day = 18
        var b = a
        b.day = 1
        XCTAssertFalse(sameStoredDate(a, b))
    }

    func testSameStoredDateDetectsDifferentTime() {
        var a = DateComponents()
        a.year = 2026; a.month = 9; a.day = 1
        a.hour = 7; a.minute = 0
        var b = a
        b.hour = 6
        XCTAssertFalse(sameStoredDate(a, b))
    }

    /// Regression (Greptile P1 on #111): matching wall-clock fields with
    /// differing time zones is NOT the same stored date. Treating it as equal
    /// made repair-dates skip exactly the drift that causes EventKit to
    /// rewrite the due date on the next save.
    func testSameStoredDateDetectsTimeZoneMismatch() {
        var withZone = DateComponents()
        withZone.year = 2026; withZone.month = 9; withZone.day = 3
        withZone.hour = 9; withZone.minute = 30
        withZone.timeZone = TimeZone(identifier: "America/New_York")

        var withoutZone = withZone
        withoutZone.timeZone = nil

        var otherZone = withZone
        otherZone.timeZone = TimeZone(identifier: "America/Los_Angeles")

        XCTAssertFalse(sameStoredDate(withZone, withoutZone))
        XCTAssertFalse(sameStoredDate(withZone, otherZone))
        XCTAssertTrue(sameStoredDate(withZone, withZone))
    }

    /// A reminder whose start zone drifted from its due zone must be repaired
    /// into a fixed point.
    func testRepairingTimeZoneMismatchConverges() {
        var due = DateComponents()
        due.year = 2026; due.month = 9; due.day = 3
        due.hour = 9; due.minute = 30
        due.timeZone = TimeZone(identifier: "America/New_York")

        var driftedStart = due
        driftedStart.timeZone = nil
        XCTAssertFalse(sameStoredDate(driftedStart, mirroredStart(from: due)))

        let repaired = mirroredStart(from: due)
        XCTAssertTrue(sameStoredDate(repaired, mirroredStart(from: due)))
    }

    func testSameStoredDateNilHandling() {
        var a = DateComponents()
        a.year = 2026; a.month = 9; a.day = 1
        XCTAssertTrue(sameStoredDate(nil, nil))
        XCTAssertFalse(sameStoredDate(a, nil))
        XCTAssertFalse(sameStoredDate(nil, a))
    }

    /// A repaired reminder must be a fixed point: repairing twice changes
    /// nothing the second time.
    func testMirroredStartIsIdempotent() {
        var due = DateComponents()
        due.year = 2027; due.month = 6; due.day = 1
        due.timeZone = TimeZone(identifier: "America/Los_Angeles")

        let once = mirroredStart(from: due)
        XCTAssertTrue(sameStoredDate(once, mirroredStart(from: due)))
        XCTAssertTrue(sameStoredDate(once, once))
    }
}

final class AllDayDueDateTests: XCTestCase {

    // MARK: - isDateOnlyString

    func testRecognizesISODateOnly() {
        XCTAssertTrue(isDateOnlyString("2027-06-01"))
        XCTAssertTrue(isDateOnlyString("2027-6-1"))
        XCTAssertTrue(isDateOnlyString("  2027-06-01  "))
    }

    func testRecognizesSlashDateOnly() {
        XCTAssertTrue(isDateOnlyString("06/01/2027"))
        XCTAssertTrue(isDateOnlyString("6/1/2027"))
    }

    /// Regression: DateFormatter parses a *prefix*, so "2026-09-01 07:00"
    /// satisfies a "yyyy-MM-dd" formatter. An anchored regex must not.
    func testRejectsTimedStrings() {
        XCTAssertFalse(isDateOnlyString("2026-09-01 07:00"))
        XCTAssertFalse(isDateOnlyString("2026-09-01T07:00:00"))
        XCTAssertFalse(isDateOnlyString("2026-09-01 9:30 AM"))
        XCTAssertFalse(isDateOnlyString("09/01/2026 07:00"))
    }

    func testRejectsNonDates() {
        XCTAssertFalse(isDateOnlyString(""))
        XCTAssertFalse(isDateOnlyString("tomorrow"))
        XCTAssertFalse(isDateOnlyString("next week"))
    }

    // MARK: - reminderDueComponents

    func testDateOnlyStringOmitsTimeOfDay() throws {
        let c = try XCTUnwrap(reminderDueComponents(from: "2027-06-01"))
        XCTAssertEqual(c.year, 2027)
        XCTAssertEqual(c.month, 6)
        XCTAssertEqual(c.day, 1)
        XCTAssertNil(c.hour, "an all-day reminder must carry no hour")
        XCTAssertNil(c.minute, "an all-day reminder must carry no minute")
    }

    func testTimedStringKeepsTimeOfDay() throws {
        let c = try XCTUnwrap(reminderDueComponents(from: "2026-09-03 09:30"))
        XCTAssertEqual(c.hour, 9)
        XCTAssertEqual(c.minute, 30)
    }

    func testUnparseableStringReturnsNil() {
        XCTAssertNil(reminderDueComponents(from: "not a date at all"))
    }

    /// The all-day pair: due carries no time, start sits at midnight. This is
    /// the shape Reminders.app itself writes.
    func testAllDayPairMatchesRemindersAppShape() throws {
        let due = try XCTUnwrap(reminderDueComponents(from: "2027-06-01"))
        let start = mirroredStart(from: due)
        XCTAssertNil(due.hour)
        XCTAssertEqual(start.hour, 0)
        XCTAssertEqual(start.minute, 0)
        XCTAssertTrue(sameStoredDate(due, start))
    }
}
