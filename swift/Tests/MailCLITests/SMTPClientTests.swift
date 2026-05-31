import Foundation
import Testing
@testable import MailCLI

@Suite("SMTPClient")
struct SMTPClientTests {

    private func creds() -> SMTPClient.Credentials {
        .init(username: "user@example.com", password: "app-password-1234")
    }

    private func basicMessage() -> MIMEMessage {
        var msg = MIMEMessage(
            from: "user@example.com",
            to: ["dest@example.com"],
            subject: "Hello",
            text: "Body text"
        )
        msg.boundaryFactory = { "=_Part_DETERMINISTIC" }
        msg.messageIDFactory = { _ in "<fixed@example.com>" }
        return msg
    }

    private func client(verbose: Bool = false, logSink: SMTPLogSink = StderrSink()) -> SMTPClient {
        SMTPClient(
            host: "localhost",
            port: 2525,
            credentials: creds(),
            ehloHostname: "test.local",
            verbose: verbose,
            logSink: logSink
        )
    }

    // MARK: - Happy path

    @Test("Successful send follows greeting → EHLO → AUTH → MAIL FROM → RCPT TO → DATA → QUIT")
    func testHappyPath() async throws {
        let fake = FakeTransport([
            .reply(lines: ["220 smtp.example.com ready"]),
            .expectSend({ $0 == "EHLO test.local\r\n" }, label: "EHLO"),
            .reply(lines: ["250-smtp.example.com greets test.local",
                           "250-AUTH LOGIN PLAIN",
                           "250 8BITMIME"]),
            .expectSend({ $0 == "AUTH LOGIN\r\n" }, label: "AUTH LOGIN"),
            .reply(lines: ["334 VXNlcm5hbWU6"]),
            .expectSend({
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == Data("user@example.com".utf8).base64EncodedString()
            }, label: "username base64"),
            .reply(lines: ["334 UGFzc3dvcmQ6"]),
            .expectSend({
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == Data("app-password-1234".utf8).base64EncodedString()
            }, label: "password base64"),
            .reply(lines: ["235 2.7.0 Authentication successful"]),
            .expectSend({ $0 == "MAIL FROM:<user@example.com>\r\n" }, label: "MAIL FROM"),
            .reply(lines: ["250 OK"]),
            .expectSend({ $0 == "RCPT TO:<dest@example.com>\r\n" }, label: "RCPT TO"),
            .reply(lines: ["250 OK"]),
            .expectSend({ $0 == "DATA\r\n" }, label: "DATA"),
            .reply(lines: ["354 End data with <CR><LF>.<CR><LF>"]),
            .expectSend({
                $0.hasPrefix("From: user@example.com\r\n") && $0.hasSuffix("\r\n.\r\n")
            }, label: "message body + end-of-data"),
            .reply(lines: ["250 2.0.0 OK: queued as ABC123"]),
            .expectSend({ $0 == "QUIT\r\n" }, label: "QUIT"),
            .reply(lines: ["221 bye"]),
        ])

        let result = try await client().runConversation(transport: fake, message: basicMessage())
        #expect(result.accepted == ["dest@example.com"])
        #expect(result.rejected.isEmpty)
        #expect(result.allSucceeded)
        try fake.verifyComplete()
    }

    // MARK: - Failure modes

    @Test("Unexpected greeting code fails fast")
    func testUnexpectedGreeting() async throws {
        let fake = FakeTransport([
            .reply(lines: ["421 service unavailable"]),
        ])
        await #expect(throws: SMTPClientError.self) {
            _ = try await client().runConversation(transport: fake, message: basicMessage())
        }
    }

    @Test("EHLO without AUTH LOGIN advertised is rejected")
    func testNoAuthLogin() async throws {
        let fake = FakeTransport([
            .reply(lines: ["220 ok"]),
            .expectSend({ $0.hasPrefix("EHLO ") }, label: "EHLO"),
            .reply(lines: ["250-hello", "250 8BITMIME"]),
        ])
        await #expect(throws: SMTPClientError.self) {
            _ = try await client().runConversation(transport: fake, message: basicMessage())
        }
    }

    @Test("Auth failure surfaces as authFailed error")
    func testAuthFailed() async throws {
        let fake = FakeTransport([
            .reply(lines: ["220 ok"]),
            .expectSend({ $0.hasPrefix("EHLO ") }, label: "EHLO"),
            .reply(lines: ["250-hello", "250 AUTH LOGIN"]),
            .expectSend({ $0 == "AUTH LOGIN\r\n" }, label: "AUTH LOGIN"),
            .reply(lines: ["334 VXNlcm5hbWU6"]),
            .expectSend({ !$0.isEmpty }, label: "username"),
            .reply(lines: ["334 UGFzc3dvcmQ6"]),
            .expectSend({ !$0.isEmpty }, label: "password"),
            .reply(lines: ["535 5.7.8 Authentication failed"]),
        ])
        await #expect(throws: SMTPClientError.self) {
            _ = try await client().runConversation(transport: fake, message: basicMessage())
        }
    }

    @Test("All-recipients-rejected aborts before DATA")
    func testAllRecipientsRejected() async throws {
        let fake = FakeTransport([
            .reply(lines: ["220 ok"]),
            .expectSend({ $0.hasPrefix("EHLO ") }, label: "EHLO"),
            .reply(lines: ["250-hello", "250 AUTH LOGIN"]),
            .expectSend({ $0 == "AUTH LOGIN\r\n" }, label: "AUTH LOGIN"),
            .reply(lines: ["334 VXNlcm5hbWU6"]),
            .expectSend({ !$0.isEmpty }, label: "username"),
            .reply(lines: ["334 UGFzc3dvcmQ6"]),
            .expectSend({ !$0.isEmpty }, label: "password"),
            .reply(lines: ["235 auth ok"]),
            .expectSend({ $0.hasPrefix("MAIL FROM:") }, label: "MAIL FROM"),
            .reply(lines: ["250 ok"]),
            .expectSend({ $0.hasPrefix("RCPT TO:") }, label: "RCPT TO"),
            .reply(lines: ["550 no such user"]),
            .expectSend({ $0 == "RSET\r\n" }, label: "RSET"),
            .reply(lines: ["250 ok"]),
            .expectSend({ $0 == "QUIT\r\n" }, label: "QUIT"),
            .reply(lines: ["221 bye"]),
        ])
        await #expect(throws: SMTPClientError.self) {
            _ = try await client().runConversation(transport: fake, message: basicMessage())
        }
    }

    // MARK: - Dot-stuffing

    @Test("dotStuff doubles lines starting with '.'")
    func testDotStuff() {
        let input = Data("normal\r\n.dangerous\r\nfine\r\n..already\r\n".utf8)
        let out = String(data: SMTPClient.dotStuff(input), encoding: .utf8)!
        #expect(out == "normal\r\n..dangerous\r\nfine\r\n...already\r\n")
    }

    @Test("dotStuff preserves content with no leading dots")
    func testDotStuffNoChange() {
        let input = Data("hello\r\nworld\r\n".utf8)
        #expect(SMTPClient.dotStuff(input) == input)
    }

    // MARK: - addr-spec extraction

    @Test("extractAddrSpec handles Name <addr> and bare addr")
    func testExtractAddrSpec() {
        #expect(SMTPClient.extractAddrSpec("foo@bar") == "foo@bar")
        #expect(SMTPClient.extractAddrSpec("Name <foo@bar>") == "foo@bar")
        #expect(SMTPClient.extractAddrSpec("  foo@bar  ") == "foo@bar")
    }

    // MARK: - Verbose logging redacts password

    @Test("Verbose mode never logs the plaintext password")
    func testVerboseRedaction() async throws {
        let collector = CollectorSink()
        let fake = FakeTransport([
            .reply(lines: ["220 ok"]),
            .expectSend({ $0.hasPrefix("EHLO ") }, label: "EHLO"),
            .reply(lines: ["250-hello", "250 AUTH LOGIN"]),
            .expectSend({ $0 == "AUTH LOGIN\r\n" }, label: "AUTH LOGIN"),
            .reply(lines: ["334 VXNlcm5hbWU6"]),
            .expectSend({ _ in true }, label: "username"),
            .reply(lines: ["334 UGFzc3dvcmQ6"]),
            .expectSend({ _ in true }, label: "password"),
            .reply(lines: ["235 ok"]),
            .expectSend({ $0.hasPrefix("MAIL FROM:") }, label: "MAIL FROM"),
            .reply(lines: ["250 ok"]),
            .expectSend({ $0.hasPrefix("RCPT TO:") }, label: "RCPT TO"),
            .reply(lines: ["250 ok"]),
            .expectSend({ $0 == "DATA\r\n" }, label: "DATA"),
            .reply(lines: ["354 go"]),
            .expectSend({ $0.hasSuffix("\r\n.\r\n") }, label: "body + end"),
            .reply(lines: ["250 queued"]),
            .expectSend({ $0 == "QUIT\r\n" }, label: "QUIT"),
            .reply(lines: ["221 bye"]),
        ])

        _ = try await client(verbose: true, logSink: collector)
            .runConversation(transport: fake, message: basicMessage())

        let logged = collector.lines.joined(separator: "\n")
        #expect(!logged.contains("app-password-1234"))
        #expect(!logged.contains(Data("app-password-1234".utf8).base64EncodedString()))
        #expect(logged.contains("<PASSWORD_B64>"))
    }
}

@Suite("STARTTLS negotiation")
struct STARTTLSNegotiationTests {

    // MARK: - Happy path

    @Test("negotiateSTARTTLS drives greeting → EHLO → STARTTLS → 220")
    func testHappyPath() async throws {
        let fake = FakeTransport([
            .reply(lines: ["220 smtp.example.com ESMTP ready"]),
            .expectSend({ $0 == "EHLO mail.test\r\n" }, label: "EHLO"),
            .reply(lines: ["250-smtp.example.com greets mail.test",
                           "250-STARTTLS",
                           "250 8BITMIME"]),
            .expectSend({ $0 == "STARTTLS\r\n" }, label: "STARTTLS"),
            .reply(lines: ["220 2.0.0 Ready to start TLS"]),
        ])

        try await negotiateSTARTTLS(over: fake, ehloHostname: "mail.test")
        try fake.verifyComplete()
    }

    // MARK: - Failure modes

    @Test("Non-220 greeting fails fast")
    func testBadGreeting() async throws {
        let fake = FakeTransport([
            .reply(lines: ["554 go away"]),
        ])
        await #expect(throws: SMTPClientError.self) {
            try await negotiateSTARTTLS(over: fake, ehloHostname: "mail.test")
        }
    }

    @Test("EHLO without STARTTLS capability is rejected")
    func testNoStarttlsCapability() async throws {
        let fake = FakeTransport([
            .reply(lines: ["220 ready"]),
            .expectSend({ $0.hasPrefix("EHLO ") }, label: "EHLO"),
            .reply(lines: ["250-hello", "250 8BITMIME"]),
        ])
        await #expect(throws: SMTPClientError.self) {
            try await negotiateSTARTTLS(over: fake, ehloHostname: "mail.test")
        }
    }

    @Test("STARTTLS command rejection surfaces as error")
    func testStarttlsRejected() async throws {
        let fake = FakeTransport([
            .reply(lines: ["220 ready"]),
            .expectSend({ $0.hasPrefix("EHLO ") }, label: "EHLO"),
            .reply(lines: ["250-hello", "250 STARTTLS"]),
            .expectSend({ $0 == "STARTTLS\r\n" }, label: "STARTTLS"),
            .reply(lines: ["454 4.7.0 TLS not available"]),
        ])
        await #expect(throws: SMTPClientError.self) {
            try await negotiateSTARTTLS(over: fake, ehloHostname: "mail.test")
        }
    }

    @Test("EHLO failure (non-250) is rejected")
    func testEhloFailure() async throws {
        let fake = FakeTransport([
            .reply(lines: ["220 ready"]),
            .expectSend({ $0.hasPrefix("EHLO ") }, label: "EHLO"),
            .reply(lines: ["502 command not implemented"]),
        ])
        await #expect(throws: SMTPClientError.self) {
            try await negotiateSTARTTLS(over: fake, ehloHostname: "mail.test")
        }
    }
}

/// Test sink that captures log lines for assertion.
final class CollectorSink: SMTPLogSink, @unchecked Sendable {
    private let queue = DispatchQueue(label: "collector")
    private var _lines: [String] = []
    var lines: [String] { queue.sync { _lines } }
    func log(_ line: String) { queue.sync { _lines.append(line) } }
}
