import ArgumentParser
import CoreLocation
import EventKit
import Foundation
import PIMConfig

@main
struct ReminderCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder-cli",
        abstract: "Manage macOS Reminders using EventKit",
        subcommands: [
            AuthStatus.self,
            ListLists.self,
            ListReminders.self,
            GetReminder.self,
            SearchReminders.self,
            CreateReminder.self,
            CompleteReminder.self,
            UpdateReminder.self,
            DeleteReminder.self,
            BatchCreateReminder.self,
            BatchCompleteReminder.self,
            BatchDeleteReminder.self,
            RepairDates.self,
            ConfigCommand.self,
        ]
    )
}

// MARK: - Auth Status (no prompts)

struct AuthStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth-status",
        abstract: "Check reminder authorization status without triggering prompts"
    )

    func run() throws {
        let status: String
        if #available(macOS 14.0, *) {
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .fullAccess: status = "authorized"
            case .writeOnly: status = "writeOnly"
            case .denied: status = "denied"
            case .restricted: status = "restricted"
            case .notDetermined: status = "notDetermined"
            @unknown default: status = "unknown"
            }
        } else {
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .authorized: status = "authorized"
            case .denied: status = "denied"
            case .restricted: status = "restricted"
            case .notDetermined: status = "notDetermined"
            default: status = "unknown"
            }
        }
        let result: [String: Any] = ["authorization": status]
        let data = try JSONSerialization.data(withJSONObject: result)
        print(String(data: data, encoding: .utf8)!)
    }
}

// MARK: - Shared Utilities

let eventStore = EKEventStore()

func requestReminderAccess() async throws {
    if #available(macOS 14.0, *) {
        let granted = try await eventStore.requestFullAccessToReminders()
        guard granted else {
            throw CLIError.accessDenied("Reminders access denied. Grant access in System Settings > Privacy & Security > Reminders")
        }
    } else {
        let granted = try await eventStore.requestAccess(to: .reminder)
        guard granted else {
            throw CLIError.accessDenied("Reminders access denied. Grant access in System Settings > Privacy & Security > Reminders")
        }
    }
}

enum CLIError: Error, LocalizedError {
    case accessDenied(String)
    case notFound(String)
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let msg): return msg
        case .notFound(let msg): return msg
        case .invalidInput(let msg): return msg
        }
    }
}

func outputJSON(_ value: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
       let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}

func parseDate(_ string: String) -> Date? {
    // Handle relative dates first
    let lowercased = string.lowercased()
    let calendar = Calendar.current
    let now = Date()

    if lowercased == "today" {
        return calendar.startOfDay(for: now)
    } else if lowercased == "tomorrow" {
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
    } else if lowercased == "yesterday" {
        return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
    } else if lowercased.hasPrefix("next ") {
        let component = String(lowercased.dropFirst(5))
        switch component {
        case "week":
            return calendar.date(byAdding: .weekOfYear, value: 1, to: now)
        case "month":
            return calendar.date(byAdding: .month, value: 1, to: now)
        default:
            break
        }
    }

    // Try ISO 8601 first (handles offsets like -07:00, Z, and fractional seconds)
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]
    if let date = isoFormatter.date(from: string) {
        return date
    }
    // Also try with fractional seconds
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoFormatter.date(from: string) {
        return date
    }

    // DateFormatter patterns for non-ISO formats
    let formats = [
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd h:mm a",
        "yyyy-MM-dd",
        "MM/dd/yyyy HH:mm",
        "MM/dd/yyyy",
    ]
    for format in formats {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let date = formatter.date(from: string) {
            return date
        }
    }

    // Try natural language
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    if let match = detector?.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
       let date = match.date {
        return date
    }

    return nil
}

func listToDict(_ list: EKCalendar) -> [String: Any] {
    return [
        "id": list.calendarIdentifier,
        "title": list.title,
        "color": list.cgColor?.components?.map { Int($0 * 255) } ?? [],
        "allowsModifications": list.allowsContentModifications,
        "source": list.source?.title ?? "Unknown"
    ]
}

func reminderToDict(_ reminder: EKReminder) -> [String: Any] {
    var dict: [String: Any] = [
        "id": reminder.calendarItemIdentifier,
        "title": reminder.title ?? "",
        "isCompleted": reminder.isCompleted,
        "list": reminder.calendar?.title ?? "",
        "listId": reminder.calendar?.calendarIdentifier ?? "",
        "priority": reminder.priority
    ]

    if let completionDate = reminder.completionDate {
        dict["completionDate"] = ISO8601DateFormatter().string(from: completionDate)
    }
    if let dueDate = reminder.dueDateComponents {
        dict["dueDate"] = dateComponentsToString(dueDate)
    }
    if let startDate = reminder.startDateComponents {
        // Written on every dated reminder, mirrored from the due date (`setReminderDueDate`).
        // Returned so that mirroring is inspectable rather than implicit: a reminder carrying a
        // start date but no due date renders as dateless in Reminders.app, and that is only
        // diagnosable if reads show the field.
        dict["startDate"] = dateComponentsToString(startDate)
    }
    if let notes = reminder.notes, !notes.isEmpty {
        dict["notes"] = notes
    }
    if let url = reminder.url {
        // `EKReminder.url`. Apple Reminders does not display this; a link the user is meant
        // to see is mirrored into `notes` at write time (see `notesWithVisibleURL`).
        dict["url"] = url.absoluteString
    }
    if reminder.hasRecurrenceRules, let rules = reminder.recurrenceRules {
        dict["recurrence"] = rules.map { ruleToDict($0) }
    }
    if reminder.hasAlarms, let alarms = reminder.alarms {
        dict["alarms"] = alarms.map { alarmToDict($0) }
    }

    return dict
}

/// Attaches the alert Apple Reminders itself writes for a TIMED due date.
///
/// Reminders.app puts an `EKAlarm(relativeOffset: 0)` -- an alert AT the due moment -- on
/// every timed reminder created through its UI, and nothing on an all-day one. Measured
/// across a live library: of 178 timed reminders 116 carry it, while of 119 all-day
/// reminders 115 carry nothing. That inverted ratio is the design, and the timed reminders
/// missing it are the ones this CLI wrote.
///
/// Writing it makes a reminder created here indistinguishable from one created in the app.
///
/// It does NOT control whether the reminder fires. Dated reminders written by this CLI with
/// no alarm at all did notify, confirmed by the person who had been receiving them for
/// months; two attempts to observe delivery programmatically were both inconclusive and are
/// not worth repeating (the usernoted database has never held a `com.apple.reminders` row,
/// and a screen-capture probe could not rule out Reminders' notification settings). So this
/// is a REPRESENTATION fix, not a delivery fix: the value is that a reminder created here
/// matches one created in the app, which matters for round-tripping and for anything reading
/// the store. Nothing was silently mute before it.
///
/// All-day reminders get nothing, exactly as Reminders does it. An alert on a date with no
/// time of day resolves to midnight, which is not when anyone wants to hear about it.
///
/// Applies only when the reminder has no alarms already. An explicit `--alarm` stays exactly
/// what the caller asked for: adding an offset-0 alarm beside an early one would not change
/// what Reminders DISPLAYS -- earliest wins, see `earlyAlarmShift` -- but would add a second
/// ping nobody asked for.
/// - Parameter dueDateChanged: true on the update path, where the due date was just
///   rewritten and an offset-0 alarm left over from a previous TIMED due would now resolve
///   to midnight. On create there is no previous state, so an explicit `--alarm 0` beside an
///   all-day due is the caller's stated intent and is left alone.
func syncDueAlert(_ reminder: EKReminder, enabled: Bool, dueDateChanged: Bool = false) {
    guard enabled else { return }

    guard reminder.dueDateComponents?.hour != nil else {
        // The due date is all-day now. A BARE relative alarm resolves to midnight, which is
        // the state this function exists to avoid and one Reminders never produces on its
        // own -- so a timed reminder retimed to all-day must not keep the alert added when
        // it was timed.
        //
        // Narrow on purpose. An alarm carrying an `absoluteDate` is the real "all-day
        // reminder, alert me at 9am" shape and is common in practice (measured in a live
        // library: of 4 all-day reminders holding alarms, 3 carry an absoluteDate and only
        // 1 is a bare offset). Location alarms have no time of their own. Both are left.
        guard dueDateChanged else { return }
        for alarm in reminder.alarms ?? []
        where alarm.structuredLocation == nil && alarm.absoluteDate == nil
            && alarm.relativeOffset == 0 {
            reminder.removeAlarm(alarm)
        }
        return
    }

    guard !reminder.hasAlarms else { return }
    reminder.addAlarm(EKAlarm(relativeOffset: 0))
}

/// When a reminder's earliest alarm lands before its due date, the alert moment and the due
/// moment — in that order.
///
/// Reminders.app has ONE notion of a reminder's time: it draws the EARLIEST alarm, and falls
/// back to the due date only when a reminder has no alarms at all. So an alarm 15 minutes
/// before a 3:00 due date does not add a heads-up ahead of a 3:00 reminder — it makes the
/// reminder read 2:45, and the due time appears nowhere in the app.
///
/// Verified against Reminders.app on macOS 26: due 15:00 with no alarm renders "3:00 PM"; the
/// same reminder with a -15m alarm renders "2:45 PM"; adding a companion offset-0 alarm does
/// NOT restore it, because earliest still wins. Converting the offset to an absolute alarm
/// resolves to the same instant and renders identically. Reminders' own writes only ever use
/// `relativeOffset: 0` — an alert AT the due date — which is why the app has no UI for this
/// and no way to draw it.
///
/// There is therefore no EventKit shape that renders as "due 3:00, alert 2:45". The field is
/// not invisible, which mirroring could fix; it is *load-bearing in a way the caller did not
/// ask for*, so the only honest move left is to say so at the moment it is written.
///
/// Location alarms carry no time of their own and are excluded.
func earlyAlarmShift(for reminder: EKReminder) -> (alert: Date, due: Date)? {
    guard let dueComponents = reminder.dueDateComponents,
          let due = Calendar.current.date(from: dueComponents),
          let alarms = reminder.alarms else { return nil }
    let alertDates = alarms.compactMap { alarm -> Date? in
        guard alarm.structuredLocation == nil else { return nil }
        return alarm.absoluteDate ?? due.addingTimeInterval(alarm.relativeOffset)
    }
    guard let earliest = alertDates.min(), earliest < due else { return nil }
    return (earliest, due)
}

/// The caller-facing form of `earlyAlarmShift`, or `nil` when nothing is being moved.
func earlyAlarmWarnings(for reminder: EKReminder) -> [String] {
    guard let shift = earlyAlarmShift(for: reminder) else { return [] }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return ["Apple Reminders shows a reminder at its earliest alarm, not its due date, so this "
            + "reminder will display and fire at \(formatter.string(from: shift.alert)) rather "
            + "than \(formatter.string(from: shift.due)). Reminders has one alert per reminder "
            + "and no separate due time, so an early alert cannot be added alongside the due "
            + "date. Use an alarm of 0 to alert at the due date, or set the due date to when "
            + "you actually want to be reminded."]
}

/// Marker line that carries a reminder's URL where Apple Reminders will actually show it.
///
/// `EKReminder.url` round-trips through EventKit and syncs, but Reminders on iOS and macOS
/// renders it nowhere — a link written only there is invisible to the person the reminder
/// is for. Notes are rendered and data-detected, so mirroring the URL into a line of its own
/// is what makes a link real. The line is matched exactly on removal, so clearing the URL
/// takes the mirror with it and leaves the rest of the notes untouched.
func urlNotesLine(_ url: String) -> String { "🔗 \(url)" }

/// Notes with `url` present as its own line, appended if it is not already there.
/// Returns `nil` when there is nothing to write (no URL, empty notes).
func notesWithVisibleURL(_ notes: String?, url: String) -> String? {
    let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedURL.isEmpty else { return notes }
    let existing = notes ?? ""
    // Already visible — as our marker line or as bare text the caller wrote themselves.
    // Adding a second copy would be noise, and would survive the first one's removal.
    let lines = existing.components(separatedBy: .newlines).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    if lines.contains(urlNotesLine(trimmedURL)) || lines.contains(trimmedURL) { return existing }
    return existing.isEmpty
        ? urlNotesLine(trimmedURL)
        : "\(existing)\n\(urlNotesLine(trimmedURL))"
}

/// Notes with the mirrored line for `url` removed. Only our own marker line is removed:
/// a URL the caller typed into their notes is their text, not our bookkeeping.
func notesWithoutVisibleURL(_ notes: String?, url: String) -> String? {
    guard let notes, !notes.isEmpty else { return notes }
    let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedURL.isEmpty else { return notes }
    let marker = urlNotesLine(trimmedURL)
    let kept = notes.components(separatedBy: .newlines).filter {
        $0.trimmingCharacters(in: .whitespaces) != marker
    }
    let result = kept.joined(separator: "\n").trimmingCharacters(in: .newlines)
    return result.isEmpty ? nil : result
}

func dateComponentsToString(_ components: DateComponents) -> String {
    var parts: [String] = []
    if let year = components.year { parts.append(String(format: "%04d", year)) }
    if let month = components.month { parts.append(String(format: "%02d", month)) }
    if let day = components.day { parts.append(String(format: "%02d", day)) }

    var dateStr = parts.joined(separator: "-")

    if let hour = components.hour, let minute = components.minute {
        dateStr += String(format: " %02d:%02d", hour, minute)
    }

    return dateStr
}

/// Sets a reminder's due date and mirrors `startDateComponents` to match.
///
/// Reminders.app writes both fields together and offers no separate "start
/// date" control, but EventKit does not mirror them for you. Writing due
/// alone leaves whatever start date was there before, and a reminder that
/// ends up with a start date but no due date renders as *dateless* in
/// Reminders.app while still occupying a date slot in EventKit. Always go
/// through this instead of assigning `dueDateComponents` directly.
func setReminderDueDate(_ reminder: EKReminder, to due: DateComponents?) {
    reminder.dueDateComponents = due
    reminder.startDateComponents = due.map { mirroredStart(from: $0) }
}

/// Whether a due-date string names a day with no time of day.
///
/// Matched with an anchored regex rather than `DateFormatter`, which happily
/// parses a *prefix*: "2026-09-01 07:00" satisfies a "yyyy-MM-dd" formatter
/// and would otherwise be misread as all-day.
func isDateOnlyString(_ string: String) -> Bool {
    let trimmed = string.trimmingCharacters(in: .whitespaces)
    let patterns = [#"^\d{4}-\d{1,2}-\d{1,2}$"#, #"^\d{1,2}/\d{1,2}/\d{4}$"#]
    return patterns.contains { trimmed.range(of: $0, options: .regularExpression) != nil }
}

/// Builds due-date components, keeping the all-day shape when the caller
/// named a day without a time.
///
/// Reminders.app stores an all-day reminder as a due date carrying no hour or
/// minute. Someone passing "2027-06-01" means the whole day, not midnight.
func reminderDueComponents(from string: String) -> DateComponents? {
    guard let date = parseDate(string) else { return nil }
    let fields: Set<Calendar.Component> = isDateOnlyString(string)
        ? [.year, .month, .day]
        : [.year, .month, .day, .hour, .minute]
    return Calendar.current.dateComponents(fields, from: date)
}

func ruleToDict(_ rule: EKRecurrenceRule) -> [String: Any] {
    var dict: [String: Any] = [
        "frequency": frequencyString(rule.frequency),
        "interval": rule.interval
    ]
    if let end = rule.recurrenceEnd {
        if let endDate = end.endDate {
            dict["endDate"] = ISO8601DateFormatter().string(from: endDate)
        } else {
            dict["occurrenceCount"] = end.occurrenceCount
        }
    }
    if let days = rule.daysOfTheWeek, !days.isEmpty {
        dict["daysOfTheWeek"] = days.map { weekdayString($0.dayOfTheWeek) }
    }
    if let days = rule.daysOfTheMonth, !days.isEmpty {
        dict["daysOfTheMonth"] = days.map { $0.intValue }
    }
    return dict
}

func frequencyString(_ freq: EKRecurrenceFrequency) -> String {
    switch freq {
    case .daily: return "daily"
    case .weekly: return "weekly"
    case .monthly: return "monthly"
    case .yearly: return "yearly"
    @unknown default: return "unknown"
    }
}

func alarmToDict(_ alarm: EKAlarm) -> [String: Any] {
    var dict: [String: Any] = [
        "relativeOffset": alarm.relativeOffset
    ]

    if let absoluteDate = alarm.absoluteDate {
        // An absolute alarm reports `relativeOffset: 0`, so without this an alarm pinned to a
        // fixed moment read back identically to one anchored on the due date.
        dict["absoluteDate"] = ISO8601DateFormatter().string(from: absoluteDate)
    }

    if let location = alarm.structuredLocation {
        var locDict: [String: Any] = [:]
        if let title = location.title {
            locDict["name"] = title
        }
        if let geoLocation = location.geoLocation {
            locDict["latitude"] = geoLocation.coordinate.latitude
            locDict["longitude"] = geoLocation.coordinate.longitude
        }
        locDict["radius"] = location.radius
        switch alarm.proximity {
        case .enter:
            locDict["proximity"] = "arrive"
        case .leave:
            locDict["proximity"] = "depart"
        case .none:
            locDict["proximity"] = "none"
        @unknown default:
            locDict["proximity"] = "unknown"
        }
        dict["location"] = locDict
    }

    return dict
}

// MARK: - Config Helpers

/// Get only the reminder lists allowed by the current PIM config.
func allowedLists(config: PIMConfiguration) -> [EKCalendar] {
    let all = eventStore.calendars(for: .reminder)
    return ItemFilter.filter(items: all, config: config.reminders, name: { $0.title }, id: { $0.calendarIdentifier })
}

/// Validate that a reminder's list is accessible under the current config.
func validateReminderAccess(_ reminder: EKReminder, config: PIMConfiguration) throws {
    guard let cal = reminder.calendar else { return }
    guard ItemFilter.isAllowed(name: cal.title, id: cal.calendarIdentifier, config: config.reminders) else {
        throw CLIError.accessDenied("Reminder list '\(cal.title)' is not in your allowed list. Run /apple-pim:configure to update access.")
    }
}

/// Find a reminder list by name or ID, validating it's in the allowed list.
func findAllowedList(nameOrId: String, config: PIMConfiguration) throws -> EKCalendar {
    let allLists = eventStore.calendars(for: .reminder)
    guard let cal = allLists.first(where: {
        $0.calendarIdentifier == nameOrId || $0.title.lowercased() == nameOrId.lowercased()
    }) else {
        throw CLIError.notFound("Reminder list not found: \(nameOrId)")
    }
    guard ItemFilter.isAllowed(name: cal.title, id: cal.calendarIdentifier, config: config.reminders) else {
        throw CLIError.accessDenied("Reminder list '\(cal.title)' is not in your allowed list. Run /apple-pim:configure to update access.")
    }
    return cal
}

/// Resolve the target list for a create operation: explicit name > config default > system default.
func resolveTargetList(explicit: String?, config: PIMConfiguration) throws -> EKCalendar {
    if let name = explicit {
        return try findAllowedList(nameOrId: name, config: config)
    }
    if let defaultName = config.defaultReminderList {
        return try findAllowedList(nameOrId: defaultName, config: config)
    }
    guard let systemDefault = eventStore.defaultCalendarForNewReminders() else {
        throw CLIError.notFound("No default reminder list available")
    }
    return systemDefault
}

// MARK: - Recurrence Helpers

struct RecurrenceJSON: Codable {
    let frequency: String?
    let interval: Int?
    let endDate: String?
    let occurrenceCount: Int?
    let daysOfTheWeek: [String]?
    let daysOfTheMonth: [Int]?
}

func weekdayString(_ weekday: EKWeekday) -> String {
    switch weekday {
    case .sunday: return "sunday"
    case .monday: return "monday"
    case .tuesday: return "tuesday"
    case .wednesday: return "wednesday"
    case .thursday: return "thursday"
    case .friday: return "friday"
    case .saturday: return "saturday"
    @unknown default: return "unknown"
    }
}

func dayStringToEKDay(_ day: String) -> EKRecurrenceDayOfWeek? {
    switch day.lowercased() {
    case "sunday", "sun": return EKRecurrenceDayOfWeek(.sunday)
    case "monday", "mon": return EKRecurrenceDayOfWeek(.monday)
    case "tuesday", "tue": return EKRecurrenceDayOfWeek(.tuesday)
    case "wednesday", "wed": return EKRecurrenceDayOfWeek(.wednesday)
    case "thursday", "thu": return EKRecurrenceDayOfWeek(.thursday)
    case "friday", "fri": return EKRecurrenceDayOfWeek(.friday)
    case "saturday", "sat": return EKRecurrenceDayOfWeek(.saturday)
    default: return nil
    }
}

func parseRecurrenceRule(_ json: String) -> EKRecurrenceRule? {
    guard let data = json.data(using: .utf8),
          let recurrence = try? JSONDecoder().decode(RecurrenceJSON.self, from: data) else {
        return nil
    }

    // A nil or "none" frequency means remove recurrence — return nil
    guard let freqStr = recurrence.frequency?.lowercased(), freqStr != "none" else {
        return nil
    }

    // Parse frequency
    let frequency: EKRecurrenceFrequency
    switch freqStr {
    case "daily": frequency = .daily
    case "weekly": frequency = .weekly
    case "monthly": frequency = .monthly
    case "yearly": frequency = .yearly
    default: return nil
    }

    // Parse interval (default: 1)
    let interval = recurrence.interval ?? 1

    // Parse end condition
    var recurrenceEnd: EKRecurrenceEnd? = nil
    if let endDateStr = recurrence.endDate, let endDate = parseDate(endDateStr) {
        recurrenceEnd = EKRecurrenceEnd(end: endDate)
    } else if let count = recurrence.occurrenceCount {
        recurrenceEnd = EKRecurrenceEnd(occurrenceCount: count)
    }

    // Parse days of the week
    var daysOfTheWeek: [EKRecurrenceDayOfWeek]? = nil
    if let days = recurrence.daysOfTheWeek {
        daysOfTheWeek = days.compactMap { dayStringToEKDay($0) }
        if daysOfTheWeek?.isEmpty == true {
            daysOfTheWeek = nil
        }
    }

    // Parse days of the month
    var daysOfTheMonth: [NSNumber]? = nil
    if let days = recurrence.daysOfTheMonth {
        daysOfTheMonth = days.map { NSNumber(value: $0) }
        if daysOfTheMonth?.isEmpty == true {
            daysOfTheMonth = nil
        }
    }

    return EKRecurrenceRule(
        recurrenceWith: frequency,
        interval: interval,
        daysOfTheWeek: daysOfTheWeek,
        daysOfTheMonth: daysOfTheMonth,
        monthsOfTheYear: nil,
        weeksOfTheYear: nil,
        daysOfTheYear: nil,
        setPositions: nil,
        end: recurrenceEnd
    )
}

// MARK: - Location Helpers

struct LocationJSON: Codable {
    let name: String?
    let latitude: Double
    let longitude: Double
    let radius: Double?
    let proximity: String  // "arrive" or "depart"
}

func parseLocationAlarm(_ json: String) -> EKAlarm? {
    guard let data = json.data(using: .utf8),
          let location = try? JSONDecoder().decode(LocationJSON.self, from: data) else {
        return nil
    }

    let structuredLocation = EKStructuredLocation(title: location.name ?? "Location")
    structuredLocation.geoLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
    structuredLocation.radius = location.radius ?? 100.0

    let alarm = EKAlarm()
    alarm.structuredLocation = structuredLocation
    alarm.proximity = location.proximity.lowercased() == "depart" ? .leave : .enter

    return alarm
}

// MARK: - Commands

struct ListLists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lists",
        abstract: "List all reminder lists"
    )

    @OptionGroup var pimOptions: PIMOptions

    func run() async throws {
        try await requestReminderAccess()

        let config = pimOptions.loadConfig()
        let lists = allowedLists(config: config)
        let result = lists.map { listToDict($0) }

        outputJSON([
            "success": true,
            "lists": result
        ])
    }
}

struct ListReminders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "items",
        abstract: "List reminders from a list"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Reminder list name or ID")
    var list: String?

    @Flag(name: .long, help: "Include completed reminders")
    var completed: Bool = false

    @Option(name: .long, help: "Filter: overdue, today, tomorrow, week, upcoming, completed, all")
    var filter: String?

    @Option(name: .long, help: "Maximum number of reminders")
    var limit: Int = 100

    func run() async throws {
        try await requestReminderAccess()

        let config = pimOptions.loadConfig()

        // Resolve lists: explicit filter > all allowed lists
        var calendars: [EKCalendar]?
        if let listFilter = list {
            let cal = try findAllowedList(nameOrId: listFilter, config: config)
            calendars = [cal]
        } else if config.reminders.mode != .all {
            calendars = allowedLists(config: config)
        }

        let predicate = eventStore.predicateForReminders(in: calendars)

        let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        // Determine include-completed based on filter or flag (case-insensitive)
        let filterLower = filter?.lowercased()
        let includeCompleted = completed || filterLower == "completed" || filterLower == "all"

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        let endOfTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday)!
        // Use Calendar's locale-aware week interval (respects firstWeekday setting)
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: startOfToday)
        let startOfWeek = weekInterval?.start ?? startOfToday
        let endOfWeek = weekInterval?.end ?? calendar.date(byAdding: .day, value: 7, to: startOfToday)!

        let filtered: [[String: Any]] = reminders
            .filter { reminder in
                // First apply completion filter
                if !includeCompleted && reminder.isCompleted { return false }

                // Then apply date filter if specified
                guard let filterType = filterLower else { return true }

                let dueDate: Date? = {
                    guard let components = reminder.dueDateComponents else { return nil }
                    return calendar.date(from: components)
                }()

                switch filterType {
                case "overdue":
                    guard let due = dueDate else { return false }
                    return due < startOfToday && !reminder.isCompleted
                case "today":
                    // Today includes overdue + due today
                    guard let due = dueDate else { return false }
                    return due < startOfTomorrow && !reminder.isCompleted
                case "tomorrow":
                    guard let due = dueDate else { return false }
                    return due >= startOfTomorrow && due < endOfTomorrow
                case "week":
                    // Full calendar week (locale-aware boundaries)
                    guard let due = dueDate else { return false }
                    return due >= startOfWeek && due < endOfWeek
                case "upcoming":
                    guard dueDate != nil else { return false }
                    return !reminder.isCompleted
                case "completed":
                    return reminder.isCompleted
                case "all":
                    return true
                default:
                    return true
                }
            }
            .sorted { a, b in
                // Sort by due date (earliest first), undated last
                let dateA = a.dueDateComponents.flatMap { calendar.date(from: $0) }
                let dateB = b.dueDateComponents.flatMap { calendar.date(from: $0) }
                if dateA == nil && dateB == nil { return false }
                if dateA == nil { return false }
                if dateB == nil { return true }
                return dateA! < dateB!
            }
            .prefix(limit)
            .map { reminderToDict($0) }

        var result: [String: Any] = [
            "success": true,
            "reminders": Array(filtered),
            "count": filtered.count
        ]
        if let f = filter {
            result["filter"] = f
        }

        outputJSON(result)
    }
}

struct GetReminder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a single reminder by ID"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Reminder ID")
    var id: String

    func run() async throws {
        try await requestReminderAccess()

        let config = pimOptions.loadConfig()

        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw CLIError.notFound("Reminder not found: \(id)")
        }

        try validateReminderAccess(reminder, config: config)

        outputJSON([
            "success": true,
            "reminder": reminderToDict(reminder)
        ])
    }
}

struct SearchReminders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search reminders by title"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Argument(help: "Search query")
    var query: String

    @Option(name: .long, help: "Reminder list name or ID")
    var list: String?

    @Flag(name: .long, help: "Include completed reminders")
    var completed: Bool = false

    @Option(name: .long, help: "Maximum results")
    var limit: Int = 50

    func run() async throws {
        try await requestReminderAccess()

        let config = pimOptions.loadConfig()

        // Resolve lists: explicit filter > all allowed lists
        var calendars: [EKCalendar]?
        if let listFilter = list {
            let cal = try findAllowedList(nameOrId: listFilter, config: config)
            calendars = [cal]
        } else if config.reminders.mode != .all {
            calendars = allowedLists(config: config)
        }

        let predicate = eventStore.predicateForReminders(in: calendars)

        let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        let queryLower = query.lowercased()
        let filtered = reminders
            .filter { reminder in
                let title = reminder.title?.lowercased() ?? ""
                let notes = reminder.notes?.lowercased() ?? ""
                return title.contains(queryLower) || notes.contains(queryLower)
            }
            .filter { completed || !$0.isCompleted }
            .prefix(limit)
            .map { reminderToDict($0) }

        outputJSON([
            "success": true,
            "query": query,
            "reminders": Array(filtered),
            "count": filtered.count
        ])
    }
}

struct CreateReminder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new reminder"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Reminder title")
    var title: String

    @Option(name: .long, help: "Reminder list name or ID")
    var list: String?

    @Option(name: .long, help: "Due date/time")
    var due: String?

    @Option(name: .long, help: "Notes")
    var notes: String?

    @Option(name: .long, help: "Priority (0=none, 1=high, 5=medium, 9=low)")
    var priority: Int = 0

    @Option(name: .long, help: ArgumentHelp("URL to attach. Written to EKReminder.url, which Apple Reminders does not display, so it is also mirrored into the notes as a visible link (disable with --no-url-in-notes)"))
    var url: String?

    @Flag(inversion: .prefixedNo,
          help: "Mirror --url into the notes so Apple Reminders shows a tappable link")
    var urlInNotes: Bool = true

    @Option(name: .long, help: ArgumentHelp(
        "Alarm minutes before due (can specify multiple). NOT an early heads-up: Apple "
        + "Reminders shows a reminder at its earliest alarm, so --alarm 15 on a reminder due "
        + "at 3:00 makes it read and fire at 2:45, with the due time shown nowhere. Use 0 to "
        + "alert at the due date, which is what Reminders itself writes"))
    var alarm: [Int] = []

    @Flag(inversion: .prefixedNo,
          help: "Attach the alert Apple Reminders itself writes for a timed due date (an alarm at the due moment). All-day reminders never get one. Skipped when --alarm is given")
    var dueAlert: Bool = true


    @Option(name: .long, help: "Recurrence rule as JSON (e.g., '{\"frequency\":\"monthly\",\"interval\":1}')")
    var recurrence: String?

    @Option(name: .long, help: "Location-based alarm as JSON (e.g., '{\"name\":\"Home\",\"latitude\":37.33,\"longitude\":-122.03,\"radius\":100,\"proximity\":\"arrive\"}')")
    var location: String?

    func run() async throws {
        try await requestReminderAccess()

        let config = pimOptions.loadConfig()

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = try resolveTargetList(explicit: list, config: config)

        if let dueStr = due, let components = reminderDueComponents(from: dueStr) {
            setReminderDueDate(reminder, to: components)
        }

        if let n = notes {
            reminder.notes = n
        }

        reminder.priority = priority

        if let urlStr = url, let reminderUrl = URL(string: urlStr) {
            reminder.url = reminderUrl
            // EventKit keeps the URL; Reminders shows the notes. Write both, or the caller
            // has attached a link nobody can see.
            if urlInNotes {
                reminder.notes = notesWithVisibleURL(reminder.notes, url: urlStr)
            }
        }

        for minutes in alarm {
            let alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
            reminder.addAlarm(alarm)
        }

        // Add location-based alarm if specified
        if let locationJSON = location, let locationAlarm = parseLocationAlarm(locationJSON) {
            reminder.addAlarm(locationAlarm)
        }

        // Add recurrence rule if specified
        if let recurrenceJSON = recurrence, let rule = parseRecurrenceRule(recurrenceJSON) {
            reminder.addRecurrenceRule(rule)
        }

        // Last, so it can see every alarm the caller asked for and stand down if there is one.
        syncDueAlert(reminder, enabled: dueAlert)

        try eventStore.save(reminder, commit: true)

        var payload: [String: Any] = [
            "success": true,
            "message": "Reminder created successfully",
            "reminder": reminderToDict(reminder)
        ]
        // Loud at the moment it happens: an early alarm silently relocates the reminder in
        // Reminders.app, and nothing downstream can tell that from a reminder genuinely due
        // then. See `earlyAlarmShift`.
        let warnings = earlyAlarmWarnings(for: reminder)
        if !warnings.isEmpty { payload["warnings"] = warnings }
        outputJSON(payload)
    }
}

struct CompleteReminder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "complete",
        abstract: "Mark a reminder as complete"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Reminder ID to complete")
    var id: String

    @Flag(name: .long, help: "Mark as incomplete instead")
    var undo: Bool = false

    func run() async throws {
        try await requestReminderAccess()

        let config = pimOptions.loadConfig()

        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw CLIError.notFound("Reminder not found: \(id)")
        }

        try validateReminderAccess(reminder, config: config)

        reminder.isCompleted = !undo
        if !undo {
            reminder.completionDate = Date()
        } else {
            reminder.completionDate = nil
        }

        try eventStore.save(reminder, commit: true)

        outputJSON([
            "success": true,
            "message": undo ? "Reminder marked as incomplete" : "Reminder marked as complete",
            "reminder": reminderToDict(reminder)
        ])
    }
}

struct UpdateReminder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an existing reminder"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Reminder ID to update")
    var id: String

    @Option(name: .long, help: "New title")
    var title: String?

    @Option(name: .long, help: "New due date/time")
    var due: String?

    @Option(name: .long, help: "New notes")
    var notes: String?

    @Option(name: .long, help: "New priority")
    var priority: Int?

    @Option(name: .long, help: "Recurrence rule as JSON (e.g., '{\"frequency\":\"monthly\",\"interval\":1}')")
    var recurrence: String?

    @Option(name: .long, help: ArgumentHelp("URL to attach. Written to EKReminder.url, which Apple Reminders does not display, so it is also mirrored into the notes as a visible link (disable with --no-url-in-notes)" + ". Pass an empty string to clear it"))
    var url: String?

    @Flag(inversion: .prefixedNo,
          help: "Mirror --url into the notes so Apple Reminders shows a tappable link")
    var urlInNotes: Bool = true

    @Flag(inversion: .prefixedNo,
          help: "When --due sets a time on a reminder that has no alarms, attach the alert Apple Reminders itself writes. All-day dues never get one")
    var dueAlert: Bool = true

    @Option(name: .long, help: "Location-based alarm as JSON (e.g., '{\"name\":\"Home\",\"latitude\":37.33,\"longitude\":-122.03,\"radius\":100,\"proximity\":\"arrive\"}')")
    var location: String?

    func run() async throws {
        try await requestReminderAccess()

        let config = pimOptions.loadConfig()

        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw CLIError.notFound("Reminder not found: \(id)")
        }

        try validateReminderAccess(reminder, config: config)

        if let newTitle = title {
            reminder.title = newTitle
        }
        if let newDue = due {
            if let components = reminderDueComponents(from: newDue) {
                setReminderDueDate(reminder, to: components)
            }
        }
        if let newNotes = notes {
            reminder.notes = newNotes
        }
        if let newPriority = priority {
            reminder.priority = newPriority
        }
        // Only touched when --url is passed: an unrelated update must leave an existing
        // URL (and any mirrored line) exactly where it was.
        if let newUrl = url {
            if newUrl.isEmpty {
                // Clearing takes the mirrored line with it, so the visible link and the
                // stored one cannot drift apart.
                if let previous = reminder.url?.absoluteString, urlInNotes {
                    reminder.notes = notesWithoutVisibleURL(reminder.notes, url: previous)
                }
                reminder.url = nil
            } else if let reminderUrl = URL(string: newUrl) {
                if urlInNotes {
                    // Replacing: drop the old mirror before adding the new one.
                    if let previous = reminder.url?.absoluteString, previous != newUrl {
                        reminder.notes = notesWithoutVisibleURL(reminder.notes, url: previous)
                    }
                    reminder.notes = notesWithVisibleURL(reminder.notes, url: newUrl)
                }
                reminder.url = reminderUrl
            }
        }

        // Update recurrence rule if specified
        if let recurrenceJSON = recurrence {
            // Remove existing recurrence rules
            if let existingRules = reminder.recurrenceRules {
                for rule in existingRules {
                    reminder.removeRecurrenceRule(rule)
                }
            }
            // Add new recurrence rule
            if let rule = parseRecurrenceRule(recurrenceJSON) {
                reminder.addRecurrenceRule(rule)
            }
        }

        // Update location-based alarm if specified
        if let locationJSON = location {
            // Remove existing location-based alarms
            if let existingAlarms = reminder.alarms {
                for alarm in existingAlarms {
                    if alarm.structuredLocation != nil {
                        reminder.removeAlarm(alarm)
                    }
                }
            }
            // Add new location alarm (unless empty string to clear)
            if !locationJSON.isEmpty, let locationAlarm = parseLocationAlarm(locationJSON) {
                reminder.addAlarm(locationAlarm)
            }
        }

        // Gated on `--due` rather than run unconditionally: an unrelated update (a retitle,
        // a priority change) must not quietly grow an alarm the reminder never had. Setting
        // a due time is the moment the app itself would have written one.
        if due != nil {
            syncDueAlert(reminder, enabled: dueAlert, dueDateChanged: true)
        }

        try eventStore.save(reminder, commit: true)

        var payload: [String: Any] = [
            "success": true,
            "message": "Reminder updated successfully",
            "reminder": reminderToDict(reminder)
        ]
        // Reachable without touching alarms at all: moving the due date LATER can push an
        // existing alarm before it, so the check is on the saved state, not on what changed.
        let warnings = earlyAlarmWarnings(for: reminder)
        if !warnings.isEmpty { payload["warnings"] = warnings }
        outputJSON(payload)
    }
}

struct DeleteReminder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a reminder"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Reminder ID to delete")
    var id: String

    func run() async throws {
        try await requestReminderAccess()

        let config = pimOptions.loadConfig()

        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw CLIError.notFound("Reminder not found: \(id)")
        }

        try validateReminderAccess(reminder, config: config)

        let reminderInfo = reminderToDict(reminder)
        try eventStore.remove(reminder, commit: true)

        outputJSON([
            "success": true,
            "message": "Reminder deleted successfully",
            "deletedReminder": reminderInfo
        ])
    }
}

// MARK: - Batch Operations

struct BatchReminderInput: Codable {
    let title: String
    let list: String?
    let due: String?
    let notes: String?
    let priority: Int?
    let url: String?
    /// Mirror `url` into the notes so Apple Reminders shows a tappable link. Absent means
    /// true, matching the single-item `create` default.
    let urlInNotes: Bool?
    let alarm: [Int]?
    /// Defaults to true, matching the single-item `create` default.
    let dueAlert: Bool?
    let recurrence: RecurrenceJSON?
    let location: LocationJSON?
}

func decodeBatchReminders(_ json: String) throws -> [BatchReminderInput] {
    guard let data = json.data(using: .utf8),
          let reminders = try? JSONDecoder().decode([BatchReminderInput].self, from: data) else {
        throw CLIError.invalidInput("Invalid JSON format for reminders array")
    }

    if reminders.isEmpty {
        throw CLIError.invalidInput("Reminders array cannot be empty")
    }

    return reminders
}

func batchReminderDueDateComponents(_ due: String?) -> DateComponents? {
    guard let due else { return nil }
    return reminderDueComponents(from: due)
}

struct BatchCreateReminder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch-create",
        abstract: "Create multiple reminders in a single transaction"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "JSON array of reminders to create")
    var json: String

    func run() async throws {
        try await requestReminderAccess()

        let config = pimOptions.loadConfig()
        let reminders = try decodeBatchReminders(json)

        var createdReminders: [[String: Any]] = []
        var errors: [[String: Any]] = []
        var warnings: [String] = []

        for (index, reminderInput) in reminders.enumerated() {
            do {
                let reminder = EKReminder(eventStore: eventStore)
                reminder.title = reminderInput.title
                reminder.calendar = try resolveTargetList(explicit: reminderInput.list, config: config)

                setReminderDueDate(reminder, to: batchReminderDueDateComponents(reminderInput.due))

                if let n = reminderInput.notes {
                    reminder.notes = n
                }

                if let p = reminderInput.priority {
                    reminder.priority = p
                }

                if let urlStr = reminderInput.url, let reminderUrl = URL(string: urlStr) {
                    reminder.url = reminderUrl
                    if reminderInput.urlInNotes ?? true {
                        reminder.notes = notesWithVisibleURL(reminder.notes, url: urlStr)
                    }
                }

                if let alarms = reminderInput.alarm {
                    for minutes in alarms {
                        let alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                        reminder.addAlarm(alarm)
                    }
                }

                // Add location-based alarm if specified
                if let locationInput = reminderInput.location {
                    let locationData = try JSONEncoder().encode(locationInput)
                    if let locationStr = String(data: locationData, encoding: .utf8),
                       let locationAlarm = parseLocationAlarm(locationStr) {
                        reminder.addAlarm(locationAlarm)
                    }
                }

                // Add recurrence rule if specified
                if let recurrenceInput = reminderInput.recurrence {
                    let recurrenceJSON = try JSONEncoder().encode(recurrenceInput)
                    if let recurrenceStr = String(data: recurrenceJSON, encoding: .utf8),
                       let rule = parseRecurrenceRule(recurrenceStr) {
                        reminder.addRecurrenceRule(rule)
                    }
                }

                // Last mutation before the save, so it sees every alarm this row asked for
                // and stands down if there is one. Must precede `save`: mutating a staged
                // object after it is saved and relying on the later `commit` to notice is
                // not a contract EventKit offers.
                syncDueAlert(reminder, enabled: reminderInput.dueAlert ?? true)

                // Save with commit: false to batch changes
                try eventStore.save(reminder, commit: false)

                createdReminders.append(reminderToDict(reminder))
                warnings.append(contentsOf: earlyAlarmWarnings(for: reminder).map {
                    "\(reminderInput.title): \($0)"
                })
            } catch {
                errors.append([
                    "index": index,
                    "title": reminderInput.title,
                    "error": error.localizedDescription
                ])
            }
        }

        // Commit all changes at once
        if !createdReminders.isEmpty {
            try eventStore.commit()
        }

        var payload: [String: Any] = [
            "success": errors.isEmpty,
            "message": "Batch create completed",
            "created": createdReminders,
            "createdCount": createdReminders.count,
            "errors": errors,
            "errorCount": errors.count
        ]
        if !warnings.isEmpty { payload["warnings"] = warnings }
        outputJSON(payload)
    }
}

struct BatchCompleteReminder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch-complete",
        abstract: "Mark multiple reminders as complete in a single transaction"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "JSON array of reminder IDs to complete")
    var json: String

    @Flag(name: .long, help: "Mark as incomplete instead")
    var undo: Bool = false

    func run() async throws {
        try await requestReminderAccess()

        let config = pimOptions.loadConfig()

        guard let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            throw CLIError.invalidInput("Invalid JSON format. Expected an array of reminder ID strings.")
        }

        if ids.isEmpty {
            throw CLIError.invalidInput("IDs array cannot be empty")
        }

        var completed: [[String: Any]] = []
        var errors: [[String: Any]] = []

        for id in ids {
            guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
                errors.append([
                    "id": id,
                    "error": "Reminder not found: \(id)"
                ])
                continue
            }

            do {
                try validateReminderAccess(reminder, config: config)
            } catch {
                errors.append([
                    "id": id,
                    "error": error.localizedDescription
                ])
                continue
            }

            reminder.isCompleted = !undo
            if !undo {
                reminder.completionDate = Date()
            } else {
                reminder.completionDate = nil
            }

            do {
                try eventStore.save(reminder, commit: false)
                completed.append(reminderToDict(reminder))
            } catch {
                errors.append([
                    "id": id,
                    "error": error.localizedDescription
                ])
            }
        }

        // Commit all changes at once
        if !completed.isEmpty {
            try eventStore.commit()
        }

        outputJSON([
            "success": errors.isEmpty,
            "message": undo ? "Batch incomplete completed" : "Batch complete completed",
            "completed": completed,
            "completedCount": completed.count,
            "errors": errors,
            "errorCount": errors.count
        ])
    }
}

struct BatchDeleteReminder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch-delete",
        abstract: "Delete multiple reminders in a single transaction"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "JSON array of reminder IDs to delete")
    var json: String

    func run() async throws {
        try await requestReminderAccess()

        let config = pimOptions.loadConfig()

        guard let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            throw CLIError.invalidInput("Invalid JSON format. Expected an array of reminder ID strings.")
        }

        if ids.isEmpty {
            throw CLIError.invalidInput("IDs array cannot be empty")
        }

        var deleted: [[String: Any]] = []
        var errors: [[String: Any]] = []

        for id in ids {
            guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
                errors.append([
                    "id": id,
                    "error": "Reminder not found: \(id)"
                ])
                continue
            }

            do {
                try validateReminderAccess(reminder, config: config)
            } catch {
                errors.append([
                    "id": id,
                    "error": error.localizedDescription
                ])
                continue
            }

            let info = reminderToDict(reminder)
            do {
                try eventStore.remove(reminder, commit: false)
                deleted.append(info)
            } catch {
                errors.append([
                    "id": id,
                    "error": error.localizedDescription
                ])
            }
        }

        // Commit all changes at once
        if !deleted.isEmpty {
            try eventStore.commit()
        }

        outputJSON([
            "success": errors.isEmpty,
            "message": "Batch delete completed",
            "deleted": deleted,
            "deletedCount": deleted.count,
            "errors": errors,
            "errorCount": errors.count
        ])
    }
}

// MARK: - Config Command

// MARK: - Repair Dates

/// Returns the `startDateComponents` value that should accompany `due`.
///
/// Reminders.app stores an all-day reminder as a due date with no time and a
/// start date at 00:00, so an exact component copy is not quite right. This
/// mirrors the day fields and fills in midnight when the due date carries no
/// time of day.
func mirroredStart(from due: DateComponents) -> DateComponents {
    var start = DateComponents()
    start.year = due.year
    start.month = due.month
    start.day = due.day
    start.hour = due.hour ?? 0
    start.minute = due.minute ?? 0
    // Carry the due date's time zone across. Handing EventKit a start date
    // with no time zone makes it renormalize BOTH fields into local time on
    // save, which silently rewrites the due date's wall-clock representation.
    start.timeZone = due.timeZone
    return start
}

/// Whether two date components would be stored identically by EventKit.
///
/// The time zone is part of the comparison. Matching wall-clock fields with
/// differing zones is exactly the state that makes EventKit renormalize both
/// the start and due dates on the next save, so `repair-dates` must treat it
/// as drift rather than skipping it.
func sameStoredDate(_ a: DateComponents?, _ b: DateComponents?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return a.year == b.year && a.month == b.month && a.day == b.day
        && (a.hour ?? 0) == (b.hour ?? 0) && (a.minute ?? 0) == (b.minute ?? 0)
        && a.timeZone == b.timeZone
}

/// Repairs reminders whose start date drifted away from their due date.
///
/// Versions of this CLI before the `setReminderDate` fix wrote
/// `dueDateComponents` without touching `startDateComponents`, leaving stale
/// start dates behind. Reminders that ended up with a start date and no due
/// date render as *dateless* in Reminders.app, and some third-party clients
/// bucket them as due today.
struct RepairDates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair-dates",
        abstract: "Re-sync reminder start dates to their due dates (dry run unless --apply)"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Flag(name: .long, help: "Write the changes. Without this the command only reports.")
    var apply: Bool = false

    @Flag(name: .long, help: "Include completed reminders")
    var completed: Bool = false

    func run() async throws {
        try await requestReminderAccess()

        let config = pimOptions.loadConfig()
        var calendars: [EKCalendar]?
        if config.reminders.mode != .all {
            calendars = allowedLists(config: config)
        }

        let predicate = eventStore.predicateForReminders(in: calendars)
        let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
            eventStore.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }

        var repaired: [[String: Any]] = []
        var orphans: [[String: Any]] = []
        var errors: [[String: Any]] = []
        var scanned = 0

        for reminder in reminders where completed || !reminder.isCompleted {
            scanned += 1

            // Start date but no due date: Reminders.app shows these as dateless.
            // Picking a due date is a judgement call, so only report them.
            guard let due = reminder.dueDateComponents else {
                if let start = reminder.startDateComponents {
                    orphans.append([
                        "id": reminder.calendarItemIdentifier,
                        "title": reminder.title ?? "",
                        "list": reminder.calendar?.title ?? "",
                        "startDate": dateComponentsToString(start)
                    ])
                }
                continue
            }

            let desired = mirroredStart(from: due)
            if sameStoredDate(reminder.startDateComponents, desired) { continue }

            var change: [String: Any] = [
                "id": reminder.calendarItemIdentifier,
                "title": reminder.title ?? "",
                "list": reminder.calendar?.title ?? "",
                "dueDate": dateComponentsToString(due),
                "oldStartDate": reminder.startDateComponents.map { dateComponentsToString($0) } ?? "none",
                "newStartDate": dateComponentsToString(desired),
                "dueTimeZone": due.timeZone?.identifier ?? "none",
                "oldStartTimeZone": reminder.startDateComponents?.timeZone?.identifier ?? "none",
                "recurring": reminder.hasRecurrenceRules
            ]

            if apply {
                reminder.startDateComponents = desired
                do {
                    try eventStore.save(reminder, commit: false)
                } catch {
                    change["error"] = error.localizedDescription
                    errors.append(change)
                    continue
                }
            }
            repaired.append(change)
        }

        if apply && !repaired.isEmpty {
            try eventStore.commit()
        }

        outputJSON([
            "success": errors.isEmpty,
            "applied": apply,
            "scanned": scanned,
            "repairedCount": repaired.count,
            "repaired": repaired,
            "orphanedCount": orphans.count,
            "orphaned": orphans,
            "errors": errors
        ])
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage PIM configuration",
        subcommands: [ConfigShow.self, ConfigInit.self]
    )
}

struct ConfigShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Display the resolved configuration (base + profile)"
    )

    @OptionGroup var pimOptions: PIMOptions

    func run() throws {
        let config = pimOptions.loadConfig()
        let ctx = pimOptions.outputContext
        let activeProfile = pimOptions.profile ?? ProcessInfo.processInfo.environment["APPLE_PIM_PROFILE"]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        pimOutput(
            [
                "success": true,
                "configPath": ConfigLoader.defaultConfigPath.path,
                "profilesDir": ConfigLoader.profilesDir.path,
                "activeProfile": activeProfile as Any,
                "config": (try? JSONSerialization.jsonObject(with: data)) ?? [:]
            ],
            text: ConfigFormatter.formatConfigShow(
                config: config,
                configPath: ConfigLoader.defaultConfigPath.path,
                profilesDir: ConfigLoader.profilesDir.path,
                activeProfile: activeProfile
            ),
            context: ctx
        )
    }
}

struct ConfigInit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "List available reminder lists for configuration setup"
    )

    @OptionGroup var pimOptions: PIMOptions

    func run() async throws {
        try await requestReminderAccess()
        let ctx = pimOptions.outputContext

        let lists = eventStore.calendars(for: .reminder).map { listToDict($0) }
        let defaultRem = eventStore.defaultCalendarForNewReminders()?.title ?? ""

        pimOutput(
            [
                "success": true,
                "configPath": ConfigLoader.defaultConfigPath.path,
                "profilesDir": ConfigLoader.profilesDir.path,
                "availableReminderLists": lists,
                "defaultReminderList": defaultRem
            ],
            text: ConfigFormatter.formatConfigInit(
                configPath: ConfigLoader.defaultConfigPath.path,
                profilesDir: ConfigLoader.profilesDir.path,
                reminderLists: lists,
                defaultReminderList: defaultRem
            ),
            context: ctx
        )
    }
}

