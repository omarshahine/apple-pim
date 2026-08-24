import XCTest
@testable import MailCLI

final class EnvelopeQueriesTests: XCTestCase {

    // MARK: - emlxSubpath

    func testEmlxSubpathSmallRowID() {
        XCTAssertEqual(emlxSubpath(forRowID: 42), [])
        XCTAssertEqual(emlxSubpath(forRowID: 999), [])
    }

    func testEmlxSubpathSingleDigit() {
        // 8632 / 1000 = 8 -> Data/8/Messages/8632.emlx
        XCTAssertEqual(emlxSubpath(forRowID: 8632), ["8"])
    }

    func testEmlxSubpathMultiDigitReversed() {
        // 106847 / 1000 = 106 -> digits least-significant first: Data/6/0/1
        XCTAssertEqual(emlxSubpath(forRowID: 106847), ["6", "0", "1"])
        // 109430 / 1000 = 109 -> 9, 0, 1
        XCTAssertEqual(emlxSubpath(forRowID: 109430), ["9", "0", "1"])
    }

    // MARK: - parseMailboxRef

    func testParseMailboxRefSimple() {
        let ref = parseMailboxRef(
            rowid: 14, url: "imap://ABC-123/INBOX", totalCount: 20, unreadCount: 5)
        XCTAssertEqual(ref?.accountUUID, "ABC-123")
        XCTAssertEqual(ref?.name, "INBOX")
        XCTAssertEqual(ref?.pathComponents, ["INBOX"])
        XCTAssertEqual(ref?.scheme, "imap")
        XCTAssertEqual(ref?.totalCount, 20)
        XCTAssertEqual(ref?.unreadCount, 5)
    }

    func testParseMailboxRefNestedWithEmoji() {
        // "Agent/🧾 Invoices" percent-encoded, as observed in the live index.
        let ref = parseMailboxRef(
            rowid: 59, url: "imap://ABC-123/Agent/%F0%9F%A7%BE%20Invoices",
            totalCount: 3, unreadCount: 0)
        XCTAssertEqual(ref?.pathComponents, ["Agent", "🧾 Invoices"])
        XCTAssertEqual(ref?.name, "🧾 Invoices")
    }

    func testParseMailboxRefRejectsMalformed() {
        XCTAssertNil(parseMailboxRef(rowid: 1, url: "no-scheme-here", totalCount: 0, unreadCount: 0))
        XCTAssertNil(parseMailboxRef(rowid: 1, url: "imap://ACCOUNT-ONLY", totalCount: 0, unreadCount: 0))
    }

    // MARK: - Formatting

    func testFormatAddress() {
        XCTAssertEqual(formatAddress(address: "a@b.com", comment: "Ann Smith"), "Ann Smith <a@b.com>")
        XCTAssertEqual(formatAddress(address: "a@b.com", comment: ""), "a@b.com")
        XCTAssertEqual(formatAddress(address: "a@b.com", comment: "  "), "a@b.com")
    }

    func testIsoStringFromEpochMatchesJXAToISOString() {
        // JXA's Date.toISOString() emits milliseconds; the SQLite path must match.
        XCTAssertEqual(isoStringFromEpoch(1753036640), "2025-07-20T18:37:20.000Z")
    }

    func testEpochFromISO8601DateOnly() {
        let epoch = epochFromISO8601("2026-01-15")
        XCTAssertNotNil(epoch)
        // Date-only strings resolve in the local time zone (same as the JXA path).
        let backOut = Calendar.current.dateComponents(
            in: TimeZone.current, from: Date(timeIntervalSince1970: epoch!))
        XCTAssertEqual(backOut.year, 2026)
        XCTAssertEqual(backOut.month, 1)
        XCTAssertEqual(backOut.day, 15)
        XCTAssertNil(epochFromISO8601("not a date"))
    }

    func testFullSubject() {
        XCTAssertEqual(fullSubject(prefix: "Re: ", subject: "Hello"), "Re: Hello")
        XCTAssertEqual(fullSubject(prefix: nil, subject: "Hello"), "Hello")
        XCTAssertEqual(fullSubject(prefix: nil, subject: nil), "")
    }

    func testIsJunkMailboxName() {
        XCTAssertTrue(isJunkMailboxName("Junk"))
        XCTAssertTrue(isJunkMailboxName("Spam"))
        XCTAssertFalse(isJunkMailboxName("INBOX"))
        XCTAssertFalse(isJunkMailboxName("Train Spam"))
    }

    func testEpochValueCoalescesIntegerAndReal() {
        XCTAssertEqual(epochValue(Int64(1753036640)), 1753036640.0)
        XCTAssertEqual(epochValue(1753036640.5), 1753036640.5)
        XCTAssertNil(epochValue(nil))
        XCTAssertNil(epochValue("not a number"))
    }

    // MARK: - LIKE escaping

    func testEscapeLikePattern() {
        XCTAssertEqual(escapeLikePattern("100% off_now"), "100\\% off\\_now")
        XCTAssertEqual(escapeLikePattern("back\\slash"), "back\\\\slash")
        XCTAssertEqual(escapeLikePattern("plain"), "plain")
    }

    // MARK: - Mailbox scope clause

    func testMailboxScopeClauseWithoutLabels() throws {
        let scope = try XCTUnwrap(mailboxScopeClause(rowIDs: [297], includeLabels: false))
        XCTAssertEqual(scope.sql, "m.mailbox IN (?)")
        XCTAssertEqual(scope.rowIDBinds, [297])
        XCTAssertEqual(scope.logicalMailboxSQL, "m.mailbox")
        XCTAssertEqual(scope.logicalMailboxRowIDBinds, [])
    }

    func testMailboxScopeClauseWithLabelsAddsGmailArm() throws {
        // Gmail keeps the single physical copy under [Gmail]/All Mail and records
        // INBOX membership in `labels`, so the direct arm alone matches nothing.
        let scope = try XCTUnwrap(mailboxScopeClause(rowIDs: [297], includeLabels: true))
        XCTAssertEqual(
            scope.sql,
            "m.ROWID IN (SELECT scoped.ROWID FROM messages scoped "
                + "WHERE scoped.mailbox IN (?) UNION ALL "
                + "SELECT l.message_id FROM labels l WHERE l.mailbox_id IN (?))")
        XCTAssertEqual(scope.rowIDBinds, [297, 297])
        XCTAssertEqual(
            scope.logicalMailboxSQL,
            "CASE WHEN m.mailbox IN (?) THEN m.mailbox "
                + "ELSE (SELECT l.mailbox_id FROM labels l "
                + "WHERE l.message_id = m.ROWID AND l.mailbox_id IN (?) "
                + "ORDER BY l.mailbox_id LIMIT 1) END")
        XCTAssertEqual(scope.logicalMailboxRowIDBinds, [297, 297])
    }

    func testMailboxScopeClauseMultipleRowIDs() throws {
        let scope = try XCTUnwrap(mailboxScopeClause(rowIDs: [1, 2, 3], includeLabels: true))
        XCTAssertTrue(scope.sql.contains("scoped.mailbox IN (?,?,?)"))
        XCTAssertTrue(scope.sql.contains("l.mailbox_id IN (?,?,?)"))
        XCTAssertEqual(scope.rowIDBinds, [1, 2, 3, 1, 2, 3])
        XCTAssertEqual(scope.logicalMailboxRowIDBinds, [1, 2, 3, 1, 2, 3])
    }

    func testMailboxScopeClauseBindCountInvariant() {
        // Binds are positional: the mailbox condition is appended first, so a drift
        // between placeholder count and bind count shifts every later bind.
        for rowIDs in [[297], [10, 11], [1, 2, 3]] as [[Int64]] {
            XCTAssertEqual(
                mailboxScopeClause(rowIDs: rowIDs, includeLabels: false)?.rowIDBinds.count,
                rowIDs.count)
            XCTAssertEqual(
                mailboxScopeClause(rowIDs: rowIDs, includeLabels: true)?.rowIDBinds.count,
                rowIDs.count * 2)
        }
    }

    func testMailboxScopeClauseLabelsOffIsByteIdenticalToUpstream() throws {
        // Installs with no Gmail labels must emit exactly the clause they emitted before.
        let scope = try XCTUnwrap(mailboxScopeClause(rowIDs: [4, 5], includeLabels: false))
        XCTAssertEqual(scope.sql, "m.mailbox IN (?,?)")
        XCTAssertEqual(scope.rowIDBinds, [4, 5])
    }

    func testMailboxScopeClauseEmptyRowIDsReturnsNil() {
        // An empty scope selects nothing, so there is no clause to emit and no query to
        // run. SQLite would accept the `IN ()` this used to build, but only as a
        // non-standard always-false expression, and both arms would still be dead weight.
        XCTAssertNil(mailboxScopeClause(rowIDs: [], includeLabels: false))
        XCTAssertNil(mailboxScopeClause(rowIDs: [], includeLabels: true))
    }

    // MARK: - Message ID normalization

    func testMessageIDCandidates() {
        XCTAssertEqual(messageIDCandidates("abc@example.com"), ["<abc@example.com>", "abc@example.com"])
        XCTAssertEqual(messageIDCandidates("<abc@example.com>"), ["<abc@example.com>", "abc@example.com"])
    }

    func testStripAngleBrackets() {
        XCTAssertEqual(stripAngleBrackets("<abc@x>"), "abc@x")
        XCTAssertEqual(stripAngleBrackets("abc@x"), "abc@x")
    }
    // MARK: - Address parsing

    func testParseAddressPrefersTheBracketedAddressOverAnAtInTheDisplayName() {
        // The reported phishing shape: a forged display name that is itself an address.
        // Splitting on the first token reports "service@paypal.com" and treats the message
        // as PayPal's; RFC 5322 parsers give up and report nothing at all.
        let parsed = parseAddress("service@paypal.com <store+abc@g.shopifyemail.com>")
        XCTAssertEqual(parsed.address, "store+abc@g.shopifyemail.com")
        XCTAssertEqual(parsed.name, "service@paypal.com")
    }

    func testParseAddressHandlesQuotesBracketsAndBareAddresses() {
        XCTAssertEqual(parseAddress("\"Doe, John\" <john@example.com>").name, "Doe, John")
        XCTAssertEqual(parseAddress("\"Doe, John\" <john@example.com>").address, "john@example.com")
        // A display name containing its own angle brackets must not displace the address.
        XCTAssertEqual(parseAddress("<weird> name <real@example.com>").address, "real@example.com")
        XCTAssertEqual(parseAddress("<weird> name <real@example.com>").name, "<weird> name")

        XCTAssertEqual(parseAddress("bare@example.com").address, "bare@example.com")
        XCTAssertEqual(parseAddress("bare@example.com").name, "")
        XCTAssertEqual(parseAddress("  spaced@example.com  ").address, "spaced@example.com")

        // Neither brackets nor an "@": a display name with no address, not an address.
        XCTAssertEqual(parseAddress("Mailer Daemon").name, "Mailer Daemon")
        XCTAssertEqual(parseAddress("Mailer Daemon").address, "")
        XCTAssertEqual(parseAddress("").address, "")
    }

    func testParseAddressRoundTripsWhatFormatAddressProduced() {
        for (name, address) in [
            ("Example Sender", "sender@example.com"),
            ("", "bare@example.com"),
            ("service@paypal.com", "store@g.shopifyemail.com"),
        ] {
            let parsed = parseAddress(formatAddress(address: address, comment: name))
            XCTAssertEqual(parsed.address, address)
            XCTAssertEqual(parsed.name, name)
        }
    }

    func testWithParsedAddressesAddsBothPairsAndLeavesOtherFieldsAlone() {
        let enriched = withParsedAddresses([
            "sender": "Example Sender <sender@example.com>",
            "replyTo": "noreply@example.com",
            "subject": "Hello",
        ])
        XCTAssertEqual(enriched["senderAddress"] as? String, "sender@example.com")
        XCTAssertEqual(enriched["senderName"] as? String, "Example Sender")
        XCTAssertEqual(enriched["replyToAddress"] as? String, "noreply@example.com")
        XCTAssertEqual(enriched["replyToName"] as? String, "")
        XCTAssertEqual(enriched["subject"] as? String, "Hello")
        // The flattened strings stay put: existing consumers are not broken.
        XCTAssertEqual(enriched["sender"] as? String, "Example Sender <sender@example.com>")

        // A message with no replyTo gets no reply-to keys invented for it.
        let senderOnly = withParsedAddresses(["sender": "a@example.com"])
        XCTAssertNil(senderOnly["replyToAddress"])
    }

}
