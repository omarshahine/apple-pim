import ArgumentParser
import EventKit
import Foundation
import PIMConfig
import ReminderKitShim

// Opt-in writes for Reminders metadata EventKit cannot write: flags, subtasks, sections and
// tags. They go through Apple's private ReminderKit framework (ReminderKitShim), which saves
// through remindd exactly as Reminders.app does, so CloudKit sync is unchanged. Nothing here
// writes the Reminders database.
//
// ReminderKit is unsupported and can change in any macOS update, so every write is gated and
// checked:
//   1. Off by default. Each command refuses to run without --private.
//   2. PIMConfig: the reminder (and parent, for subtasks) must be in an allowed list.
//   3. Preconditions are checked against the store before anything is sent.
//   4. Exactly one write. A write that throws is reported, never retried.
//   5. The store is read back until it shows the intended change AND the fields the
//      operation must not touch are unchanged. If it does not, the command fails and
//      reports what it observed. It still does not retry.
//
// Verification needs the read-only store (Full Disk Access). Without it no private write
// is attempted, because its outcome could not be checked.

// MARK: - Seams

protocol PrivateReminderWriting {
    func setFlagged(_ flagged: Bool, reminderID: String) throws
    func addSubtask(title: String, parentID: String) throws -> String
    func move(reminderID: String, parentID: String?) throws
    func assign(reminderID: String, sectionID: String) throws
    func replaceTags(_ tags: [String], reminderID: String) throws
}

protocol ReminderMetadataReading {
    func metadata(for ids: [String]) throws -> [String: ReminderMetadata]
    func sections(forLists listIds: [String]) throws -> [String: [ReminderSectionRef]]
    func strictSectionMemberships(forList listId: String) throws -> [String: String?]
}

extension ReminderMetadataStore: ReminderMetadataReading {}

/// The real writer, over the Objective-C ReminderKit shim.
struct ReminderKitWriter: PrivateReminderWriting {
    func setFlagged(_ flagged: Bool, reminderID: String) throws {
        try APRKShim.setFlagged(flagged, reminderID: reminderID)
    }
    func addSubtask(title: String, parentID: String) throws -> String {
        try APRKShim.addSubtask(withTitle: title, parentID: parentID)
    }
    func move(reminderID: String, parentID: String?) throws {
        try APRKShim.moveReminderID(reminderID, parentID: parentID)
    }
    func assign(reminderID: String, sectionID: String) throws {
        try APRKShim.assignReminderID(reminderID, sectionID: sectionID)
    }
    func replaceTags(_ tags: [String], reminderID: String) throws {
        try APRKShim.replaceTags(tags, reminderID: reminderID)
    }
}

// MARK: - Errors

enum PrivateWriteError: Error, LocalizedError, Equatable {
    case notEnabled(String)
    case storeUnavailable(String)
    case notFound(String)
    case precondition(String)
    case writeFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notEnabled(let m), .storeUnavailable(let m), .notFound(let m),
             .precondition(let m), .writeFailed(let m), .verificationFailed(let m):
            return m
        }
    }
}

// MARK: - Tags

/// Normalizes a tag as Reminders shows it: no leading '#', no surrounding whitespace.
/// Rejects empty tags and tags containing whitespace, which Reminders cannot represent.
func normalizeTag(_ raw: String) throws -> String {
    var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while tag.hasPrefix("#") { tag.removeFirst() }
    guard !tag.isEmpty else {
        throw PrivateWriteError.precondition("Empty tag: '\(raw)'")
    }
    guard tag.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !tag.contains("#") else {
        throw PrivateWriteError.precondition("Tags cannot contain spaces or '#': '\(raw)'")
    }
    guard tag.count <= 64 else {
        throw PrivateWriteError.precondition("Tag longer than 64 characters: '\(raw)'")
    }
    return tag
}

/// `current` plus `add`, minus `remove`, compared case-insensitively. Existing spellings
/// are kept; new tags keep the caller's spelling.
func computeTags(current: [String], add: [String], remove: [String]) -> [String] {
    var result: [String] = []
    func contains(_ list: [String], _ tag: String) -> Bool {
        list.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
    for tag in current + add where !contains(result, tag) { result.append(tag) }
    return result.filter { !contains(remove, $0) }
}

func sameTagSet(_ a: [String], _ b: [String]) -> Bool {
    Set(a.map { $0.lowercased() }) == Set(b.map { $0.lowercased() })
}

// MARK: - Coordinator

struct PrivateWriteCoordinator {
    let writer: PrivateReminderWriting
    let reader: ReminderMetadataReading
    /// Readback polls: remindd commits before the save returns, but the WAL may lag a beat.
    var attempts = 15
    var delay: TimeInterval = 0.2
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    func current(_ id: String) throws -> ReminderMetadata {
        guard let meta = try reader.metadata(for: [id])[id] else {
            throw PrivateWriteError.notFound("Reminder \(id) is not in the Reminders store")
        }
        return meta
    }

    /// Polls the store until `check` passes. Returns the last observed state either way.
    private func waitFor(_ id: String, _ check: (ReminderMetadata?) throws -> Bool) throws -> (Bool, ReminderMetadata?) {
        var last: ReminderMetadata?
        for attempt in 0..<max(attempts, 1) {
            last = try reader.metadata(for: [id])[id]
            if try check(last) { return (true, last) }
            if attempt < attempts - 1 { sleep(delay) }
        }
        return (false, last)
    }

    private func write(_ what: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as PrivateWriteError {
            throw error
        } catch {
            throw PrivateWriteError.writeFailed(
                "ReminderKit \(what) failed and was not retried: \(error.localizedDescription)")
        }
    }

    private func unchanged(_ a: ReminderMetadata, _ b: ReminderMetadata,
                           flag: Bool = true, tags: Bool = true, parent: Bool = true, section: Bool = true) -> [String] {
        var drift: [String] = []
        if a.listId?.uppercased() != b.listId?.uppercased() { drift.append("list") }
        if flag && a.flagged != b.flagged { drift.append("flagged") }
        if tags && !sameTagSet(a.tags, b.tags) { drift.append("tags") }
        if parent && a.parentId?.uppercased() != b.parentId?.uppercased() { drift.append("parent") }
        if section && a.section?.id.uppercased() != b.section?.id.uppercased() { drift.append("section") }
        return drift
    }

    private func verificationFailure(_ what: String, expected: String, observed: ReminderMetadata?, drift: [String] = []) -> PrivateWriteError {
        var observedText = "reminder missing from the store"
        if let observed {
            observedText = "flagged=\(observed.flagged), parent=\(observed.parentId ?? "none"), "
                + "section=\(observed.section?.name ?? "none"), tags=\(observed.tags)"
        }
        let driftText = drift.isEmpty ? "" : " Fields that changed but should not have: \(drift.joined(separator: ", "))."
        return .verificationFailed(
            "ReminderKit \(what) saved, but the Reminders store does not show the expected result "
            + "(expected \(expected); observed \(observedText)).\(driftText) The write was not "
            + "retried. Check the reminder in Reminders.app.")
    }

    private func result(_ action: String, changed: Bool, meta: ReminderMetadata, extra: [String: Any] = [:]) -> [String: Any] {
        var reminder = meta.toDict()
        reminder["id"] = meta.id
        if let title = meta.title { reminder["title"] = title }
        var payload: [String: Any] = [
            "success": true,
            "action": action,
            "changed": changed,
            "verified": true,
            "reminder": reminder,
        ]
        for (k, v) in extra { payload[k] = v }
        return payload
    }

    // MARK: Operations

    func setFlag(id: String, flagged: Bool) throws -> [String: Any] {
        let before = try current(id)
        if before.flagged == flagged { return result("set_flag", changed: false, meta: before) }
        try write("flag update") { try writer.setFlagged(flagged, reminderID: id) }
        var drift: [String] = []
        let (ok, after) = try waitFor(id) { meta in
            guard let meta, meta.flagged == flagged else { return false }
            drift = unchanged(before, meta, flag: false)
            return drift.isEmpty
        }
        guard ok, let after else {
            throw verificationFailure("flag update", expected: "flagged=\(flagged)", observed: after, drift: drift)
        }
        return result("set_flag", changed: true, meta: after)
    }

    func addSubtask(parentID: String, title: String) throws -> [String: Any] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PrivateWriteError.precondition("A subtask title is required") }
        let parent = try current(parentID)
        guard parent.parentId == nil else {
            throw PrivateWriteError.precondition(
                "Reminder \(parentID) is itself a subtask; Reminders allows one level of subtasks")
        }
        var newID = ""
        try write("subtask creation") { newID = try writer.addSubtask(title: trimmed, parentID: parentID) }
        let (ok, child) = try waitFor(newID) { meta in
            guard let meta else { return false }
            return meta.parentId?.uppercased() == parentID.uppercased()
                && meta.title == trimmed
                && meta.listId?.uppercased() == parent.listId?.uppercased()
        }
        guard ok, let child else {
            throw verificationFailure("subtask creation", expected: "a subtask '\(trimmed)' under \(parentID)", observed: child)
        }
        let parentAfter = try current(parentID)
        let drift = unchanged(parent, parentAfter)
        guard drift.isEmpty, parentAfter.subtaskIds.contains(where: { $0.uppercased() == newID.uppercased() }) else {
            throw verificationFailure("subtask creation", expected: "parent \(parentID) otherwise unchanged",
                                      observed: parentAfter, drift: drift)
        }
        return result("add_subtask", changed: true, meta: child, extra: ["parent": {
            var dict = parentAfter.toDict(); dict["id"] = parentAfter.id; return dict
        }()])
    }

    func moveSubtask(id: String, parentID: String?) throws -> [String: Any] {
        let before = try current(id)
        if let parentID {
            guard parentID.uppercased() != id.uppercased() else {
                throw PrivateWriteError.precondition("A reminder cannot be its own parent")
            }
            let parent = try current(parentID)
            guard parent.parentId == nil else {
                throw PrivateWriteError.precondition(
                    "Reminder \(parentID) is itself a subtask; Reminders allows one level of subtasks")
            }
            guard parent.listId?.uppercased() == before.listId?.uppercased() else {
                throw PrivateWriteError.precondition(
                    "The reminder and its new parent are in different lists. Moving across lists is not supported.")
            }
            guard before.subtaskIds.isEmpty else {
                throw PrivateWriteError.precondition("A reminder with its own subtasks cannot become a subtask")
            }
            if before.parentId?.uppercased() == parentID.uppercased() {
                return result("move_subtask", changed: false, meta: before)
            }
        } else if before.parentId == nil {
            return result("move_subtask", changed: false, meta: before)
        }
        try write("subtask move") { try writer.move(reminderID: id, parentID: parentID) }
        var drift: [String] = []
        let (ok, after) = try waitFor(id) { meta in
            guard let meta, meta.parentId?.uppercased() == parentID?.uppercased() else { return false }
            drift = unchanged(before, meta, parent: false, section: false)
            return drift.isEmpty
        }
        guard ok, let after else {
            throw verificationFailure("subtask move", expected: "parent=\(parentID ?? "none")", observed: after, drift: drift)
        }
        return result("move_subtask", changed: true, meta: after)
    }

    /// Resolves `section` (an ID or a case-insensitive name) within the reminder's list.
    func resolveSection(_ section: String, listId: String) throws -> ReminderSectionRef {
        let sections = try reader.sections(forLists: [listId])[listId] ?? []
        if let byID = sections.first(where: { $0.id.caseInsensitiveCompare(section) == .orderedSame }) {
            return byID
        }
        let byName = sections.filter { $0.name.caseInsensitiveCompare(section) == .orderedSame }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 {
            throw PrivateWriteError.precondition(
                "More than one section in this list is named '\(section)'. Pass a section ID: "
                + byName.map(\.id).joined(separator: ", "))
        }
        let names = sections.map { "'\($0.name)'" }.joined(separator: ", ")
        throw PrivateWriteError.notFound(
            "No section '\(section)' in the reminder's list. Sections: \(names.isEmpty ? "none" : names)")
    }

    func setSection(id: String, section: String) throws -> [String: Any] {
        let before = try current(id)
        guard let listId = before.listId else {
            throw PrivateWriteError.precondition("Reminder \(id) has no list in the store")
        }
        let target = try resolveSection(section, listId: listId)
        if before.section?.id.uppercased() == target.id.uppercased() {
            return result("set_section", changed: false, meta: before)
        }
        func others(_ map: [String: String?]) -> [String: String] {
            var out: [String: String] = [:]
            for (key, value) in map where key != id.uppercased() {
                if let value { out[key] = value.uppercased() }
            }
            return out
        }
        let othersBefore = others(try reader.strictSectionMemberships(forList: listId))
        try write("section assignment") { try writer.assign(reminderID: id, sectionID: target.id) }
        var drift: [String] = []
        let (ok, after) = try waitFor(id) { meta in
            guard let meta, meta.section?.id.uppercased() == target.id.uppercased() else { return false }
            drift = unchanged(before, meta, section: false)
            if others(try reader.strictSectionMemberships(forList: listId)) != othersBefore {
                drift.append("other reminders' sections")
            }
            return drift.isEmpty
        }
        guard ok, let after else {
            throw verificationFailure("section assignment", expected: "section '\(target.name)'", observed: after, drift: drift)
        }
        return result("set_section", changed: true, meta: after)
    }

    func setTags(id: String, add: [String], remove: [String]) throws -> [String: Any] {
        let addTags = try add.map(normalizeTag)
        let removeTags = try remove.map(normalizeTag)
        guard !addTags.isEmpty || !removeTags.isEmpty else {
            throw PrivateWriteError.precondition("Pass at least one tag to add or remove")
        }
        let before = try current(id)
        let expected = computeTags(current: before.tags, add: addTags, remove: removeTags)
        if sameTagSet(before.tags, expected) { return result("set_tags", changed: false, meta: before) }
        try write("tag update") { try writer.replaceTags(expected, reminderID: id) }
        var drift: [String] = []
        let (ok, after) = try waitFor(id) { meta in
            guard let meta, sameTagSet(meta.tags, expected) else { return false }
            drift = unchanged(before, meta, tags: false)
            return drift.isEmpty
        }
        guard ok, let after else {
            throw verificationFailure("tag update", expected: "tags=\(expected)", observed: after, drift: drift)
        }
        return result("set_tags", changed: true, meta: after)
    }
}

// MARK: - Command plumbing

struct PrivateWriteOptions: ParsableArguments {
    @Flag(name: .customLong("private"), help: ArgumentHelp(
        "Required. Confirms this write may use Apple's private ReminderKit framework, which is "
        + "unsupported and can change in any macOS update. The result is read back from the "
        + "Reminders database (needs Full Disk Access) and the command fails if it does not match."))
    var enabled: Bool = false
}

/// Gates, checks PIMConfig for every reminder involved, then runs `body` with a coordinator.
func runPrivateWrite(_ options: PrivateWriteOptions, pimOptions: PIMOptions, command: String,
                     reminderIDs: [String],
                     _ body: (PrivateWriteCoordinator) throws -> [String: Any]) async throws {
    guard options.enabled else {
        throw PrivateWriteError.notEnabled(
            "\(command) writes through Apple's private ReminderKit framework and is off by default. "
            + "Pass --private to confirm.")
    }
    try await requestReminderAccess()
    let config = pimOptions.loadConfig()
    try checkRemindersEnabled(config: config)
    for id in reminderIDs {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw CLIError.notFound("Reminder not found: \(id)")
        }
        try validateReminderAccess(reminder, config: config)
    }
    let store: ReminderMetadataStore
    switch SharedReminderStore.get() {
    case .success(let opened): store = opened
    case .failure(let error):
        throw PrivateWriteError.storeUnavailable(
            "Private writes are verified by reading the Reminders database back, and it cannot be "
            + "read, so nothing was written. \(error.localizedDescription)")
    }
    let coordinator = PrivateWriteCoordinator(writer: ReminderKitWriter(), reader: store)
    outputJSON(try body(coordinator))
}

// MARK: - Commands

struct SetFlag: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-flag",
        abstract: "Flag or unflag a reminder (private ReminderKit write; requires --private)"
    )

    @OptionGroup var pimOptions: PIMOptions
    @OptionGroup var privateOptions: PrivateWriteOptions

    @Option(name: .long, help: "Reminder ID")
    var id: String

    @Flag(name: .long, help: "Remove the flag instead of setting it")
    var unflag: Bool = false

    func run() async throws {
        try await runPrivateWrite(privateOptions, pimOptions: pimOptions, command: "set-flag", reminderIDs: [id]) {
            try $0.setFlag(id: id, flagged: !unflag)
        }
    }
}

struct AddSubtask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-subtask",
        abstract: "Create a subtask under a reminder (private ReminderKit write; requires --private)",
        discussion: "Only the title is set here. Use `update --id <new id>` for a due date or notes."
    )

    @OptionGroup var pimOptions: PIMOptions
    @OptionGroup var privateOptions: PrivateWriteOptions

    @Option(name: .long, help: "Parent reminder ID (must be a top-level reminder)")
    var parent: String

    @Option(name: .long, help: "Subtask title")
    var title: String

    func run() async throws {
        try await runPrivateWrite(privateOptions, pimOptions: pimOptions, command: "add-subtask", reminderIDs: [parent]) {
            try $0.addSubtask(parentID: parent, title: title)
        }
    }
}

struct MoveSubtask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move-subtask",
        abstract: "Make a reminder a subtask of another in the same list, or top-level again (private ReminderKit write; requires --private)"
    )

    @OptionGroup var pimOptions: PIMOptions
    @OptionGroup var privateOptions: PrivateWriteOptions

    @Option(name: .long, help: "Reminder ID to move")
    var id: String

    @Option(name: .long, help: "New parent reminder ID (same list, top-level)")
    var parent: String?

    @Flag(name: .customLong("top-level"), help: "Make the reminder top-level again")
    var topLevel: Bool = false

    func validate() throws {
        guard (parent != nil) != topLevel else {
            throw ValidationError("Pass exactly one of --parent or --top-level")
        }
    }

    func run() async throws {
        let ids = [id] + (parent.map { [$0] } ?? [])
        try await runPrivateWrite(privateOptions, pimOptions: pimOptions, command: "move-subtask", reminderIDs: ids) {
            try $0.moveSubtask(id: id, parentID: parent)
        }
    }
}

struct SetSection: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-section",
        abstract: "Put a reminder into a section of its list (private ReminderKit write; requires --private)",
        discussion: "Sections are listed by `lists` (needs Full Disk Access). Removing a reminder from a section is not supported."
    )

    @OptionGroup var pimOptions: PIMOptions
    @OptionGroup var privateOptions: PrivateWriteOptions

    @Option(name: .long, help: "Reminder ID")
    var id: String

    @Option(name: .long, help: "Section name or ID within the reminder's list")
    var section: String

    func run() async throws {
        try await runPrivateWrite(privateOptions, pimOptions: pimOptions, command: "set-section", reminderIDs: [id]) {
            try $0.setSection(id: id, section: section)
        }
    }
}

struct SetTags: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-tags",
        abstract: "Add or remove a reminder's tags (private ReminderKit write; requires --private)"
    )

    @OptionGroup var pimOptions: PIMOptions
    @OptionGroup var privateOptions: PrivateWriteOptions

    @Option(name: .long, help: "Reminder ID")
    var id: String

    @Option(name: .long, help: "Tag to add (repeatable; a leading # is ignored)")
    var add: [String] = []

    @Option(name: .long, help: "Tag to remove (repeatable; case-insensitive)")
    var remove: [String] = []

    func run() async throws {
        try await runPrivateWrite(privateOptions, pimOptions: pimOptions, command: "set-tags", reminderIDs: [id]) {
            try $0.setTags(id: id, add: add, remove: remove)
        }
    }
}
