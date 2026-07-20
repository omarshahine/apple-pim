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

    // MARK: - Message ID normalization

    func testMessageIDCandidates() {
        XCTAssertEqual(messageIDCandidates("abc@example.com"), ["<abc@example.com>", "abc@example.com"])
        XCTAssertEqual(messageIDCandidates("<abc@example.com>"), ["<abc@example.com>", "abc@example.com"])
    }

    func testStripAngleBrackets() {
        XCTAssertEqual(stripAngleBrackets("<abc@x>"), "abc@x")
        XCTAssertEqual(stripAngleBrackets("abc@x"), "abc@x")
    }
}
