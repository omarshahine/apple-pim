import Foundation
import SQLite3
import XCTest
@testable import ReminderCLI

/// Builds a throwaway Reminders-shaped Core Data store in a temp directory. Nothing here
/// touches the real Reminders database.
final class FixtureStore {
    let dir: URL
    let path: URL
    private var db: OpaquePointer?

    init(name: String = "Data-TEST.sqlite", withHashtagLabels: Bool = true, extraReminderColumns: Bool = true) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reminder-store-\(UUID().uuidString)/Stores")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent(name)
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { throw ReminderStoreError.unavailable("fixture open") }
        let reminderExtra = extraReminderColumns
            ? ", ZFLAGGED INTEGER, ZISURGENTSTATEENABLEDFORCURRENTUSER INTEGER" : ""
        exec("""
            CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
            INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME) VALUES (3,'REMCDList'),(6,'REMCDListSection'),
              (23,'REMCDFileAttachment'),(25,'REMCDImageAttachment'),(26,'REMCDURLAttachment'),(32,'REMCDHashtag'),(39,'REMCDReminder');
            CREATE TABLE ZREMCDBASELIST (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZMARKEDFORDELETION INTEGER DEFAULT 0,
              ZCKIDENTIFIER VARCHAR, ZNAME VARCHAR, ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA BLOB);
            CREATE TABLE ZREMCDBASESECTION (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZMARKEDFORDELETION INTEGER DEFAULT 0,
              ZLIST INTEGER, ZCKIDENTIFIER VARCHAR, ZDISPLAYNAME VARCHAR, ZCREATIONDATE TIMESTAMP);
            CREATE TABLE ZREMCDREMINDER (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZMARKEDFORDELETION INTEGER DEFAULT 0,
              ZCKIDENTIFIER VARCHAR, ZTITLE VARCHAR, ZLIST INTEGER, ZPARENTREMINDER INTEGER\(reminderExtra));
            CREATE TABLE ZREMCDOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZMARKEDFORDELETION INTEGER DEFAULT 0,
              ZREMINDER INTEGER, ZREMINDER2 INTEGER, ZREMINDER3 INTEGER, ZHASHTAGLABEL INTEGER, ZNAME VARCHAR,
              ZURL VARCHAR, ZFILENAME VARCHAR, ZUTI VARCHAR, ZFILESIZE INTEGER, ZWIDTH INTEGER, ZHEIGHT INTEGER, ZSHA512SUM VARCHAR);
            """)
        if withHashtagLabels {
            exec("CREATE TABLE ZREMCDHASHTAGLABEL (Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR);")
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            XCTFail("fixture SQL failed: \(message)\n\(sql)")
        }
    }

    func setMemberships(listPK: Int, json: String) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE ZREMCDBASELIST SET ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA = ? WHERE Z_PK = ?", -1, &stmt, nil)
        let data = Array(json.utf8)
        sqlite3_bind_blob(stmt, 1, data, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, Int64(listPK))
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
    }

    func open() throws -> ReminderMetadataStore {
        try ReminderMetadataStore.open(storesDirectory: dir)
    }
}

let listA = "11111111-1111-1111-1111-111111111111"
let listB = "22222222-2222-2222-2222-222222222222"
let parentID = "AAAAAAAA-0000-0000-0000-000000000001"
let childID = "AAAAAAAA-0000-0000-0000-000000000002"
let plainID = "AAAAAAAA-0000-0000-0000-000000000003"
let deletedID = "AAAAAAAA-0000-0000-0000-000000000004"
let sectionWork = "5EC00000-0000-0000-0000-000000000001"
let sectionHome = "5EC00000-0000-0000-0000-000000000002"

func populatedFixture() throws -> FixtureStore {
    let f = try FixtureStore()
    f.exec("""
        INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZCKIDENTIFIER, ZNAME) VALUES (1, 3, '\(listA)', 'Projects'), (2, 3, '\(listB)', 'Home');
        INSERT INTO ZREMCDBASESECTION (Z_PK, Z_ENT, ZLIST, ZCKIDENTIFIER, ZDISPLAYNAME, ZCREATIONDATE)
          VALUES (1, 6, 1, '\(sectionWork)', 'Work', 1), (2, 6, 1, '\(sectionHome)', 'Errands', 2);
        INSERT INTO ZREMCDREMINDER (Z_PK, Z_ENT, ZCKIDENTIFIER, ZTITLE, ZLIST, ZPARENTREMINDER, ZFLAGGED, ZISURGENTSTATEENABLEDFORCURRENTUSER) VALUES
          (1, 39, '\(parentID)', 'Parent', 1, NULL, 1, 0),
          (2, 39, '\(childID)', 'Child', 1, 1, 0, 1),
          (3, 39, '\(plainID)', 'Plain', 2, NULL, 0, 0);
        INSERT INTO ZREMCDREMINDER (Z_PK, Z_ENT, ZMARKEDFORDELETION, ZCKIDENTIFIER, ZTITLE, ZLIST, ZPARENTREMINDER) VALUES
          (4, 39, 1, '\(deletedID)', 'Deleted child', 1, 1);
        INSERT INTO ZREMCDHASHTAGLABEL (Z_PK, ZNAME) VALUES (1, 'work'), (2, 'urgent-ish');
        INSERT INTO ZREMCDOBJECT (Z_PK, Z_ENT, ZREMINDER3, ZHASHTAGLABEL) VALUES (10, 32, 1, 1), (11, 32, 1, 2), (12, 32, 1, 1);
        INSERT INTO ZREMCDOBJECT (Z_PK, Z_ENT, ZMARKEDFORDELETION, ZREMINDER3, ZHASHTAGLABEL) VALUES (13, 32, 1, 3, 1);
        INSERT INTO ZREMCDOBJECT (Z_PK, Z_ENT, ZREMINDER2, ZURL) VALUES (20, 26, 1, 'https://example.com/a');
        INSERT INTO ZREMCDOBJECT (Z_PK, Z_ENT, ZREMINDER2, ZFILENAME, ZUTI, ZFILESIZE, ZWIDTH, ZHEIGHT, ZSHA512SUM)
          VALUES (30, 25, 2, 'photo.png', 'public.png', 1234, 640, 480, 'abc123');
        """)
    f.setMemberships(listPK: 1, json: """
        {"memberships":[
          {"memberID":"\(parentID)","groupID":"\(sectionWork)","modifiedOn":10},
          {"memberID":"\(childID)","groupID":"\(sectionWork)","modifiedOn":10},
          {"memberID":"\(childID)","groupID":"\(sectionHome)","modifiedOn":20}
        ]}
        """)
    return f
}

final class ReminderStoreTests: XCTestCase {

    func testReadsEveryMetadataField() throws {
        let f = try populatedFixture()
        let store = try f.open()
        let meta = try store.metadata(for: [parentID, childID, plainID, deletedID])

        XCTAssertNil(meta[deletedID], "rows marked for deletion are not reported")

        let parent = try XCTUnwrap(meta[parentID])
        XCTAssertTrue(parent.flagged)
        XCTAssertFalse(parent.urgent)
        XCTAssertNil(parent.parentId)
        XCTAssertEqual(parent.subtaskIds, [childID], "deleted children are not subtasks")
        XCTAssertEqual(parent.tags, ["work", "urgent-ish"], "tags are de-duplicated, order kept")
        XCTAssertEqual(parent.richLinks, ["https://example.com/a"])
        XCTAssertEqual(parent.section?.name, "Work")
        XCTAssertEqual(parent.listId, listA)

        let child = try XCTUnwrap(meta[childID])
        XCTAssertTrue(child.urgent)
        XCTAssertEqual(child.parentId, parentID)
        XCTAssertEqual(child.section?.name, "Errands", "newest membership wins")
        XCTAssertEqual(child.attachments.count, 1)
        XCTAssertEqual(child.attachments[0].type, "image")
        XCTAssertEqual(child.attachments[0].filename, "photo.png")
        XCTAssertEqual(child.attachments[0].width, 640)
        XCTAssertNil(child.attachments[0].path, "no attachment file on disk")

        let plain = try XCTUnwrap(meta[plainID])
        XCTAssertEqual(plain.tags, [], "a deleted hashtag row is ignored")
        XCTAssertNil(plain.section)
    }

    func testLookupIsCaseInsensitiveAndKeyedByCallerSpelling() throws {
        let store = try populatedFixture().open()
        let lower = parentID.lowercased()
        let meta = try store.metadata(for: [lower])
        XCTAssertEqual(meta[lower]?.id, lower)
        XCTAssertTrue(meta[lower]?.flagged ?? false)
    }

    func testToDictShape() throws {
        let store = try populatedFixture().open()
        let dict = try XCTUnwrap(store.metadata(for: [childID])[childID]).toDict()
        XCTAssertEqual(dict["isSubtask"] as? Bool, true)
        XCTAssertEqual(dict["parentId"] as? String, parentID)
        XCTAssertEqual((dict["section"] as? [String: Any])?["id"] as? String, sectionHome)
        XCTAssertNil(dict["title"], "title stays internal; EventKit reports it")
        let plain = try XCTUnwrap(store.metadata(for: [plainID])[plainID]).toDict()
        XCTAssertTrue(plain["parentId"] is NSNull)
        XCTAssertTrue(plain["section"] is NSNull)
    }

    func testSectionsForLists() throws {
        let store = try populatedFixture().open()
        let sections = try store.sections(forLists: [listA, listB])
        XCTAssertEqual(sections[listA]?.map(\.name), ["Work", "Errands"])
        XCTAssertEqual(sections[listB]?.count, 0)
    }

    func testToleratesMissingColumnsAndTables() throws {
        // An older or newer schema without flag/urgent columns or the hashtag label table.
        let f = try FixtureStore(withHashtagLabels: false, extraReminderColumns: false)
        f.exec("""
            INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZCKIDENTIFIER) VALUES (1, 3, '\(listA)');
            INSERT INTO ZREMCDREMINDER (Z_PK, Z_ENT, ZCKIDENTIFIER, ZLIST) VALUES (1, 39, '\(parentID)', 1);
            INSERT INTO ZREMCDOBJECT (Z_PK, Z_ENT, ZREMINDER3, ZNAME) VALUES (10, 32, 1, 'inline');
            """)
        let meta = try XCTUnwrap(f.open().metadata(for: [parentID])[parentID])
        XCTAssertFalse(meta.flagged)
        XCTAssertEqual(meta.tags, ["inline"], "falls back to the object's own name")
    }

    func testRelationshipColumnIsProbedNotHardcoded() throws {
        // Same data, but this "model version" links URL attachments through ZREMINDER.
        let f = try FixtureStore()
        f.exec("""
            INSERT INTO ZREMCDBASELIST (Z_PK, Z_ENT, ZCKIDENTIFIER) VALUES (1, 3, '\(listA)');
            INSERT INTO ZREMCDREMINDER (Z_PK, Z_ENT, ZCKIDENTIFIER, ZLIST) VALUES (1, 39, '\(parentID)', 1);
            INSERT INTO ZREMCDOBJECT (Z_PK, Z_ENT, ZREMINDER, ZURL) VALUES (20, 26, 1, 'https://example.com/b');
            """)
        XCTAssertEqual(try f.open().metadata(for: [parentID])[parentID]?.richLinks, ["https://example.com/b"])
    }

    func testOpenFailsWithFullDiskAccessHintWhenDirectoryUnreadable() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        XCTAssertThrowsError(try ReminderMetadataStore.open(storesDirectory: missing)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Full Disk Access"))
        }
    }

    func testOpenSkipsEmptyStores() throws {
        let f = try FixtureStore()  // no lists at all
        XCTAssertThrowsError(try f.open())
    }

    func testStoreIsOpenedReadOnly() throws {
        let f = try populatedFixture()
        let db = try ReminderStoreDatabase(path: f.path)
        XCTAssertThrowsError(try db.query("DELETE FROM ZREMCDREMINDER"))
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS n FROM ZREMCDREMINDER").first?["n"] as? Int64, 4)
    }

    // MARK: enrich

    func testEnrichAutoReportsUnavailableWithoutFailing() throws {
        let failure: Result<ReminderMetadataStore, Error> = .failure(ReminderStoreError.unavailable("no FDA"))
        let (out, status) = try enrichReminders([["id": parentID, "title": "x"]], mode: .auto, store: failure)
        XCTAssertEqual(status?["available"] as? Bool, false)
        XCTAssertEqual(status?["reason"] as? String, "no FDA")
        XCTAssertNil(out[0]["flagged"])
        XCTAssertEqual(out[0]["title"] as? String, "x")
    }

    func testEnrichRequiredThrows() {
        let failure: Result<ReminderMetadataStore, Error> = .failure(ReminderStoreError.unavailable("no FDA"))
        XCTAssertThrowsError(try enrichReminders([["id": parentID]], mode: .required, store: failure))
    }

    func testEnrichOffSkipsStatus() throws {
        let (out, status) = try enrichReminders([["id": parentID]], mode: .off,
                                                store: .failure(ReminderStoreError.unavailable("x")))
        XCTAssertNil(status)
        XCTAssertEqual(out.count, 1)
    }

    func testEnrichMergesWithoutOverwritingEventKitFields() throws {
        let store = try populatedFixture().open()
        let (out, status) = try enrichReminders([["id": parentID, "title": "EventKit title"], ["id": "unknown"]],
                                                mode: .auto, store: .success(store))
        XCTAssertEqual(status?["available"] as? Bool, true)
        XCTAssertEqual(out[0]["title"] as? String, "EventKit title")
        XCTAssertEqual(out[0]["flagged"] as? Bool, true)
        XCTAssertNil(out[1]["flagged"], "unknown reminders are left as EventKit reported them")
    }

    func testEnrichListsAddsSections() throws {
        let store = try populatedFixture().open()
        let (out, _) = try enrichLists([["id": listA], ["id": listB]], mode: .auto, store: .success(store))
        XCTAssertEqual((out[0]["sections"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["Work", "Errands"])
        XCTAssertEqual((out[1]["sections"] as? [[String: Any]])?.count, 0)
    }
}

final class SectionMembershipTests: XCTestCase {
    private func map(_ json: String, strict: Bool = false) -> [String: String?] {
        effectiveSectionMemberships(json.data(using: .utf8), strict: strict)
    }

    func testNewestEntryWins() {
        let m = map(#"{"memberships":[{"memberID":"a","groupID":"S1","modifiedOn":1},{"memberID":"A","groupID":"S2","modifiedOn":2}]}"#)
        XCTAssertEqual(m["A"], .some("S2"))
    }

    func testNewestObsoleteMeansNoSection() {
        let m = map(#"{"memberships":[{"memberID":"a","groupID":"S1","modifiedOn":1},{"memberID":"a","groupID":"S1","isObsolete":true,"modifiedOn":2}]}"#)
        XCTAssertEqual(m["A"], .some(nil))
    }

    func testUndatedDisagreementIsNilWhenStrict() {
        let json = #"{"memberships":[{"memberID":"a","groupID":"S1"},{"memberID":"a","groupID":"S2"}]}"#
        XCTAssertEqual(map(json)["A"], .some("S2"), "display keeps the last live entry")
        XCTAssertEqual(map(json, strict: true)["A"], .some(nil), "verification refuses to guess")
    }

    func testMissingGroupIsNoSection() {
        XCTAssertEqual(map(#"{"memberships":[{"memberID":"a","modifiedOn":1}]}"#)["A"], .some(nil))
    }

    func testGarbageIsEmpty() {
        XCTAssertTrue(map("not json").isEmpty)
        XCTAssertTrue(effectiveSectionMemberships(nil).isEmpty)
    }
}

final class ReminderAuthStatusTests: XCTestCase {
    func testReportsStoreReadability() throws {
        let f = try populatedFixture()
        let readable = reminderAuthStatusPayload(authorization: "authorized", storesDirectory: f.dir)
        XCTAssertEqual(readable["authorization"] as? String, "authorized")
        XCTAssertEqual((readable["remindersStore"] as? [String: Any])?["readable"] as? Bool, true)
        let missing = reminderAuthStatusPayload(authorization: "authorized",
                                                storesDirectory: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertEqual((missing["remindersStore"] as? [String: Any])?["readable"] as? Bool, false)
    }
}
