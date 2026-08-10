import Foundation
import SQLite3
import XCTest
@testable import MailCLI

/// Regression coverage for resolving Mail mailbox UUIDs through Accounts4.sqlite.
final class EnvelopeIndexAccountTests: XCTestCase {
    private lazy var tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailcli-accounts-\(UUID().uuidString)")

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testChildAccountInheritsParentDisplayName() throws {
        let index = try openFixture()

        let names = index.accountNames()

        XCTAssertEqual(names["IMAP-CHILD"]?.name, "Personal Gmail")
        XCTAssertEqual(names["IMAP-CHILD"]?.userName, "personal@example.com")
        XCTAssertEqual(try index.accountUUIDs(matching: "Personal Gmail"), ["IMAP-CHILD"])
        XCTAssertEqual(try index.accountUUIDs(matching: "personal@example.com"), ["IMAP-CHILD"])
    }

    func testTopLevelAndChildOwnedNamesStillWin() throws {
        let index = try openFixture()

        let names = index.accountNames()

        XCTAssertEqual(names["EXCHANGE"]?.name, "Work Exchange")
        XCTAssertEqual(names["EXCHANGE"]?.userName, "person@example.com")
        XCTAssertEqual(names["NAMED-CHILD"]?.name, "Child Override")
        XCTAssertEqual(try index.accountUUIDs(matching: "child@example.com"), ["NAMED-CHILD"])
    }

    func testSharedUsernameWithinOneLogicalAccountReturnsAllMailboxUUIDs() throws {
        let index = try openFixture()

        XCTAssertEqual(
            try index.accountUUIDs(matching: "Shared A"),
            ["SHARED-CHILD-A", "SHARED-CHILD-A2"])
        XCTAssertEqual(
            try index.accountUUIDs(matching: "SHARED-CHILD-A2"),
            ["SHARED-CHILD-A2"])
    }

    func testSharedUsernameAcrossLogicalAccountsIsRejected() throws {
        let index = try openFixture()

        XCTAssertThrowsError(try index.accountUUIDs(matching: "shared@example.com")) { error in
            guard case EnvelopeIndexError.ambiguous(let message) = error else {
                return XCTFail("Expected ambiguous account error, got \(error)")
            }
            XCTAssertTrue(message.contains("multiple logical accounts"))
        }
    }

    private func openFixture() throws -> EnvelopeIndex {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let envelopePath = tempDir.appendingPathComponent("Envelope Index")
        let accountsPath = tempDir.appendingPathComponent("Accounts4.sqlite")

        try createDatabase(at: envelopePath, sql: """
            CREATE TABLE mailboxes (
                ROWID INTEGER PRIMARY KEY,
                url TEXT NOT NULL,
                total_count INTEGER NOT NULL DEFAULT 0,
                unread_count INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO mailboxes (ROWID, url) VALUES
                (1, 'imap://IMAP-CHILD/INBOX'),
                (2, 'ews://EXCHANGE/Inbox'),
                (3, 'imap://NAMED-CHILD/INBOX'),
                (4, 'imap://SHARED-CHILD-A/INBOX'),
                (5, 'imap://SHARED-CHILD-A2/Archive'),
                (6, 'imap://SHARED-CHILD-B/INBOX');
            """)

        try createDatabase(at: accountsPath, sql: """
            CREATE TABLE ZACCOUNT (
                Z_PK INTEGER PRIMARY KEY,
                ZIDENTIFIER TEXT,
                ZACCOUNTDESCRIPTION TEXT,
                ZUSERNAME TEXT,
                ZPARENTACCOUNT INTEGER
            );
            INSERT INTO ZACCOUNT
                (Z_PK, ZIDENTIFIER, ZACCOUNTDESCRIPTION, ZUSERNAME, ZPARENTACCOUNT)
            VALUES
                (1, 'IMAP-PARENT', 'Personal Gmail', 'personal@example.com', NULL),
                (2, 'IMAP-CHILD', NULL, NULL, 1),
                (3, 'EXCHANGE', 'Work Exchange', 'person@example.com', NULL),
                (4, 'NAMED-PARENT', 'Parent Name', 'parent@example.com', NULL),
                (5, 'NAMED-CHILD', 'Child Override', 'child@example.com', 4),
                (6, NULL, 'Ignored', 'ignored@example.com', NULL),
                (7, 'SHARED-PARENT-A', 'Shared A', 'shared@example.com', NULL),
                (8, 'SHARED-CHILD-A', NULL, NULL, 7),
                (9, 'SHARED-CHILD-A2', NULL, NULL, 7),
                (10, 'SHARED-PARENT-B', 'Shared B', 'shared@example.com', NULL),
                (11, 'SHARED-CHILD-B', NULL, NULL, 10);
            """)

        return try EnvelopeIndex(
            databasePath: envelopePath,
            accountsDatabasePath: accountsPath)
    }

    private func createDatabase(at path: URL, sql: String) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            path.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openResult == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw EnvelopeIndexError.notAvailable("Fixture open failed: code \(openResult)")
        }

        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        let detail = result == SQLITE_OK ? "" : String(cString: sqlite3_errmsg(handle))
        sqlite3_close_v2(handle)
        guard result == SQLITE_OK else {
            throw EnvelopeIndexError.queryFailed("Fixture setup failed: \(detail)")
        }
    }
}
