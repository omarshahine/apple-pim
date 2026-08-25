import EventKit
import XCTest
@testable import ReminderCLI

/// Reminders.app draws a reminder at its EARLIEST alarm and falls back to the due date only
/// when there are no alarms, so a nonzero `--alarm` relocates the reminder instead of adding a
/// heads-up before it. `earlyAlarmShift` is what makes that loud; these hold its edges.
///
/// Observed on macOS 26 with three reminders all due 2026-08-26 15:00: no alarm renders
/// "3:00 PM", a -15m alarm renders "2:45 PM", and offset-0 PLUS -15m still renders "2:45 PM".
final class EarlyAlarmWarningTests: XCTestCase {

    private let store = EKEventStore()

    private func makeReminder(dueHour: Int?, offsets: [TimeInterval]) -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        if let dueHour {
            var due = DateComponents()
            due.year = 2026; due.month = 8; due.day = 26
            due.hour = dueHour; due.minute = 0
            reminder.dueDateComponents = due
        }
        for offset in offsets { reminder.addAlarm(EKAlarm(relativeOffset: offset)) }
        return reminder
    }

    func testAnAlarmBeforeTheDueDateReportsTheShift() {
        let reminder = makeReminder(dueHour: 15, offsets: [-900])

        guard let shift = earlyAlarmShift(for: reminder) else {
            return XCTFail("a -15m alarm moves the displayed time and must be reported")
        }
        XCTAssertEqual(shift.due.timeIntervalSince(shift.alert), 900)
        XCTAssertEqual(earlyAlarmWarnings(for: reminder).count, 1)
        XCTAssertTrue(earlyAlarmWarnings(for: reminder)[0].contains("14:45"))
    }

    /// The alarm Reminders itself writes for every timed reminder. It lands exactly ON the due
    /// date, so nothing moves and warning about it would be noise on the common path.
    func testAnAlarmAtTheDueDateIsNotAShift() {
        XCTAssertNil(earlyAlarmShift(for: makeReminder(dueHour: 15, offsets: [0])))
        XCTAssertTrue(earlyAlarmWarnings(for: makeReminder(dueHour: 15, offsets: [0])).isEmpty)
    }

    /// The case that rules out "add a companion alarm at the due date" as a fix: Reminders
    /// takes the EARLIEST, so the offset-0 alarm does not restore the 3:00 PM label. The helper
    /// has to agree, or it would go quiet on precisely the shape that still renders wrong.
    func testEarliestAlarmWinsOverACompanionAtTheDueDate() {
        guard let shift = earlyAlarmShift(for: makeReminder(dueHour: 15, offsets: [0, -900])) else {
            return XCTFail("earliest alarm still moves the displayed time")
        }
        XCTAssertEqual(shift.due.timeIntervalSince(shift.alert), 900)
    }

    /// An alarm AFTER the due date does not move the label — Reminders takes the earliest, and
    /// the due date is earlier. Only shifts that make the reminder read early are reported.
    func testAnAlarmAfterTheDueDateIsNotReported() {
        XCTAssertNil(earlyAlarmShift(for: makeReminder(dueHour: 15, offsets: [900])))
    }

    func testNoAlarmsAndNoDueDateAreBothSilent() {
        XCTAssertNil(earlyAlarmShift(for: makeReminder(dueHour: 15, offsets: [])))
        XCTAssertNil(earlyAlarmShift(for: makeReminder(dueHour: nil, offsets: [-900])))
    }

    /// A location alarm carries no time of its own — `relativeOffset` is 0 and meaningless —
    /// so counting it would fire the warning on a geofenced reminder that displays fine.
    func testLocationAlarmsAreExcluded() {
        let reminder = makeReminder(dueHour: 15, offsets: [])
        let alarm = EKAlarm()
        let location = EKStructuredLocation(title: "Home")
        location.radius = 100
        alarm.structuredLocation = location
        alarm.proximity = .enter
        alarm.relativeOffset = -3600
        reminder.addAlarm(alarm)

        XCTAssertNil(earlyAlarmShift(for: reminder))
    }
}
