import ArgumentParser
import EventKit
import Foundation

/// Where `events`, `get` and `search` may take an event's availability from.
/// auto: EventKit, plus the local Calendar store for subscribed events EventKit cannot
/// answer, falling back silently when the store is unreadable. sqlite: the same, but the
/// store must be readable. eventkit: EventKit only; the store is never opened.
enum EngineChoice: String, ExpressibleByArgument {
    case auto
    case sqlite
    case eventkit
}

/// In `--engine sqlite` mode a store failure is fatal; in auto mode the
/// caller keeps EventKit's value.
func rethrowFatalStoreError(_ engine: EngineChoice, _ error: Error) throws {
    guard engine == .sqlite else { return }
    let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    throw CLIError.accessDenied(
        "SQLite engine failed: \(detail) (retry with --engine auto or eventkit, or grant Full Disk Access)")
}

/// Chooses each event's availability for one request.
///
/// EventKit's value is used unless the event's calendar is a subscription
/// (`EKCalendar.isSubscribed`) and EventKit reports `notSupported` for it. Only then is the
/// store consulted (`CalendarStore.storedAvailability`); no unique row or nothing usable
/// keeps EventKit's value. The store is opened at most once per request, so every lookup
/// shares one snapshot.
final class AvailabilityResolver {
    private let engine: EngineChoice
    private let storePath: URL
    private var store: CalendarStore?
    private var storeTried = false

    init(engine: EngineChoice, storePath: URL = CalendarStore.defaultPath()) throws {
        self.engine = engine
        self.storePath = storePath
        if engine == .sqlite {
            storeTried = true
            do {
                store = try CalendarStore(path: storePath)
            } catch {
                try rethrowFatalStoreError(engine, error)
            }
        }
    }

    /// Whether the store was opened for this request: always under `--engine sqlite`, and
    /// under `auto` once an event needed it and it was readable. Responses then carry
    /// `"engine": "sqlite"`.
    var openedStore: Bool { store != nil }

    func availability(for event: EKEvent) throws -> String {
        try availability(
            isSubscribed: event.calendar?.isSubscribed ?? false,
            native: event.availability,
            calendarID: event.calendar?.calendarIdentifier,
            itemID: event.calendarItemIdentifier)
    }

    func availability(isSubscribed: Bool, native: EKEventAvailability,
                      calendarID: String?, itemID: String?) throws -> String {
        let eventKitValue = availabilityString(native)
        guard engine != .eventkit, isSubscribed, native == .notSupported,
              let calendarID, !calendarID.isEmpty, let itemID, !itemID.isEmpty,
              let store = currentStore()
        else { return eventKitValue }

        do {
            return try store.storedAvailability(calendarUUID: calendarID, itemUUID: itemID) ?? eventKitValue
        } catch {
            try rethrowFatalStoreError(engine, error)
            return eventKitValue
        }
    }

    private func currentStore() -> CalendarStore? {
        if !storeTried {
            storeTried = true
            store = try? CalendarStore(path: storePath)
        }
        return store
    }
}
