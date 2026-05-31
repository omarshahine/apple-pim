import Foundation

/// Errors produced by the IMAP APPEND state machine.
public enum IMAPClientError: Error, CustomStringConvertible {
    case unexpectedGreeting(String)
    case loginFailed(String)
    case appendNoContinuation(String)
    case appendRejected(String)
    case transport(SMTPTransportError)

    public var description: String {
        switch self {
        case .unexpectedGreeting(let s): return "unexpected IMAP greeting: \(s)"
        case .loginFailed(let s):        return "IMAP LOGIN failed: \(s)"
        case .appendNoContinuation(let s): return "IMAP APPEND got no continuation: \(s)"
        case .appendRejected(let s):     return "IMAP APPEND rejected: \(s)"
        case .transport(let e):          return "transport: \(e)"
        }
    }
}

/// Minimal IMAP client whose sole job is to APPEND a sent message to the Sent
/// folder so SMTP-delivered mail also shows up in Mail.app / iCloud.com (see
/// issue #63). It is intentionally tiny: connect (implicit TLS), LOGIN, APPEND,
/// LOGOUT. No SELECT, no SEARCH, no FETCH.
///
/// Folder-name conventions differ by provider: iCloud uses `"Sent Messages"`,
/// Gmail `"[Gmail]/Sent Mail"`, generic IMAP `"Sent"`. The caller supplies the
/// resolved folder via `sentFolder`.
///
/// APPEND failures are NOT fatal to the overall send — the message was already
/// delivered by SMTP. Callers surface APPEND errors as a non-fatal warning.
public struct IMAPClient: Sendable {

    public struct Credentials: Sendable {
        public let username: String
        public let password: String
        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    public let host: String
    public let port: Int
    public let credentials: Credentials
    public let sentFolder: String
    public let verbose: Bool
    public let logSink: SMTPLogSink
    public let timeout: TimeInterval

    public init(
        host: String,
        port: Int = 993,
        credentials: Credentials,
        sentFolder: String,
        verbose: Bool = false,
        logSink: SMTPLogSink = StderrSink(),
        timeout: TimeInterval = 30
    ) {
        self.host = host
        self.port = port
        self.credentials = credentials
        self.sentFolder = sentFolder
        self.verbose = verbose
        self.logSink = logSink
        self.timeout = timeout
    }

    /// Open an implicit-TLS connection and APPEND `rawMessage` to the Sent folder.
    public func appendToSent(_ rawMessage: Data, internalDate: Date) async throws {
        let transport = try await NWConnectionTransport(host: host, port: port, timeout: timeout)
        defer { Task { await transport.close() } }
        try await runAppend(transport: transport, rawMessage: rawMessage, internalDate: internalDate)
    }

    /// Testable entry point — caller provides the transport. Drives the tagged
    /// IMAP conversation: greeting → LOGIN → APPEND (literal) → LOGOUT.
    public func runAppend(transport: SMTPTransport, rawMessage: Data, internalDate: Date) async throws {
        // 1. Greeting (untagged "* OK ...").
        let greeting = try await receive(transport)
        guard greeting.uppercased().contains("OK") else {
            throw IMAPClientError.unexpectedGreeting(greeting)
        }

        // 2. LOGIN. Password is redacted from the verbose log.
        let loginTag = "A1"
        try await writeLineRedacted(
            transport,
            "\(loginTag) LOGIN \(Self.quoteIMAP(credentials.username)) \(Self.quoteIMAP(credentials.password))",
            display: "\(loginTag) LOGIN \(Self.quoteIMAP(credentials.username)) <PASSWORD>"
        )
        let login = try await readTagged(transport, tag: loginTag)
        guard login.ok else { throw IMAPClientError.loginFailed(login.text) }

        // 3. APPEND with a literal. The command line ends with `{N}`; the server
        //    answers with a `+` continuation, then we stream exactly N octets
        //    followed by a CRLF that terminates the command.
        //
        //    The literal is `rawMessage` verbatim (N == rawMessage.count) — the
        //    terminating CRLF is a SEPARATE octet pair that is NOT counted in {N}
        //    (RFC 3501 §6.3.11; this matches Python's imaplib). Folding the CRLF
        //    into the literal would either mis-count {N} or, for a message that
        //    already ends in CRLF (the normal rendered case), omit the terminator
        //    entirely and hang the session waiting for end-of-command.
        let appendTag = "A2"
        let dateArg = Self.imapInternalDate(internalDate)
        let literalLength = rawMessage.count
        let appendCmd = "\(appendTag) APPEND \(Self.quoteIMAP(sentFolder)) (\\Seen) \"\(dateArg)\" {\(literalLength)}"
        try await writeLine(transport, appendCmd)

        let continuation = try await receive(transport)
        guard continuation.hasPrefix("+") else {
            // No continuation — the command was rejected outright (e.g. folder
            // missing). The line is the tagged NO/BAD or an error.
            throw IMAPClientError.appendNoContinuation(continuation)
        }

        // Stream the N-octet literal, then the command-terminating CRLF.
        var payload = rawMessage
        payload.append(Data("\r\n".utf8))
        try await transport.send(payload)
        if verbose { logSink.log("C: <\(literalLength) bytes of APPEND literal>") }

        let appendResp = try await readTagged(transport, tag: appendTag)
        guard appendResp.ok else { throw IMAPClientError.appendRejected(appendResp.text) }

        // 4. LOGOUT (best-effort).
        try? await writeLine(transport, "A3 LOGOUT")
        _ = try? await readTagged(transport, tag: "A3")
    }

    // MARK: - Response reading

    /// Maximum untagged/continuation lines tolerated before the tagged response.
    /// A backstop against a server that streams indefinitely without ever sending
    /// the tag — the transport's receive timeout is the primary bound, this caps
    /// the pathological "fast but endless" case. Generous so legitimate multi-line
    /// responses never false-trip.
    private static let maxResponseLines = 10_000

    /// Read lines until the tagged response (`<tag> OK|NO|BAD …`) arrives,
    /// skipping untagged (`*`) and continuation (`+`) lines.
    private func readTagged(_ transport: SMTPTransport, tag: String) async throws -> (ok: Bool, text: String) {
        var lineCount = 0
        while true {
            let line = try await receive(transport)
            if line.hasPrefix(tag + " ") {
                let rest = String(line.dropFirst(tag.count + 1))
                return (rest.uppercased().hasPrefix("OK"), rest)
            }
            lineCount += 1
            if lineCount > Self.maxResponseLines {
                throw IMAPClientError.appendRejected(
                    "no tagged '\(tag)' response after \(Self.maxResponseLines) lines")
            }
            // Untagged status / continuation — keep reading.
        }
    }

    private func receive(_ transport: SMTPTransport) async throws -> String {
        let line = try await transport.receiveLine()
        if verbose { logSink.log("S: \(line)") }
        return line
    }

    // MARK: - Writing

    private func writeLine(_ transport: SMTPTransport, _ line: String) async throws {
        if verbose { logSink.log("C: \(line)") }
        try await transport.send(Data((line + "\r\n").utf8))
    }

    private func writeLineRedacted(_ transport: SMTPTransport, _ line: String, display: String) async throws {
        if verbose { logSink.log("C: \(display)") }
        try await transport.send(Data((line + "\r\n").utf8))
    }

    // MARK: - IMAP encoding helpers

    /// IMAP quoted-string: wrap in double quotes, escaping `\` and `"`.
    static func quoteIMAP(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// IMAP date-time for APPEND, e.g. `17-Apr-2026 12:34:56 -0700`.
    static func imapInternalDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return f.string(from: date)
    }
}
