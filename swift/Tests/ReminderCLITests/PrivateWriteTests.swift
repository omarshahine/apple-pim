import Foundation
import PIMConfig
import XCTest
@testable import ReminderCLI

/// In-memory stand-in for the Reminders store and ReminderKit. The fake writer mutates the
/// fake store the way a real save would, unless told to misbehave.
final class FakeReminders: ReminderMetadataReading, PrivateReminderWriting {
    var items: [String: ReminderMetadata] = [:]
    var sectionsByList: [String: [ReminderSectionRef]] = [:]
    /// Extra section memberships of other reminders, keyed by list.
    var otherMemberships: [String: [String: String?]] = [:]

    var calls: [String] = []
    var failWith: Error?
    /// Accept the write but change nothing (a silent no-op save).
    var dropWrites = false
    /// Apply the write, then also corrupt an unrelated field.
    var sideEffect: ((FakeReminders, String) -> Void)?
    /// Number of reads before a write becomes visible (WAL lag).
    var visibleAfterReads = 0
    private var pending: (() -> Void)?
    private var readsSinceWrite = 0

    func metadata(for ids: [String]) throws -> [String: ReminderMetadata] {
        if let apply = pending {
            readsSinceWrite += 1
            if readsSinceWrite > visibleAfterReads { apply(); pending = nil }
        }
        var out: [String: ReminderMetadata] = [:]
        for id in ids {
            guard let meta = items[id.uppercased()] else { continue }
            var copy = meta
            copy.subtaskIds = items.values.filter { $0.parentId?.uppercased() == id.uppercased() }.map(\.id).sorted()
            out[id] = copy
        }
        return out
    }

    func sections(forLists listIds: [String]) throws -> [String: [ReminderSectionRef]] {
        var out: [String: [ReminderSectionRef]] = [:]
        for id in listIds { out[id] = sectionsByList[id] ?? [] }
        return out
    }

    func strictSectionMemberships(forList listId: String) throws -> [String: String?] {
        var map = otherMemberships[listId] ?? [:]
        for meta in items.values where meta.listId == listId {
            map[meta.id.uppercased()] = .some(meta.section?.id)
        }
        return map
    }

    private func perform(_ name: String, id: String, _ change: @escaping () -> Void) throws {
        calls.append(name)
        if let failWith { throw failWith }
        if dropWrites { return }
        pending = { [unowned self] in
            change()
            sideEffect?(self, id)
        }
        readsSinceWrite = 0
    }

    func setFlagged(_ flagged: Bool, reminderID: String) throws {
        try perform("setFlagged", id: reminderID) { self.items[reminderID.uppercased()]?.flagged = flagged }
    }

    func addSubtask(title: String, parentID: String) throws -> String {
        let newID = "NEW00000-0000-0000-0000-000000000001"
        try perform("addSubtask", id: newID) {
            var child = ReminderMetadata(id: newID)
            child.title = title
            child.parentId = parentID
            child.listId = self.items[parentID.uppercased()]?.listId
            self.items[newID] = child
        }
        return newID
    }

    func move(reminderID: String, parentID: String?) throws {
        try perform("move", id: reminderID) { self.items[reminderID.uppercased()]?.parentId = parentID }
    }

    func assign(reminderID: String, sectionID: String) throws {
        try perform("assign", id: reminderID) {
            let listId = self.items[reminderID.uppercased()]?.listId ?? ""
            self.items[reminderID.uppercased()]?.section = self.sectionsByList[listId]?.first { $0.id == sectionID }
        }
    }

    func replaceTags(_ tags: [String], reminderID: String) throws {
        try perform("replaceTags", id: reminderID) { self.items[reminderID.uppercased()]?.tags = tags }
    }
}

final class PrivateWriteTests: XCTestCase {
    let list = "LIST0000-0000-0000-0000-000000000001"
    let otherList = "LIST0000-0000-0000-0000-000000000002"
    let a = "AAAAAAAA-0000-0000-0000-00000000000A"
    let b = "BBBBBBBB-0000-0000-0000-00000000000B"
    let c = "CCCCCCCC-0000-0000-0000-00000000000C"
    let work = ReminderSectionRef(id: "5EC00000-0000-0000-0000-000000000001", name: "Work", listId: "LIST0000-0000-0000-0000-000000000001")
    let errands = ReminderSectionRef(id: "5EC00000-0000-0000-0000-000000000002", name: "Errands", listId: "LIST0000-0000-0000-0000-000000000001")

    var fake: FakeReminders!

    override func setUp() {
        fake = FakeReminders()
        for (id, listId) in [(a, list), (b, list), (c, otherList)] {
            var meta = ReminderMetadata(id: id)
            meta.title = "Reminder \(id.prefix(1))"
            meta.listId = listId
            fake.items[id] = meta
        }
        fake.items[a]?.tags = ["home"]
        fake.sectionsByList[list] = [work, errands]
    }

    private func coordinator(attempts: Int = 3) -> PrivateWriteCoordinator {
        var co = PrivateWriteCoordinator(writer: fake, reader: fake)
        co.attempts = attempts
        co.sleep = { _ in }
        return co
    }

    // MARK: flag

    func testFlagWritesOnceAndVerifies() throws {
        let out = try coordinator().setFlag(id: a, flagged: true)
        XCTAssertEqual(fake.calls, ["setFlagged"])
        XCTAssertEqual(out["verified"] as? Bool, true)
        XCTAssertEqual(out["changed"] as? Bool, true)
        XCTAssertEqual((out["reminder"] as? [String: Any])?["flagged"] as? Bool, true)
    }

    func testAlreadyFlaggedSkipsTheWrite() throws {
        fake.items[a]?.flagged = true
        let out = try coordinator().setFlag(id: a, flagged: true)
        XCTAssertEqual(fake.calls, [], "no private write when nothing would change")
        XCTAssertEqual(out["changed"] as? Bool, false)
    }

    func testReadbackWaitsForLaggingStore() throws {
        fake.visibleAfterReads = 2
        _ = try coordinator(attempts: 5).setFlag(id: a, flagged: true)
        XCTAssertEqual(fake.calls, ["setFlagged"], "polling reads again, it never writes again")
    }

    func testWriteErrorIsReportedAndNotRetried() {
        fake.failWith = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        XCTAssertThrowsError(try coordinator().setFlag(id: a, flagged: true)) { error in
            guard case PrivateWriteError.writeFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("boom"))
            XCTAssertTrue(message.contains("not retried"))
        }
        XCTAssertEqual(fake.calls, ["setFlagged"])
    }

    func testSilentNoOpSaveFailsVerificationWithoutRetry() {
        fake.dropWrites = true
        XCTAssertThrowsError(try coordinator().setFlag(id: a, flagged: true)) { error in
            guard case PrivateWriteError.verificationFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("expected flagged=true"))
        }
        XCTAssertEqual(fake.calls, ["setFlagged"])
    }

    func testCollateralDamageFailsVerification() {
        fake.sideEffect = { fake, id in fake.items[id]?.tags = [] }
        XCTAssertThrowsError(try coordinator().setFlag(id: a, flagged: true)) { error in
            guard case PrivateWriteError.verificationFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("tags"), message)
        }
    }

    func testMissingReminderIsNotFound() {
        XCTAssertThrowsError(try coordinator().setFlag(id: "FFFFFFFF-0000-0000-0000-000000000000", flagged: true)) {
            XCTAssertEqual($0 as? PrivateWriteError, .notFound("Reminder FFFFFFFF-0000-0000-0000-000000000000 is not in the Reminders store"))
        }
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: subtasks

    func testAddSubtaskVerifiesChildAndParent() throws {
        let out = try coordinator().addSubtask(parentID: a, title: "  Step one ")
        XCTAssertEqual(fake.calls, ["addSubtask"])
        let reminder = try XCTUnwrap(out["reminder"] as? [String: Any])
        XCTAssertEqual(reminder["title"] as? String, "Step one")
        XCTAssertEqual(reminder["parentId"] as? String, a)
        let parent = try XCTUnwrap(out["parent"] as? [String: Any])
        XCTAssertEqual(parent["subtaskIds"] as? [String], ["NEW00000-0000-0000-0000-000000000001"])
    }

    func testAddSubtaskUnderSubtaskIsRefused() {
        fake.items[b]?.parentId = a
        XCTAssertThrowsError(try coordinator().addSubtask(parentID: b, title: "x"))
        XCTAssertEqual(fake.calls, [])
    }

    func testAddSubtaskNeedsTitle() {
        XCTAssertThrowsError(try coordinator().addSubtask(parentID: a, title: "   "))
        XCTAssertEqual(fake.calls, [])
    }

    func testMoveUnderParent() throws {
        let out = try coordinator().moveSubtask(id: b, parentID: a)
        XCTAssertEqual(fake.calls, ["move"])
        XCTAssertEqual((out["reminder"] as? [String: Any])?["parentId"] as? String, a)
    }

    func testMoveToTopLevel() throws {
        fake.items[b]?.parentId = a
        _ = try coordinator().moveSubtask(id: b, parentID: nil)
        XCTAssertNil(fake.items[b]?.parentId)
    }

    func testMoveRefusals() {
        let co = coordinator()
        XCTAssertThrowsError(try co.moveSubtask(id: a, parentID: a), "own parent")
        XCTAssertThrowsError(try co.moveSubtask(id: a, parentID: c), "across lists")
        fake.items[b]?.parentId = a
        XCTAssertThrowsError(try co.moveSubtask(id: c, parentID: b), "parent is a subtask")
        XCTAssertThrowsError(try co.moveSubtask(id: a, parentID: b), "reminder with subtasks")
        XCTAssertEqual(fake.calls, [])
    }

    func testMoveNoOps() throws {
        XCTAssertEqual(try coordinator().moveSubtask(id: a, parentID: nil)["changed"] as? Bool, false)
        fake.items[b]?.parentId = a
        XCTAssertEqual(try coordinator().moveSubtask(id: b, parentID: a)["changed"] as? Bool, false)
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: sections

    func testSetSectionByNameCaseInsensitively() throws {
        let out = try coordinator().setSection(id: a, section: "work")
        XCTAssertEqual(fake.calls, ["assign"])
        XCTAssertEqual(((out["reminder"] as? [String: Any])?["section"] as? [String: Any])?["name"] as? String, "Work")
    }

    func testSetSectionByID() throws {
        _ = try coordinator().setSection(id: a, section: errands.id.lowercased())
        XCTAssertEqual(fake.items[a]?.section, errands)
    }

    func testUnknownSectionListsChoices() {
        XCTAssertThrowsError(try coordinator().setSection(id: a, section: "Nope")) { error in
            XCTAssertTrue(error.localizedDescription.contains("'Work'"))
        }
        XCTAssertEqual(fake.calls, [])
    }

    func testAmbiguousSectionNameNeedsID() {
        fake.sectionsByList[list]?.append(ReminderSectionRef(id: "5EC00000-0000-0000-0000-000000000003", name: "WORK", listId: list))
        XCTAssertThrowsError(try coordinator().setSection(id: a, section: "Work")) { error in
            XCTAssertTrue(error.localizedDescription.contains("More than one section"))
        }
    }

    func testSectionWriteThatMovesOtherRemindersFailsVerification() {
        fake.sideEffect = { fake, _ in fake.items[self.b]?.section = self.errands }
        XCTAssertThrowsError(try coordinator().setSection(id: a, section: "Work")) { error in
            XCTAssertTrue(error.localizedDescription.contains("other reminders' sections"), error.localizedDescription)
        }
        XCTAssertEqual(fake.calls, ["assign"])
    }

    // MARK: tags

    func testSetTagsAddsAndRemoves() throws {
        let out = try coordinator().setTags(id: a, add: ["#Work", "errand"], remove: ["HOME"])
        XCTAssertEqual(fake.calls, ["replaceTags"])
        XCTAssertEqual(fake.items[a]?.tags, ["Work", "errand"])
        XCTAssertEqual(out["changed"] as? Bool, true)
    }

    func testSetTagsNoOp() throws {
        XCTAssertEqual(try coordinator().setTags(id: a, add: ["HOME"], remove: [])["changed"] as? Bool, false)
        XCTAssertEqual(fake.calls, [])
    }

    func testInvalidTagsAreRejectedBeforeWriting() {
        XCTAssertThrowsError(try coordinator().setTags(id: a, add: ["two words"], remove: []))
        XCTAssertThrowsError(try coordinator().setTags(id: a, add: ["#"], remove: []))
        XCTAssertThrowsError(try coordinator().setTags(id: a, add: [], remove: []))
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: review follow-ups

    func testUnreadableFieldRefusesWrite() {
        fake.items[a]?.unreadable = ["flagged"]
        XCTAssertThrowsError(try coordinator().setFlag(id: a, flagged: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not be verified"), error.localizedDescription)
        }
        XCTAssertEqual(fake.calls, [], "an unreadable false must not short-circuit as already unflagged")
    }

    func testTitleOrLinkDriftFailsVerification() {
        fake.sideEffect = { fake, id in fake.items[id]?.richLinks = ["https://example.com/x"] }
        XCTAssertThrowsError(try coordinator().setTags(id: a, add: ["work"], remove: [])) { error in
            XCTAssertTrue(error.localizedDescription.contains("richLinks"), error.localizedDescription)
        }
    }

    func testUndecidedMembershipSettlingFailsVerification() {
        let x = "DDDDDDDD-0000-0000-0000-00000000000D"
        fake.otherMemberships[list] = [x: .some(undecidedSectionMembership)]
        fake.sideEffect = { fake, _ in fake.otherMemberships[self.list] = [:] }
        XCTAssertThrowsError(try coordinator().setSection(id: a, section: "Work")) { error in
            XCTAssertTrue(error.localizedDescription.contains("other reminders' sections"), error.localizedDescription)
        }
    }

    func testAddSubtaskThatDropsAnExistingChildFails() {
        fake.items[b]?.parentId = a
        fake.sideEffect = { fake, _ in fake.items[self.b]?.parentId = nil }
        XCTAssertThrowsError(try coordinator().addSubtask(parentID: a, title: "x")) { error in
            XCTAssertTrue(error.localizedDescription.contains("parent's subtasks"), error.localizedDescription)
        }
    }

    func testMoveChecksOldParent() throws {
        let d = "DDDDDDDD-0000-0000-0000-00000000000D"
        var meta = ReminderMetadata(id: d); meta.listId = list; meta.parentId = a
        fake.items[d] = meta
        fake.items[b]?.parentId = a
        fake.sideEffect = { fake, _ in fake.items[d]?.parentId = nil }  // collateral: sibling leaves too
        XCTAssertThrowsError(try coordinator().moveSubtask(id: b, parentID: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("parent's subtasks"), error.localizedDescription)
        }
    }

    func testComputeTags() {
        XCTAssertEqual(computeTags(current: ["A", "b"], add: ["a", "c"], remove: ["B"]), ["A", "c"])
        XCTAssertEqual(try normalizeTag("  ##groceries "), "groceries")
    }
}

final class PrivateWriteSwitchTests: XCTestCase {
    func testOffByDefaultWithHowToTurnOn() {
        XCTAssertThrowsError(try requirePrivateWritesEnabled(PIMConfiguration(), command: "set-tags")) { error in
            guard case PrivateWriteError.notEnabled(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("reminder-cli config private-writes --on"))
            XCTAssertTrue(message.contains("\"privateWrites\": true"))
        }
    }

    func testOnWhenConfigured() throws {
        var config = PIMConfiguration()
        config.reminders.privateWrites = true
        XCTAssertNoThrow(try requirePrivateWritesEnabled(config, command: "set-flag"))
    }

    func testSettingKeepsEveryOtherKey() {
        let original: [String: Any] = [
            "trusted_senders": ["a@example.com"],
            "reminders": ["mode": "allowlist", "items": ["Errands"]],
        ]
        let on = settingPrivateWrites(true, in: original)
        let reminders = on["reminders"] as? [String: Any]
        XCTAssertEqual(reminders?["privateWrites"] as? Bool, true)
        XCTAssertEqual(reminders?["items"] as? [String], ["Errands"])
        XCTAssertEqual(on["trusted_senders"] as? [String], ["a@example.com"])

        let off = settingPrivateWrites(false, in: on)
        XCTAssertNil((off["reminders"] as? [String: Any])?["privateWrites"], "off removes the key")
        XCTAssertEqual((off["reminders"] as? [String: Any])?["mode"] as? String, "allowlist")
    }

    func testSettingCreatesRemindersSection() {
        XCTAssertEqual((settingPrivateWrites(true, in: [:])["reminders"] as? [String: Any])?["privateWrites"] as? Bool, true)
    }
}
