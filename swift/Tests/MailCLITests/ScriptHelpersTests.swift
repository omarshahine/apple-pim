import XCTest
@testable import MailCLI

final class ScriptHelpersTests: XCTestCase {
    func testEscapeForJXAEscapesQuotesBackslashesAndControlChars() {
        let raw = "a\\b'c\"d\ne\rf\tg"
        let escaped = escapeForJXA(raw)
        XCTAssertEqual(escaped, "a\\\\b\\'c\\\"d\\ne\\rf\\tg")
    }

    func testFindMessageJXAUsesNullHintsWhenNotProvided() {
        let script = findMessageJXA(targetId: "<id>", mailbox: nil, account: nil)
        XCTAssertTrue(script.contains("const mboxHint = null;"))
        XCTAssertTrue(script.contains("const acctHint = null;"))
    }

    func testFindMessageJXAInjectsEscapedHints() {
        let script = findMessageJXA(
            targetId: "<id'\"\\\\>",
            mailbox: "Inbox 'Primary'",
            account: "Personal \"Account\""
        )
        XCTAssertTrue(script.contains("const targetId = '<id\\'\\\"\\\\\\\\>';"))
        XCTAssertTrue(script.contains("const mboxHint = 'Inbox \\'Primary\\'';"))
        XCTAssertTrue(script.contains("const acctHint = 'Personal \\\"Account\\\"';"))
    }

    func testBatchFindMessageJXAUsesNullHintsWhenNotProvided() {
        let script = batchFindMessageJXA(mailbox: nil, account: nil)
        XCTAssertTrue(script.contains("const mboxHint = null;"))
        XCTAssertTrue(script.contains("const acctHint = null;"))
        XCTAssertTrue(script.contains("function findMsg(targetId)"))
    }

    // MARK: - Reply script (issue #67)

    func testReplyScriptDoesNotUseBrittleByNameMailboxSpecifier() {
        // The -1728 bug came from addressing `mailbox "<name>" of account "<acct>"`,
        // which fails for nested Gmail mailboxes. The fix must NOT emit that form.
        let script = buildReplyAppleScript(
            bodyPath: "/tmp/body.txt",
            accountName: "Google",
            appleMailId: 12345,
            attachmentLines: ""
        )
        XCTAssertFalse(script.contains("of mailbox"),
                       "reply must not address the message via a by-name mailbox specifier")
        XCTAssertFalse(script.contains("message of mailbox"))
    }

    func testReplyScriptSearchesAccountMailboxTreeRecursively() {
        let script = buildReplyAppleScript(
            bodyPath: "/tmp/body.txt",
            accountName: "Google",
            appleMailId: 12345,
            attachmentLines: ""
        )
        // Recursive resolver present, account addressed by name, id used numerically.
        XCTAssertTrue(script.contains("on findMsgById(theId, mboxList)"))
        XCTAssertTrue(script.contains("my findMsgById(12345, (mailboxes of theAccount))"))
        XCTAssertTrue(script.contains("first account whose name is \"Google\""))
        XCTAssertTrue(script.contains("messages of mb whose id is theId"))
        XCTAssertTrue(script.contains("mailboxes of mb"))
        XCTAssertTrue(script.contains("reply origMsg with opening window"))
        XCTAssertTrue(script.contains("send replyMsg"))
    }

    func testReplyScriptEscapesAccountAndOmitsAttachmentBlockWhenEmpty() {
        let script = buildReplyAppleScript(
            bodyPath: "/tmp/body.txt",
            accountName: "Weird \"Acct\"",
            appleMailId: 7,
            attachmentLines: ""
        )
        XCTAssertTrue(script.contains("first account whose name is \"Weird \\\"Acct\\\"\""))
        XCTAssertFalse(script.contains("tell replyMsg"))
    }

    func testReplyScriptIncludesAttachmentBlockWhenProvided() {
        let attachmentLines = "\n        make new attachment with properties {file name:\"/tmp/a.pdf\"} at after the last paragraph"
        let script = buildReplyAppleScript(
            bodyPath: "/tmp/body.txt",
            accountName: "Google",
            appleMailId: 7,
            attachmentLines: attachmentLines
        )
        XCTAssertTrue(script.contains("tell replyMsg"))
        XCTAssertTrue(script.contains("make new attachment with properties {file name:\"/tmp/a.pdf\"}"))
    }
}
