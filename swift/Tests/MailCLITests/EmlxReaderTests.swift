import XCTest
@testable import MailCLI

final class EmlxReaderTests: XCTestCase {

    private func emlxData(message: String) -> Data {
        let body = Data(message.utf8)
        var data = Data("\(body.count)\n".utf8)
        data.append(body)
        data.append(Data("<?xml version=\"1.0\"?><plist/>".utf8)) // trailer is ignored
        return data
    }

    // MARK: - emlx envelope

    func testParseSimplePlainText() throws {
        let raw = "From: a@b.com\r\nSubject: Hi\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHello world\r\n"
        let msg = try parseEmlx(data: emlxData(message: raw))
        XCTAssertEqual(msg.content.trimmingCharacters(in: .whitespacesAndNewlines), "Hello world")
        XCTAssertEqual(msg.header("Subject"), "Hi")
        XCTAssertEqual(msg.header("subject"), "Hi") // case-insensitive
    }

    func testParseRejectsMissingByteCount() {
        XCTAssertThrowsError(try parseEmlx(data: Data("no newline at all".utf8)))
    }

    func testByteCountLimitsMessage() throws {
        // Byte count shorter than the data: the plist trailer must not leak into the body.
        let message = "A: b\r\n\r\nBody"
        let msg = try parseEmlx(data: emlxData(message: message))
        XCTAssertFalse(msg.content.contains("plist"))
    }

    // MARK: - Headers

    func testHeaderUnfolding() {
        let headers = parseHeaderBlock("Subject: a very\r\n long subject\r\nFrom: x@y.z")
        XCTAssertEqual(headers.first { $0.name == "Subject" }?.value, "a very long subject")
        XCTAssertEqual(headers.first { $0.name == "From" }?.value, "x@y.z")
    }

    func testMimeParameter() {
        XCTAssertEqual(mimeParameter("multipart/alternative; boundary=\"abc123\"", "boundary"), "abc123")
        XCTAssertEqual(mimeParameter("multipart/mixed; boundary=xyz", "boundary"), "xyz")
        XCTAssertEqual(mimeParameter("text/plain; charset=utf-8", "charset"), "utf-8")
        XCTAssertNil(mimeParameter("text/plain", "boundary"))
    }

    // MARK: - Multipart

    func testMultipartPrefersTextPlain() throws {
        let raw = """
        Content-Type: multipart/alternative; boundary="BOUND"\r
        \r
        --BOUND\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        plain body\r
        --BOUND\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>html body</p>\r
        --BOUND--\r
        """
        let msg = try parseEmlx(data: emlxData(message: raw))
        XCTAssertEqual(msg.content.trimmingCharacters(in: .whitespacesAndNewlines), "plain body")
    }

    func testMultipartFallsBackToStrippedHTML() throws {
        let raw = """
        Content-Type: multipart/alternative; boundary="BOUND"\r
        \r
        --BOUND\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><p>Hello <b>there</b></p></body></html>\r
        --BOUND--\r
        """
        let msg = try parseEmlx(data: emlxData(message: raw))
        XCTAssertEqual(msg.content, "Hello there")
    }

    // MARK: - Transfer encodings

    func testQuotedPrintableDecoding() {
        let decoded = decodeQuotedPrintable(Data("Caf=C3=A9 soft=\r\nbreak".utf8))
        XCTAssertEqual(String(data: decoded, encoding: .utf8), "Café softbreak")
    }

    func testBase64BodyDecoding() throws {
        let base64 = Data("Hello base64".utf8).base64EncodedString()
        let raw = "Content-Type: text/plain\r\nContent-Transfer-Encoding: base64\r\n\r\n\(base64)\r\n"
        let msg = try parseEmlx(data: emlxData(message: raw))
        XCTAssertEqual(msg.content.trimmingCharacters(in: .whitespacesAndNewlines), "Hello base64")
    }

    func testLatin1Charset() throws {
        var raw = Data("Content-Type: text/plain; charset=iso-8859-1\r\n\r\n".utf8)
        raw.append(Data([0xE9])) // 'é' in latin-1, invalid as UTF-8
        let msg = try parseEmlx(data: {
            var d = Data("\(raw.count)\n".utf8); d.append(raw); return d
        }())
        XCTAssertEqual(msg.content, "é")
    }

    // MARK: - HTML stripping

    func testStripHTMLDropsStyleBlocks() {
        let html = "<html><head><style>p { color: red }</style></head><body>Visible</body></html>"
        XCTAssertEqual(stripHTMLTags(html), "Visible")
    }

    func testStripHTMLEntities() {
        XCTAssertEqual(stripHTMLTags("a &amp; b&nbsp;&lt;c&gt;"), "a & b <c>")
    }
}
