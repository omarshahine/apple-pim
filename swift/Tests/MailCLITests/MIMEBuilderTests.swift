import Foundation
import struct MailCLI.Attachment
import Testing
@testable import MailCLI

@Suite("MIMEBuilder")
struct MIMEBuilderTests {

    // Fixed Date for deterministic output.
    private static let fixedDate = Date(timeIntervalSince1970: 1713369296)  // 2024-04-17 ~16:00 UTC

    private func makeMessage(
        from: String = "lobster.claw@icloud.com",
        to: [String] = ["omar@shahine.com"],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String = "Test",
        text: String? = nil,
        html: String? = nil,
        attachments: [Attachment] = [],
        boundary: String = "=_Part_TEST0001",
        messageID: String = "<test-message-id@icloud.com>",
        autoDeriveTextFallback: Bool = true
    ) -> MIMEMessage {
        var msg = MIMEMessage(
            from: from, to: to, cc: cc, bcc: bcc,
            subject: subject, text: text, html: html, attachments: attachments,
            messageID: messageID, date: Self.fixedDate,
            autoDeriveTextFallback: autoDeriveTextFallback
        )
        msg.boundaryFactory = { boundary }
        return msg
    }

    private func renderString(_ msg: MIMEMessage) throws -> String {
        String(data: try msg.render(), encoding: .utf8) ?? ""
    }

    // MARK: - Preconditions

    @Test("No recipients rejected")
    func testNoRecipientsRejected() {
        let msg = makeMessage(to: [], text: "hi")
        #expect(throws: MIMEError.self) { _ = try msg.render() }
    }

    @Test("No body rejected")
    func testNoBodyRejected() {
        let msg = makeMessage(text: nil, html: nil)
        #expect(throws: MIMEError.self) { _ = try msg.render() }
    }

    @Test("Invalid From address rejected")
    func testInvalidFrom() {
        let msg = makeMessage(from: "no-at-sign", text: "hi")
        #expect(throws: MIMEError.self) { _ = try msg.render() }
    }

    // MARK: - Basic shape

    @Test("Text-only message produces text/plain QP")
    func testTextOnly() throws {
        let msg = makeMessage(text: "Hello world\nLine two.")
        let out = try renderString(msg)

        #expect(out.contains("From: lobster.claw@icloud.com\r\n"))
        #expect(out.contains("To: omar@shahine.com\r\n"))
        #expect(out.contains("Subject: Test\r\n"))
        #expect(out.contains("MIME-Version: 1.0\r\n"))
        #expect(out.contains("Message-ID: <test-message-id@icloud.com>\r\n"))
        #expect(out.contains("Content-Type: text/plain; charset=utf-8\r\n"))
        #expect(out.contains("Content-Transfer-Encoding: quoted-printable\r\n"))
        // Body follows CRLF CRLF. LF in input is normalized to CRLF.
        #expect(out.contains("\r\n\r\nHello world\r\nLine two."))
    }

    @Test("HTML-only message with fallback opt-out produces single-part text/html")
    func testHTMLOnlySinglePartOptOut() throws {
        let msg = makeMessage(html: "<p>hi</p>", autoDeriveTextFallback: false)
        let out = try renderString(msg)
        #expect(out.contains("Content-Type: text/html; charset=utf-8\r\n"))
        #expect(out.contains("\r\n\r\n<p>hi</p>"))
        #expect(!out.contains("multipart/alternative"))
    }

    // MARK: - HTML → text fallback (issue #61)

    @Test("HTML-only message defaults to multipart/alternative with derived text part")
    func testHTMLOnlyDerivesTextFallback() throws {
        let msg = makeMessage(html: "<p>Hello</p>", boundary: "=_Part_ALT")
        let out = try renderString(msg)
        #expect(out.contains("Content-Type: multipart/alternative; boundary=\"=_Part_ALT\"\r\n"))
        #expect(out.contains("--=_Part_ALT\r\nContent-Type: text/plain; charset=utf-8\r\n"))
        #expect(out.contains("--=_Part_ALT\r\nContent-Type: text/html; charset=utf-8\r\n"))
        #expect(out.contains("--=_Part_ALT--\r\n"))
        // The derived plain part contains the text content, the HTML part the markup.
        #expect(out.contains("Hello"))
        #expect(out.contains("<p>Hello</p>"))
    }

    @Test("Derived fallback preserves paragraph breaks and decodes entities")
    func testHTMLToTextStructureAndEntities() {
        let html = "<h1>Title &amp; Co</h1><p>First para.</p><p>Second &lt;para&gt;</p>"
        let text = MIMEMessage.htmlToPlainText(html)
        #expect(text == "Title & Co\nFirst para.\nSecond <para>")
    }

    @Test("Derived fallback converts <br> to newline and decodes numeric entities")
    func testHTMLToTextBreaksAndNumericEntities() {
        let html = "Line one<br>Line two<br/>caf&#233;&#x21;"
        let text = MIMEMessage.htmlToPlainText(html)
        #expect(text == "Line one\nLine two\ncafé!")
    }

    @Test("Derived fallback excludes <script> and <style> blocks")
    func testHTMLToTextDropsScriptAndStyle() {
        let html = """
        <style>.a { color: red; }</style><p>Visible</p><script>alert('x');</script><p>Also visible</p>
        """
        let text = MIMEMessage.htmlToPlainText(html)
        #expect(text == "Visible\nAlso visible")
        #expect(!text.contains("color"))
        #expect(!text.contains("alert"))
    }

    @Test("Derived fallback collapses whitespace and blank-line runs")
    func testHTMLToTextCollapsesWhitespace() {
        let html = "<p>too    many     spaces</p>\n\n\n\n<div>after gap</div>"
        let text = MIMEMessage.htmlToPlainText(html)
        // Horizontal runs collapse to one space; the 5-newline run collapses to a
        // single blank line (\n\n), never a single \n.
        #expect(text == "too many spaces\n\nafter gap")
    }

    @Test("text + html produces multipart/alternative with declared boundary")
    func testMultipartAlternative() throws {
        let msg = makeMessage(text: "plain", html: "<p>html</p>", boundary: "=_Part_ALT")
        let out = try renderString(msg)

        #expect(out.contains("Content-Type: multipart/alternative; boundary=\"=_Part_ALT\"\r\n"))
        #expect(out.contains("--=_Part_ALT\r\nContent-Type: text/plain; charset=utf-8\r\n"))
        #expect(out.contains("--=_Part_ALT\r\nContent-Type: text/html; charset=utf-8\r\n"))
        #expect(out.contains("--=_Part_ALT--\r\n"))
    }

    @Test("Attachment produces multipart/mixed with base64 body")
    func testSingleAttachment() throws {
        let payload = Data("hello pdf world".utf8)
        let att = Attachment(filename: "doc.pdf", contentType: "application/pdf", data: payload)

        // When attachments are present and BOTH text+html are absent, inner is one content part.
        let msg = makeMessage(text: "plain only", attachments: [att], boundary: "=_Part_MIX")
        let out = try renderString(msg)

        #expect(out.contains("Content-Type: multipart/mixed; boundary=\"=_Part_MIX\"\r\n"))
        #expect(out.contains("Content-Type: application/pdf; name=\"doc.pdf\"\r\n"))
        #expect(out.contains("Content-Disposition: attachment; filename=\"doc.pdf\"\r\n"))
        #expect(out.contains("Content-Transfer-Encoding: base64\r\n"))
        // Verify base64 body.
        let expectedB64 = payload.base64EncodedString()
        #expect(out.contains(expectedB64))
        #expect(out.contains("--=_Part_MIX--\r\n"))
    }

    // MARK: - Bcc isolation

    @Test("Bcc appears in allRecipients but NEVER in rendered headers")
    func testBccNotInHeaders() throws {
        let msg = makeMessage(
            to: ["visible@example.com"],
            cc: ["cc@example.com"],
            bcc: ["secret@example.com", "also-secret@example.com"],
            text: "hi"
        )
        #expect(msg.allRecipients() == ["visible@example.com", "cc@example.com", "secret@example.com", "also-secret@example.com"])

        let out = try renderString(msg)
        #expect(out.contains("To: visible@example.com\r\n"))
        #expect(out.contains("Cc: cc@example.com\r\n"))
        #expect(!out.contains("secret@example.com"),
                "Bcc address leaked into rendered headers — this is the most common hand-rolled-SMTP privacy bug")
        #expect(!out.lowercased().contains("bcc:"))
    }

    // MARK: - Encoding edge cases

    @Test("Non-ASCII subject uses RFC 2047 encoded-word")
    func testEmojiSubject() throws {
        let msg = makeMessage(subject: "🦞 hi", text: "hi")
        let out = try renderString(msg)
        #expect(out.contains("=?UTF-8?B?"))
        #expect(!out.contains("Subject: 🦞"), "emoji leaked unencoded into Subject")
    }

    @Test("QP encodes '=' as =3D and preserves printable ASCII")
    func testQuotedPrintableBasics() {
        let qp = MIMEMessage.quotedPrintable("a = b")
        #expect(qp == "a =3D b")
    }

    @Test("QP encodes trailing space as =20")
    func testQuotedPrintableTrailingSpace() {
        let qp = MIMEMessage.quotedPrintable("trailing ")
        #expect(qp == "trailing=20")
    }

    @Test("QP encodes non-ASCII bytes as =HH")
    func testQuotedPrintableNonASCII() {
        // é = 0xC3 0xA9 in UTF-8
        let qp = MIMEMessage.quotedPrintable("café")
        #expect(qp == "caf=C3=A9")
    }

    @Test("QP soft-wraps long lines under 76 chars")
    func testQuotedPrintableSoftWrap() {
        let long = String(repeating: "a", count: 200)
        let qp = MIMEMessage.quotedPrintable(long)
        for line in qp.components(separatedBy: "\r\n") {
            #expect(line.count <= 76, "QP line exceeded 76 chars: \(line.count)")
        }
    }

    @Test("Bare LF in body is normalized to CRLF")
    func testLineEndingNormalization() {
        let input = "line1\nline2\nline3"
        let normalized = MIMEMessage.normalizeLineEndings(input)
        #expect(normalized == "line1\r\nline2\r\nline3")
    }

    @Test("CR-only line endings are normalized to CRLF")
    func testCROnlyNormalization() {
        let input = "line1\rline2"
        let normalized = MIMEMessage.normalizeLineEndings(input)
        #expect(normalized == "line1\r\nline2")
    }

    @Test("Already-CRLF input is idempotent under normalization")
    func testCRLFIdempotent() {
        let input = "line1\r\nline2"
        #expect(MIMEMessage.normalizeLineEndings(input) == input)
    }

    // MARK: - Boundary / line-length properties

    @Test("No rendered body line exceeds 998 bytes")
    func testBodyLineLengthCap() throws {
        // Minified HTML line ~5000 chars is a realistic worst case.
        let longHTML = "<div>" + String(repeating: "x", count: 5000) + "</div>"
        let msg = makeMessage(html: longHTML)
        let data = try msg.render()
        let rendered = String(data: data, encoding: .utf8)!
        for line in rendered.components(separatedBy: "\r\n") {
            #expect(line.utf8.count <= 998, "Line too long: \(line.utf8.count) bytes")
        }
    }

    @Test("Boundary is not present in body content")
    func testBoundaryNoCollision() throws {
        // Normal render: collision avoidance is a no-op but verify output correctness.
        let msg = makeMessage(text: "plain", html: "<p>html</p>", boundary: "=_Part_UNIQUE_X7")
        let out = try renderString(msg)
        let bodyOnly = out.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        // Count occurrences of --boundary and --boundary--.
        // multipart/alternative with 2 sub-parts: 2 opening boundary markers + 1 closing = 3 total hits
        let open = bodyOnly.components(separatedBy: "--=_Part_UNIQUE_X7\r\n").count - 1
        let close = bodyOnly.components(separatedBy: "--=_Part_UNIQUE_X7--\r\n").count - 1
        #expect(open == 2)
        #expect(close == 1)
    }

    @Test("Boundary collision triggers retry and eventually gives up")
    func testBoundaryCollisionRetry() throws {
        // Force the factory to always return a boundary that appears in the body.
        let bad = "=_Part_IN_BODY"
        var msg = makeMessage(text: "contains --\(bad) inside", html: "<p>x</p>")
        msg.boundaryFactory = { bad }
        #expect(throws: MIMEError.self) { _ = try msg.render() }
    }

    // MARK: - Header details

    @Test("Cc is included in headers, Cc-less message has no Cc header")
    func testCcHeader() throws {
        let withCc = makeMessage(cc: ["one@example.com"], text: "hi")
        #expect(try renderString(withCc).contains("Cc: one@example.com\r\n"))

        let noCc = makeMessage(text: "hi")
        #expect(!(try renderString(noCc).contains("Cc:")))
    }

    @Test("Long header value is folded at whitespace")
    func testHeaderFolding() {
        let long = "A: " + String(repeating: "word ", count: 40)
        let folded = MIMEMessage.foldHeader(long)
        for line in folded.components(separatedBy: "\r\n") {
            #expect(line.count <= 78, "Folded header line over 78 chars: \(line.count)")
        }
        // Continuation lines start with a space.
        let lines = folded.components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            #expect(line.hasPrefix(" "))
        }
    }

    @Test("Domain extraction works for Name <addr> and bare addr")
    func testDomainExtraction() throws {
        #expect(try MIMEMessage.extractDomain(from: "foo@example.com") == "example.com")
        #expect(try MIMEMessage.extractDomain(from: "Name <foo@example.com>") == "example.com")
    }

    @Test("RFC 5322 date format is parseable")
    func testDateFormat() {
        // formatRFC5322Date renders in local timezone — epoch 0 is 1969 west of UTC, 1970 at/east of UTC
        let s = MIMEMessage.formatRFC5322Date(Date(timeIntervalSince1970: 0))
        #expect(s.contains("1969") || s.contains("1970"),
                "Expected year 1969 or 1970 in: \(s)")
        #expect(s.range(of: #"^[A-Z][a-z]{2}, \d{1,2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} [+-]\d{4}$"#,
                       options: .regularExpression) != nil,
                "Date does not match RFC 5322 shape: \(s)")
    }

    // MARK: - allRecipients

    @Test("allRecipients concatenates To + Cc + Bcc in order")
    func testAllRecipientsOrder() {
        let msg = makeMessage(
            to: ["t1@x.com", "t2@x.com"],
            cc: ["c1@x.com"],
            bcc: ["b1@x.com"]
        )
        #expect(msg.allRecipients() == ["t1@x.com", "t2@x.com", "c1@x.com", "b1@x.com"])
    }

    // MARK: - Base64 wrapping

    @Test("Base64 attachment body wraps at 76 chars with CRLF")
    func testBase64Wrap() {
        let data = Data((0..<300).map { UInt8($0 % 256) })
        let wrapped = String(data: MIMEMessage.base64Wrapped(data), encoding: .utf8)!
        for line in wrapped.components(separatedBy: "\r\n") where !line.isEmpty {
            #expect(line.count <= 76)
        }
    }

    // MARK: - Full multipart/mixed with text+html+attachment

    @Test("text + html + attachment produces nested multipart/mixed containing multipart/alternative")
    func testFullNestedMultipart() throws {
        let att = Attachment(filename: "r.txt", contentType: "text/plain", data: Data("hi".utf8))
        // Two boundaries needed — sequence them deterministically.
        var calls = 0
        var msg = makeMessage(text: "plain", html: "<p>html</p>", attachments: [att])
        msg.boundaryFactory = {
            calls += 1
            return calls == 1 ? "=_Outer_M" : "=_Inner_A"
        }

        let out = String(data: try msg.render(), encoding: .utf8)!
        #expect(out.contains("Content-Type: multipart/mixed; boundary=\"=_Outer_M\"\r\n"))
        #expect(out.contains("Content-Type: multipart/alternative; boundary=\"=_Inner_A\"\r\n"))
        #expect(out.contains("--=_Inner_A\r\nContent-Type: text/plain"))
        #expect(out.contains("--=_Inner_A\r\nContent-Type: text/html"))
        #expect(out.contains("--=_Inner_A--\r\n"))
        #expect(out.contains("--=_Outer_M\r\nContent-Type: text/plain; name=\"r.txt\""))
        #expect(out.contains("--=_Outer_M--\r\n"))
    }
}
