import EventKit
import XCTest
@testable import ReminderCLI

/// Reminders.app attaches an `EKAlarm(relativeOffset: 0)` to every TIMED reminder created in
/// its UI and nothing to an all-day one. Measured across a live library: of 178 timed
/// reminders 116 carry it, of 119 all-day reminders 115 carry nothing. `syncDueAlert` makes
/// this CLI write the same shape, so a reminder created here is indistinguishable from one
/// created in the app. These hold the edges of that rule.
final class DueAlertSyncTests: XCTestCase {

    private let store = EKEventStore()

    private func makeReminder(year: Int? = 2026, month: Int? = 9, day: Int? = 2,
                              hour: Int? = nil, minute: Int? = nil,
                              offsets: [TimeInterval] = []) -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        if let year, let month, let day {
            var due = DateComponents()
            due.year = year; due.month = month; due.day = day
            due.hour = hour; due.minute = minute
            reminder.dueDateComponents = due
        }
        for offset in offsets { reminder.addAlarm(EKAlarm(relativeOffset: offset)) }
        return reminder
    }

    private func offsets(_ reminder: EKReminder) -> [TimeInterval] {
        (reminder.alarms ?? []).map(\.relativeOffset)
    }

    func testATimedDueGetsTheAlertRemindersItselfWrites() {
        let reminder = makeReminder(hour: 15, minute: 0)
        syncDueAlert(reminder, enabled: true)
        XCTAssertEqual(offsets(reminder), [0])
    }

    /// An alert on a date with no time of day resolves to midnight, which is not when anyone
    /// wants to hear about it — and is why Reminders does not write one either.
    func testAnAllDayDueGetsNothing() {
        let reminder = makeReminder(hour: nil, minute: nil)
        syncDueAlert(reminder, enabled: true)
        XCTAssertTrue(offsets(reminder).isEmpty)
    }

    func testAReminderWithNoDueDateGetsNothing() {
        let reminder = makeReminder(year: nil, month: nil, day: nil)
        syncDueAlert(reminder, enabled: true)
        XCTAssertTrue(offsets(reminder).isEmpty)
    }

    /// An explicit `--alarm` stays exactly what the caller asked for. Adding an offset-0
    /// alarm beside an early one would not change what Reminders DISPLAYS — earliest wins,
    /// see `earlyAlarmShift` — but it would add a second ping nobody requested.
    func testAnExplicitAlarmIsLeftAlone() {
        let reminder = makeReminder(hour: 15, minute: 0, offsets: [-900])
        syncDueAlert(reminder, enabled: true)
        XCTAssertEqual(offsets(reminder), [-900])
    }

    /// Specifically: the implicit alert must not resurrect the early-alarm warning by
    /// stacking a second alarm, which would leave the reminder still displaying at 14:45
    /// while now also pinging at 15:00.
    func testAnExplicitAlarmKeepsTheDisplayedTimeSingleSourced() {
        let reminder = makeReminder(hour: 15, minute: 0, offsets: [-900])
        syncDueAlert(reminder, enabled: true)
        XCTAssertEqual(reminder.alarms?.count, 1)
        XCTAssertNotNil(earlyAlarmShift(for: reminder), "the early alarm still moves the label")
    }

    func testDisabledWritesNothing() {
        let reminder = makeReminder(hour: 15, minute: 0)
        syncDueAlert(reminder, enabled: false)
        XCTAssertTrue(offsets(reminder).isEmpty)
    }

    /// Idempotent: re-running over a reminder that already carries the implicit alert must
    /// not stack a duplicate. The update path can reach this on a second `--due` change.
    func testRunningTwiceDoesNotStackDuplicates() {
        let reminder = makeReminder(hour: 15, minute: 0)
        syncDueAlert(reminder, enabled: true)
        syncDueAlert(reminder, enabled: true)
        XCTAssertEqual(offsets(reminder), [0])
    }

    // MARK: - Retiming a timed reminder to all-day

    /// Greptile P1 on #126: the implicit alert was added while the reminder was timed, then
    /// the due date became all-day and the alarm stayed, resolving to a midnight ping.
    func testRetimingToAllDayDropsTheImplicitAlert() {
        let reminder = makeReminder(hour: 15, minute: 0)
        syncDueAlert(reminder, enabled: true)
        XCTAssertEqual(offsets(reminder), [0], "precondition: the implicit alert is there")

        reminder.dueDateComponents = DateComponents(year: 2026, month: 9, day: 4)
        syncDueAlert(reminder, enabled: true, dueDateChanged: true)
        XCTAssertTrue(offsets(reminder).isEmpty)
    }

    /// The narrowing that keeps the strip from eating real data: an alarm carrying an
    /// `absoluteDate` is the "all-day reminder, alert me at 9am" shape, which is what most
    /// all-day alarms in a real library actually are.
    func testRetimingToAllDayKeepsAnAbsoluteDateAlert() {
        let reminder = makeReminder(hour: 15, minute: 0)
        let alarm = EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_787_500_000))
        reminder.addAlarm(alarm)

        reminder.dueDateComponents = DateComponents(year: 2026, month: 9, day: 4)
        syncDueAlert(reminder, enabled: true, dueDateChanged: true)
        XCTAssertEqual(reminder.alarms?.count, 1)
        XCTAssertNotNil(reminder.alarms?.first?.absoluteDate)
    }

    /// A genuine early offset is the caller's, not ours, and survives the transition.
    func testRetimingToAllDayKeepsANonZeroOffset() {
        let reminder = makeReminder(hour: 15, minute: 0, offsets: [-900])
        reminder.dueDateComponents = DateComponents(year: 2026, month: 9, day: 4)
        syncDueAlert(reminder, enabled: true, dueDateChanged: true)
        XCTAssertEqual(offsets(reminder), [-900])
    }

    /// On create there is no previous state, so an explicit `--alarm 0` beside an all-day due
    /// is a stated intent rather than a leftover. Nothing is stripped without the flag.
    func testCreateLeavesAnExplicitZeroAlarmOnAnAllDayReminder() {
        let reminder = makeReminder(hour: nil, minute: nil, offsets: [0])
        syncDueAlert(reminder, enabled: true)
        XCTAssertEqual(offsets(reminder), [0])
    }

    /// A location alarm is still an alarm. The reminder already notifies on arrival, so
    /// adding a time alert would be a second notification the caller never asked for.
    func testALocationAlarmCountsAsAnAlarm() {
        let reminder = makeReminder(hour: 15, minute: 0)
        let alarm = EKAlarm()
        let location = EKStructuredLocation(title: "Home")
        location.radius = 100
        alarm.structuredLocation = location
        alarm.proximity = .enter
        reminder.addAlarm(alarm)

        syncDueAlert(reminder, enabled: true)
        XCTAssertEqual(reminder.alarms?.count, 1)
    }
}
