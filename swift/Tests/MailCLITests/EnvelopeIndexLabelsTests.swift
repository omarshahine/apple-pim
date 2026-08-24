import Foundation
import SQLite3
import XCTest
@testable import MailCLI

/// End-to-end cover for the Gmail labels arm in `EnvelopeIndex.messages`, run against a
/// throwaway Envelope Index built from Mail's own table definitions. The clause-shape
/// tests in `EnvelopeQueriesTests` only pin the SQL text; these pin what it returns.
final class EnvelopeIndexLabelsTests: XCTestCase {

    // Fixture mailbox ROWIDs.
    private let allMailRowID: Int64 = 1    // the physical Gmail store
    private let inboxRowID: Int64 = 2      // the Gmail INBOX label
    private let otherInboxRowID: Int64 = 3 // a non-Gmail mailbox, direct storage

    private lazy var tempDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailcli-envelope-\(UUID().uuidString)")

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Behavior

    func testLabelsArmFindsGmailInboxMessagesStoredUnderAllMail() throws {
        let index = try openFixture(includeLabels: true)
        let rows = try index.messages(
            filter: EnvelopeIndex.MessageFilter(mailboxRowIDs: [inboxRowID]), limit: 50)

        // 101-104 sit in All Mail and reach INBOX only through `labels`; 106 is stored in
        // INBOX directly; 105 is in All Mail with no label and must stay out.
        XCTAssertEqual(rowIDs(rows), [101, 102, 103, 104, 106])
        // 106 matches both indexable branches. The outer IN membership still returns it once.
        XCTAssertEqual(rows.count, 5)
        // Label-backed rows must report the mailbox the caller scoped to, not the
        // physical [Gmail]/All Mail store that owns the message row.
        XCTAssertEqual(Set(rows.compactMap { $0["logical_mailbox_rowid"] as? Int64 }), [inboxRowID])
    }

    func testWithoutTheLabelsArmTheGmailInboxLooksEmpty() throws {
        // The regression the arm exists to prevent: scoping by mailbox alone hides every
        // Gmail INBOX message, and hides them by succeeding with no rows.
        let index = try openFixture(includeLabels: true)
        let scope = try XCTUnwrap(mailboxScopeClause(rowIDs: [inboxRowID], includeLabels: false))
        let rows = try index.query(
            "SELECT m.ROWID AS rowid FROM messages m WHERE m.deleted = 0 AND \(scope.sql)",
            scope.rowIDBinds.map { EnvelopeIndex.Bind.int($0) })

        XCTAssertFalse(rowIDs(rows).contains(101))
        XCTAssertEqual(rowIDs(rows), [106])
    }

    func testMissingLabelsTableStillReturnsDirectMailboxMessages() throws {
        // A non-Gmail install has no `labels` table at all. The arm must stay off: naming
        // the table would fail in sqlite3_prepare_v2, and `messages` would throw rather
        // than return, so reaching these assertions is itself the prepare check.
        let index = try openFixture(includeLabels: false)

        let inbox = try index.messages(
            filter: EnvelopeIndex.MessageFilter(mailboxRowIDs: [inboxRowID]), limit: 50)
        XCTAssertEqual(rowIDs(inbox), [106])

        let allMail = try index.messages(
            filter: EnvelopeIndex.MessageFilter(mailboxRowIDs: [allMailRowID]), limit: 50)
        XCTAssertEqual(rowIDs(allMail), [101, 102, 103, 104, 105, 108])
    }

    func testMailboxWithNoLabelRowsKeepsTheDirectClause() throws {
        // `labels` exists because some other account is Gmail, but this mailbox has no
        // memberships in it, so the arm stays off and the mailbox reads as it always did.
        let index = try openFixture(includeLabels: true)
        let rows = try index.messages(
            filter: EnvelopeIndex.MessageFilter(mailboxRowIDs: [otherInboxRowID]), limit: 50)
        XCTAssertEqual(rowIDs(rows), [107])
    }

    func testLabelsArmKeepsBindsAlignedWithUnreadSinceAndSubjectFilters() throws {
        // The arm doubles the mailbox placeholders, so every later bind shifts if the
        // clause and its bind list ever disagree. Stack the three bound filters at once.
        let index = try openFixture(includeLabels: true)
        var filter = EnvelopeIndex.MessageFilter(mailboxRowIDs: [inboxRowID])
        filter.unreadOnly = true
        filter.sinceEpoch = 1000
        filter.queryText = "needle"
        filter.queryField = "subject"

        let rows = try index.messages(filter: filter, limit: 50)

        // Only 101 clears all four: labelled INBOX, unread, after the cutoff, subject
        // matches. 102 is read, 103 predates the cutoff, 104's subject has no match,
        // 105 has no label, 106's subject has no match. A one-slot drift binds the cutoff
        // or the pattern to the wrong placeholder and this set changes.
        XCTAssertEqual(rowIDs(rows), [101])
    }

    func testLabelsArmUsesBothMailboxIndexes() throws {
        let index = try openFixture(includeLabels: true)
        let scope = try XCTUnwrap(
            mailboxScopeClause(rowIDs: [inboxRowID], includeLabels: true))
        let rows = try index.query(
            """
            EXPLAIN QUERY PLAN
            SELECT m.ROWID FROM messages m
            WHERE m.deleted = 0 AND \(scope.sql)
            ORDER BY m.date_received DESC LIMIT 25
            """,
            scope.rowIDBinds.map { EnvelopeIndex.Bind.int($0) })
        let plan = rows.compactMap { $0["detail"] as? String }.joined(separator: "\n")

        XCTAssertTrue(plan.contains("messages_mailbox_date_received_index"), plan)
        XCTAssertTrue(plan.contains("labels_mailbox_id_index"), plan)
    }

    func testSQLiteEngineUsesLogicalMailboxForLocationAndJunkStatus() throws {
        let index = try openFixture(includeLabels: true)
        let engine = SQLiteEngine(index: index, allMailboxes: try index.mailboxes())

        let search = try engine.search(
            query: "Needle", field: "subject", mailbox: "INBOX", account: nil,
            limit: 50, since: nil)
        let searchMessages = try XCTUnwrap(search["messages"] as? [[String: Any]])
        XCTAssertFalse(searchMessages.isEmpty)
        XCTAssertTrue(searchMessages.allSatisfy { $0["mailbox"] as? String == "INBOX" })
        XCTAssertTrue(searchMessages.allSatisfy { $0["account"] as? String == "GMAIL-ACCOUNT" })

        let spam = try engine.messages(
            mailbox: "Spam", account: nil, limit: 50, filter: nil)
        let spamMessages = try XCTUnwrap(spam["messages"] as? [[String: Any]])
        XCTAssertEqual(spamMessages.count, 1)
        XCTAssertEqual(spamMessages.first?["isJunk"] as? Bool, true)
    }

    func testFindMessageReportsTheLabeledMailboxWhenScopedToIt() throws {
        let index = try openFixture(includeLabels: true)

        // 101 lives physically in [Gmail]/All Mail and reaches INBOX only via `labels`.
        // `search` reports it as INBOX, so `get --mailbox INBOX` has to see INBOX here too;
        // without the projection it scored against All Mail and the hint never matched.
        let scoped = try index.findMessage(
            messageIDHeader: "<m1@example.com>", logicalMailboxRowIDs: [inboxRowID])
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped.first?["logical_mailbox_rowid"] as? Int64, inboxRowID)

        // Unscoped lookups keep the physical mailbox and add no column.
        let unscoped = try index.findMessage(messageIDHeader: "<m1@example.com>")
        XCTAssertEqual(unscoped.count, 1)
        XCTAssertNil(unscoped.first?["logical_mailbox_rowid"])
    }

    func testFindMessageScopeNarrowsTheProjectionButNotTheResults() throws {
        let index = try openFixture(includeLabels: true)

        // 105 is in All Mail with no label at all. Scoping to INBOX must still return it
        // (the scope is a projection, not a filter) with no logical mailbox claimed.
        let rows = try index.findMessage(
            messageIDHeader: "<m5@example.com>", logicalMailboxRowIDs: [inboxRowID])
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?["logical_mailbox_rowid"] as? Int64)
    }

    func testGetRefusesAnAccountHintItCannotResolve() throws {
        let index = try openFixture(includeLabels: true)
        let engine = SQLiteEngine(index: index, allMailboxes: try index.mailboxes())

        // Message-IDs are sender-generated, so one message can exist as two local copies
        // under different accounts. Dropping an unresolvable hint returned whichever copy
        // sorted first with `success: true`; refusing to guess is the only safe answer.
        XCTAssertThrowsError(
            try engine.get(id: "m1@example.com", includeSource: false, accountHint: "Nope")
        ) { error in
            guard case EnvelopeIndexError.notFound(let message) = error else {
                return XCTFail("Expected notFound, got \(error)")
            }
            XCTAssertTrue(message.contains("Account not found: Nope"), message)
        }
    }

    func testSQLiteEngineReportsTheSenderAddressSeparatelyFromTheDisplayName() throws {
        let index = try openFixture(includeLabels: true)
        let engine = SQLiteEngine(index: index, allMailboxes: try index.mailboxes())

        let result = try engine.messages(
            mailbox: "Phish", account: nil, limit: 10, filter: nil)
        let message = try XCTUnwrap((result["messages"] as? [[String: Any]])?.first)

        // The two columns come through intact. Re-deriving these from `sender` is where
        // consumers go wrong: the naive read reports the message as PayPal's.
        XCTAssertEqual(message["senderAddress"] as? String, "store+abc@g.shopifyemail.com")
        XCTAssertEqual(message["senderName"] as? String, "service@paypal.com")
        // ...and the flattened field is unchanged, so existing callers keep working.
        XCTAssertEqual(
            message["sender"] as? String,
            "service@paypal.com <store+abc@g.shopifyemail.com>")
    }

    func testLabeledRowKeepsItsPhysicalMailboxForOnDiskLookup() throws {
        let index = try openFixture(includeLabels: true)
        let engine = SQLiteEngine(index: index, allMailboxes: try index.mailboxes())

        let row = try XCTUnwrap(try index.findMessage(
            messageIDHeader: "<m1@example.com>", logicalMailboxRowIDs: [inboxRowID]).first)

        // Reported as INBOX, because that is the mailbox the caller scoped to...
        XCTAssertEqual(engine.mailboxRef(forRow: row)?.name, "INBOX")
        // ...but the .emlx lives under the store that owns the row. Building the on-disk path
        // from the logical mailbox searches a directory the file is not in, which turns a
        // forced SQLite read into a failure and an auto read into a needless JXA fallback.
        XCTAssertEqual(engine.physicalMailboxRef(forRow: row)?.name, "All Mail")
        XCTAssertEqual(
            engine.physicalMailboxRef(forRow: row)?.pathComponents, ["[Gmail]", "All Mail"])
    }

    // MARK: - Fixture

    private func rowIDs(_ rows: [[String: Any]]) -> Set<Int64> {
        Set(rows.compactMap { $0["rowid"] as? Int64 })
    }

    /// Build a throwaway Envelope Index and open it through the production reader.
    /// `includeLabels` controls whether the Gmail `labels` table exists at all; its
    /// absence is what a non-Gmail install looks like.
    private func openFixture(includeLabels: Bool) throws -> EnvelopeIndex {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("Envelope Index")

        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            dbPath.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openResult == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw EnvelopeIndexError.notAvailable("Fixture open failed: code \(openResult)")
        }

        var sql = Self.schema
        if includeLabels { sql += Self.labelsSchema }
        sql += Self.rows
        if includeLabels { sql += Self.labelRows }

        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        let detail = rc == SQLITE_OK ? "" : String(cString: sqlite3_errmsg(handle))
        sqlite3_close_v2(handle)
        guard rc == SQLITE_OK else {
            throw EnvelopeIndexError.queryFailed("Fixture setup failed: \(detail)")
        }

        // Keep this integration fixture hermetic. `SQLiteEngine.search` resolves account
        // names, so point it at a deliberately absent fixture path rather than the user's
        // real ~/Library/Accounts/Accounts4.sqlite.
        return try EnvelopeIndex(
            databasePath: dbPath,
            accountsDatabasePath: tempDir.appendingPathComponent("Accounts4.sqlite"))
    }

    /// Mail's own CREATE TABLE statements, copied from a live Envelope Index. Its indexes
    /// and its count-keeping triggers are left out: the triggers reference bookkeeping
    /// tables these queries never touch, and `messages` filters the dedicated `read` and
    /// `deleted` columns rather than the `flags` bitfield the triggers maintain.
    private static let schema = """
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id INTEGER NOT NULL DEFAULT 0,
        global_message_id INTEGER NOT NULL,
        remote_id INTEGER,
        document_id TEXT COLLATE BINARY,
        sender INTEGER,
        subject_prefix TEXT COLLATE BINARY,
        subject INTEGER NOT NULL,
        summary INTEGER,
        date_sent INTEGER,
        date_received INTEGER,
        mailbox INTEGER NOT NULL,
        remote_mailbox INTEGER,
        flags INTEGER NOT NULL DEFAULT 0,
        read INTEGER NOT NULL DEFAULT 0,
        flagged INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        size INTEGER NOT NULL DEFAULT 0,
        conversation_id INTEGER NOT NULL DEFAULT 0,
        date_last_viewed INTEGER,
        list_id_hash INTEGER,
        unsubscribe_type INTEGER,
        searchable_message INTEGER,
        brand_indicator INTEGER,
        display_date INTEGER,
        flag_color INTEGER,
        is_urgent INTEGER NOT NULL DEFAULT 0,
        color TEXT COLLATE BINARY,
        type INTEGER,
        fuzzy_ancestor INTEGER,
        automated_conversation INTEGER DEFAULT 0,
        root_status INTEGER DEFAULT -1);

        CREATE INDEX messages_mailbox_date_received_index
        ON messages(mailbox, date_received);

        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT COLLATE BINARY NOT NULL,
        total_count INTEGER NOT NULL DEFAULT 0,
        unread_count INTEGER NOT NULL DEFAULT 0,
        deleted_count INTEGER NOT NULL DEFAULT 0,
        unseen_count INTEGER NOT NULL DEFAULT 0,
        unread_count_adjusted_for_duplicates INTEGER NOT NULL DEFAULT 0,
        change_identifier TEXT COLLATE BINARY,
        source INTEGER,
        alleged_change_identifier TEXT COLLATE BINARY,
        UNIQUE(url) ON CONFLICT ABORT);

        CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id INTEGER,
        follow_up_start_date INTEGER,
        follow_up_end_date INTEGER,
        follow_up_jsonstringformodelevaluationforsuggestions TEXT COLLATE BINARY,
        download_state INTEGER NOT NULL DEFAULT 0,
        read_later_date INTEGER,
        send_later_date INTEGER,
        validation_state INTEGER NOT NULL DEFAULT 0,
        model_category INTEGER,
        model_subcategory INTEGER,
        category_model_version INTEGER,
        category_is_temporary INTEGER,
        model_analytics TEXT COLLATE BINARY,
        model_high_impact INTEGER NOT NULL DEFAULT 0,
        generated_summary INTEGER,
        urgent INTEGER,
        message_id_header TEXT COLLATE BINARY,
        UNIQUE(message_id) ON CONFLICT ABORT);

        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        subject TEXT COLLATE RTRIM NOT NULL,
        UNIQUE(subject) ON CONFLICT ABORT);

        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        address TEXT COLLATE NOCASE NOT NULL,
        comment TEXT COLLATE BINARY NOT NULL,
        UNIQUE(address, comment) ON CONFLICT ABORT);

        CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        message INTEGER NOT NULL REFERENCES messages(ROWID) ON DELETE CASCADE,
        attachment_id TEXT COLLATE BINARY,
        name TEXT COLLATE BINARY,
        UNIQUE(message, attachment_id) ON CONFLICT ABORT);

        """

    private static let labelsSchema = """
        CREATE TABLE labels (message_id INTEGER REFERENCES messages(ROWID) ON DELETE CASCADE,
        mailbox_id INTEGER REFERENCES mailboxes(ROWID) ON DELETE CASCADE,
        PRIMARY KEY(message_id, mailbox_id)) WITHOUT ROWID;
        CREATE INDEX labels_mailbox_id_index on labels(mailbox_id);

        """

    private static let rows = """
        INSERT INTO mailboxes (ROWID, url) VALUES
        (1, 'imap://GMAIL-ACCOUNT/%5BGmail%5D/All%20Mail'),
        (2, 'imap://GMAIL-ACCOUNT/INBOX'),
        (3, 'ews://OTHER-ACCOUNT/Inbox'),
        (4, 'imap://GMAIL-ACCOUNT/Spam'),
        (5, 'ews://OTHER-ACCOUNT/Phish');

        INSERT INTO addresses (ROWID, address, comment) VALUES
        (1, 'sender@example.com', 'Example Sender'),
        -- A forged display name that is itself an address. The Envelope Index holds the
        -- two values apart; only the joined string conflates them.
        (2, 'store+abc@g.shopifyemail.com', 'service@paypal.com');

        INSERT INTO subjects (ROWID, subject) VALUES
        (1, 'Needle in a haystack'),
        (2, 'Needle two'),
        (3, 'Needle three'),
        (4, 'Nothing here'),
        (5, 'Needle five'),
        (6, 'Direct mailbox message'),
        (7, 'Exchange direct message'),
        (8, 'Spam offer'),
        (9, 'Your account is on hold');

        INSERT INTO message_global_data (ROWID, message_id_header) VALUES
        (1, '<m1@example.com>'),
        (2, '<m2@example.com>'),
        (3, '<m3@example.com>'),
        (4, '<m4@example.com>'),
        (5, '<m5@example.com>'),
        (6, '<m6@example.com>'),
        (7, '<m7@example.com>'),
        (8, '<m8@example.com>'),
        (9, '<m9@example.com>');

        -- 101-105 are the Gmail copies: physically in All Mail, reaching INBOX only
        -- through `labels`. A real Gmail INBOX owns no messages rows at all; 106 is put
        -- there anyway so the direct arm still has something to match, and so a row
        -- matched by both arms can be checked for duplication. 107 is the non-Gmail case.
        INSERT INTO messages
        (ROWID, global_message_id, sender, subject, date_received, date_sent, mailbox, read, deleted)
        VALUES
        (101, 1, 1, 1, 2000, 2000, 1, 0, 0),
        (102, 2, 1, 2, 2000, 2000, 1, 1, 0),
        (103, 3, 1, 3,  100,  100, 1, 0, 0),
        (104, 4, 1, 4, 2000, 2000, 1, 0, 0),
        (105, 5, 1, 5, 2000, 2000, 1, 0, 0),
        (106, 6, 1, 6, 2000, 2000, 2, 0, 0),
        (107, 7, 1, 7, 2000, 2000, 3, 0, 0),
        (108, 8, 1, 8, 2000, 2000, 1, 0, 0),
        (109, 9, 2, 9, 2000, 2000, 5, 0, 0);

        """

    private static let labelRows = """
        INSERT INTO labels (message_id, mailbox_id) VALUES
        (101, 2), (102, 2), (103, 2), (104, 2), (106, 2), (108, 4);

        """
}
