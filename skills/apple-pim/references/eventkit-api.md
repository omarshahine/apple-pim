# EventKit API Reference

## Calendar Events

Events are represented by `EKEvent` with these key properties:

| Property | Type | Description |
|----------|------|-------------|
| `eventIdentifier` | String | Unique stable identifier |
| `title` | String | Event title |
| `startDate` | Date | Start date/time |
| `endDate` | Date | End date/time |
| `isAllDay` | Bool | All-day event flag |
| `location` | String? | Location text |
| `notes` | String? | Notes/description |
| `calendar` | EKCalendar | Parent calendar |
| `url` | URL? | Associated URL. **Apple Reminders does not display this** on iOS or macOS — it is visible only to EventKit clients. `reminder-cli` mirrors the value into `notes` as a `🔗 <url>` line so the link is actually reachable by the user |
| `recurrenceRules` | [EKRecurrenceRule]? | Repeat rules |
| `alarms` | [EKAlarm]? | Reminders/alerts |
| `attendees` | [EKParticipant]? | Invitees (read-only) |

## Reminders

Reminders are represented by `EKReminder`:

| Property | Type | Description |
|----------|------|-------------|
| `calendarItemIdentifier` | String | Unique identifier |
| `title` | String | Reminder title |
| `isCompleted` | Bool | Completion status |
| `completionDate` | Date? | When marked complete |
| `dueDateComponents` | DateComponents? | Due date |
| `startDateComponents` | DateComponents? | Start date |
| `priority` | Int | 0=none, 1=high, 5=medium, 9=low |
| `notes` | String? | Notes text |
| `url` | URL? | Associated URL |
| `calendar` | EKCalendar | Parent reminder list |
| `alarms` | [EKAlarm]? | Time-based and location-based alarms |

## Reminder Filtering

The MCP server supports date-based filtering at the server level:

| Filter | Behavior |
|--------|----------|
| `overdue` | Incomplete reminders with due date before today |
| `today` | Due today + overdue (incomplete with due <= end of today) |
| `tomorrow` | Due date falls on tomorrow |
| `week` | Due date falls within current calendar week |
| `upcoming` | All incomplete reminders with any due date |
| `completed` | Finished reminders |
| `all` | Everything |

Results are sorted by due date (earliest first), with undated items last.

## Calendars and Lists

`EKCalendar` represents both calendars (for events) and reminder lists:

| Property | Type | Description |
|----------|------|-------------|
| `calendarIdentifier` | String | Unique identifier |
| `title` | String | Display name |
| `type` | EKCalendarType | local, caldav, exchange, etc. |
| `source` | EKSource | Account (iCloud, Exchange, etc.) |
| `allowsContentModifications` | Bool | Read-only check |
| `cgColor` | CGColor? | Calendar color |

## Recurrence Rules

`EKRecurrenceRule` defines repeating patterns:

```swift
// Daily for 10 occurrences
let rule = EKRecurrenceRule(
    recurrenceWith: .daily,
    interval: 1,
    end: EKRecurrenceEnd(occurrenceCount: 10)
)

// Weekly on Mon/Wed/Fri
let rule = EKRecurrenceRule(
    recurrenceWith: .weekly,
    interval: 1,
    daysOfTheWeek: [.monday, .wednesday, .friday],
    daysOfTheMonth: nil,
    monthsOfTheYear: nil,
    weeksOfTheYear: nil,
    daysOfTheYear: nil,
    setPositions: nil,
    end: nil
)
```

## Alarms

`EKAlarm` provides notifications:

```swift
// 15 minutes before
let alarm = EKAlarm(relativeOffset: -15 * 60)

// At specific time
let alarm = EKAlarm(absoluteDate: alertDate)
```

## Location-Based Alarms

`EKAlarm` can trigger based on arriving at or departing from a geofenced location:

```swift
let location = EKStructuredLocation(title: "Home")
location.geoLocation = CLLocation(latitude: 37.33, longitude: -122.03)
location.radius = 100.0 // meters

let alarm = EKAlarm()
alarm.structuredLocation = location
alarm.proximity = .enter // .enter = arriving, .leave = departing

reminder.addAlarm(alarm)
```

This enables "Remind me when I arrive home" or "Remind me when I leave the office" style reminders.

## Authorization

### macOS 14+ (Sonoma)

EventKit requires full access:
```swift
try await eventStore.requestFullAccessToEvents()
try await eventStore.requestFullAccessToReminders()
```

### Earlier macOS Versions

```swift
try await eventStore.requestAccess(to: .event)
try await eventStore.requestAccess(to: .reminder)
```
