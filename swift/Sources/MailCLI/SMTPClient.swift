import Foundation

/// Errors produced by the SMTP client state machine.
public enum SMTPClientError: Error, CustomStringConvertible {
    case unexpectedGreeting(SMTPResponse)
    case ehloFailed(SMTPResponse)
    case authNotSupported
    case authFailed(SMTPResponse)
    case mailFromRejected(SMTPResponse)
    case rcptRejected(address: String, response: SMTPResponse)
    case dataRejected(SMTPResponse)
    case dataEndRejected(SMTPResponse)
    case starttlsNotSupported(SMTPResponse)
    case starttlsRejected(SMTPResponse)
    case transport(SMTPTransportError)

    public var description: String {
        switch self {
        case .unexpectedGreeting(let r): return "unexpected SMTP greeting: \(r)"
        case .ehloFailed(let r):         return "EHLO failed: \(r)"
        case .authNotSupported:          return "server does not advertise AUTH LOGIN"
        case .authFailed(let r):         return "authentication failed: \(r)"
        case .mailFromRejected(let r):   return "MAIL FROM rejected: \(r)"
        case .rcptRejected(let a, let r): return "RCPT TO <\(a)> rejected: \(r)"
        case .dataRejected(let r):       return "DATA rejected: \(r)"
        case .dataEndRejected(let r):    return "message body rejected: \(r)"
        case .starttlsNotSupported(let r): return "server does not advertise STARTTLS: \(r)"
        case .starttlsRejected(let r):   return "STARTTLS rejected: \(r)"
        case .transport(let e):          return "transport: \(e)"
        }
    }
}

/// Drive the pre-TLS SMTP exchange for a STARTTLS connection: read the greeting,
/// send EHLO, confirm the STARTTLS capability is advertised, issue STARTTLS, and
/// read its 220 acceptance. On successful return the caller must upgrade the
/// underlying transport to TLS and then proceed with the normal conversation
/// (which re-issues EHLO over the encrypted channel).
///
/// This is expressed purely over the `SMTPTransport` abstraction so it can be
/// exercised by `FakeTransport` without real TLS (see issue #62).
public func negotiateSTARTTLS(over transport: SMTPTransport, ehloHostname: String) async throws {
    // 1. Greeting
    let greeting = try await readSMTPResponse(from: transport)
    guard greeting.code == 220 else {
        throw SMTPClientError.unexpectedGreeting(greeting)
    }

    // 2. EHLO (plaintext) and capability parse
    try await transport.send(Data("EHLO \(ehloHostname)\r\n".utf8))
    let ehlo = try await readSMTPResponse(from: transport)
    guard ehlo.code == 250 else {
        throw SMTPClientError.ehloFailed(ehlo)
    }
    let starttlsAdvertised = ehlo.lines.contains { $0.uppercased().contains("STARTTLS") }
    guard starttlsAdvertised else {
        throw SMTPClientError.starttlsNotSupported(ehlo)
    }

    // 3. STARTTLS
    try await transport.send(Data("STARTTLS\r\n".utf8))
    let resp = try await readSMTPResponse(from: transport)
    guard resp.code == 220 else {
        throw SMTPClientError.starttlsRejected(resp)
    }
}

/// Sink for the SMTP wire log. `stderr` by default; tests can swap to a buffer.
public protocol SMTPLogSink: AnyObject, Sendable {
    func log(_ line: String)
}

public final class StderrSink: SMTPLogSink, @unchecked Sendable {
    public init() {}
    public func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// Result bundle returned by `SMTPClient.sendMessage`.
public struct SMTPSendResult: Sendable {
    public let accepted: [String]
    public let rejected: [(address: String, response: SMTPResponse)]
    public let messageID: String

    public var allSucceeded: Bool { rejected.isEmpty && !accepted.isEmpty }
}

/// State-machine SMTP client. Runs one conversation per `sendMessage` call.
///
/// Supports: AUTH LOGIN + implicit TLS only. Fails fast on any non-success code.
/// The MIME body is dot-stuffed during the DATA phase (see RFC 5321 §4.5.2).
///
/// Bcc recipients are included in `RCPT TO` but are isolated from the rendered
/// body headers by `MIMEMessage.render()`.
public struct SMTPClient: Sendable {

    public struct Credentials: Sendable {
        public let username: String
        public let password: String
        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    /// How TLS is established. `implicit` connects with TLS already active (port 465,
    /// iCloud default). `starttls` connects in plaintext and upgrades via the STARTTLS
    /// command (port 587, corporate Exchange / Postfix / university relays).
    public enum TLSMode: String, Sendable, CaseIterable {
        case implicit
        case starttls
    }

    public let host: String
    public let port: Int
    public let credentials: Credentials
    public let ehloHostname: String
    public let verbose: Bool
    public let logSink: SMTPLogSink
    public let timeout: TimeInterval
    public let tlsMode: TLSMode
    public let insecureSkipVerify: Bool

    public init(
        host: String,
        port: Int,
        credentials: Credentials,
        ehloHostname: String? = nil,
        verbose: Bool = false,
        logSink: SMTPLogSink = StderrSink(),
        timeout: TimeInterval = 30,
        tlsMode: TLSMode = .implicit,
        insecureSkipVerify: Bool = false
    ) {
        self.host = host
        self.port = port
        self.credentials = credentials
        self.ehloHostname = ehloHostname ?? ProcessInfo.processInfo.hostName
        self.verbose = verbose
        self.logSink = logSink
        self.timeout = timeout
        self.tlsMode = tlsMode
        self.insecureSkipVerify = insecureSkipVerify
    }

    /// Open a transport, run the full conversation, and close cleanly.
    ///
    /// For `implicit` TLS this is a plain `NWConnectionTransport`. For `starttls`
    /// the `STARTTLSTransport` performs the plaintext greeting/EHLO/STARTTLS
    /// exchange and TLS upgrade during `init`, then presents a synthetic 220
    /// greeting so the standard conversation (which re-issues EHLO over the now
    /// encrypted channel) proceeds unchanged.
    public func sendMessage(_ msg: MIMEMessage) async throws -> SMTPSendResult {
        let transport: SMTPTransport
        switch tlsMode {
        case .implicit:
            transport = try await NWConnectionTransport(host: host, port: port, timeout: timeout)
        case .starttls:
            transport = try await STARTTLSTransport(
                host: host, port: port, ehloHostname: ehloHostname,
                insecureSkipVerify: insecureSkipVerify, verbose: verbose,
                logSink: logSink, timeout: timeout
            )
        }
        defer { Task { await transport.close() } }
        return try await runConversation(transport: transport, message: msg)
    }

    /// Testable entry point — caller provides the transport. Closes on completion.
    public func runConversation(transport: SMTPTransport, message: MIMEMessage) async throws -> SMTPSendResult {
        // Lock in a Message-ID now so it appears in the returned result even when
        // the caller didn't specify one explicitly (render() would otherwise generate
        // one locally that the result struct can't see).
        var msg = message
        if msg.messageID == nil {
            let domain = try MIMEMessage.extractDomain(from: msg.from)
            msg.messageID = msg.messageIDFactory(domain)
        }

        // 1. Greeting
        let greeting = try await readResponse(transport)
        guard greeting.code == 220 else {
            throw SMTPClientError.unexpectedGreeting(greeting)
        }

        // 2. EHLO
        try await writeLine(transport, "EHLO \(ehloHostname)")
        let ehlo = try await readResponse(transport)
        guard ehlo.code == 250 else {
            throw SMTPClientError.ehloFailed(ehlo)
        }
        let authSupported = ehlo.lines.contains(where: { $0.uppercased().contains("AUTH") && $0.uppercased().contains("LOGIN") })
        guard authSupported else {
            throw SMTPClientError.authNotSupported
        }

        // 3. AUTH LOGIN (username + password, each base64-encoded on its own line)
        try await writeLine(transport, "AUTH LOGIN")
        let authStart = try await readResponse(transport)
        guard authStart.code == 334 else {
            throw SMTPClientError.authFailed(authStart)
        }
        try await writeLineRedacted(transport, Data(credentials.username.utf8).base64EncodedString(), redactAs: "<USERNAME_B64>")
        let userReply = try await readResponse(transport)
        guard userReply.code == 334 else {
            throw SMTPClientError.authFailed(userReply)
        }
        try await writeLineRedacted(transport, Data(credentials.password.utf8).base64EncodedString(), redactAs: "<PASSWORD_B64>")
        let passReply = try await readResponse(transport)
        guard passReply.code == 235 else {
            throw SMTPClientError.authFailed(passReply)
        }

        // 4. MAIL FROM
        let fromAddr = Self.extractAddrSpec(msg.from)
        try await writeLine(transport, "MAIL FROM:<\(fromAddr)>")
        let mailFromReply = try await readResponse(transport)
        guard mailFromReply.code == 250 else {
            throw SMTPClientError.mailFromRejected(mailFromReply)
        }

        // 5. RCPT TO x N
        let rawRecipients = msg.allRecipients()
        var accepted: [String] = []
        var rejected: [(String, SMTPResponse)] = []
        for raw in rawRecipients {
            let addr = Self.extractAddrSpec(raw)
            try await writeLine(transport, "RCPT TO:<\(addr)>")
            let r = try await readResponse(transport)
            if r.code == 250 || r.code == 251 {
                accepted.append(addr)
            } else {
                rejected.append((addr, r))
            }
        }
        // If every recipient was rejected, abort rather than proceeding to DATA.
        if accepted.isEmpty {
            // Emit RSET and tear down.
            try? await writeLine(transport, "RSET")
            _ = try? await readResponse(transport)
            try? await writeLine(transport, "QUIT")
            _ = try? await readResponse(transport)
            let (firstAddr, firstResp) = rejected.first ?? ("", SMTPResponse(code: 0, lines: ["all recipients rejected"]))
            throw SMTPClientError.rcptRejected(address: firstAddr, response: firstResp)
        }

        // 6. DATA
        try await writeLine(transport, "DATA")
        let dataReady = try await readResponse(transport)
        guard dataReady.code == 354 else {
            throw SMTPClientError.dataRejected(dataReady)
        }

        // 7. Body + end-of-data marker — sent as a single payload so the state is
        //    atomic from the server's point of view (and so scripted fake transports
        //    can match a single predicate per step).
        let rendered = try msg.render()
        let dotStuffed = Self.dotStuff(rendered)
        var payload = dotStuffed
        // Guarantee the body ends with CRLF before the terminator.
        if !payload.suffix(2).elementsEqual("\r\n".utf8) {
            payload.append(Data("\r\n".utf8))
        }
        payload.append(Data(".\r\n".utf8))
        try await transport.send(payload)
        if verbose {
            logSink.log("C: <\(dotStuffed.count) bytes of message body>\nC: .")
        }
        let dataAck = try await readResponse(transport)
        guard dataAck.code == 250 else {
            throw SMTPClientError.dataEndRejected(dataAck)
        }

        // 8. QUIT
        try await writeLine(transport, "QUIT")
        _ = try? await readResponse(transport)

        return SMTPSendResult(
            accepted: accepted,
            rejected: rejected.map { (address: $0.0, response: $0.1) },
            messageID: msg.messageID ?? ""
        )
    }

    // MARK: - Transport helpers with verbose logging

    private func writeLine(_ transport: SMTPTransport, _ line: String) async throws {
        if verbose { logSink.log("C: \(line)") }
        try await transport.send(Data((line + "\r\n").utf8))
    }

    private func writeLineRedacted(_ transport: SMTPTransport, _ line: String, redactAs: String) async throws {
        if verbose { logSink.log("C: \(redactAs)") }
        try await transport.send(Data((line + "\r\n").utf8))
    }

    private func readResponse(_ transport: SMTPTransport) async throws -> SMTPResponse {
        let r = try await readSMTPResponse(from: transport)
        if verbose {
            for (i, line) in r.lines.enumerated() {
                let sep = i == r.lines.count - 1 ? " " : "-"
                logSink.log("S: \(r.code)\(sep)\(line)")
            }
        }
        return r
    }

    // MARK: - RFC helpers

    /// Pull the addr-spec out of a raw address:
    ///   `"Name <foo@bar>"` → `foo@bar`
    ///   `"foo@bar"` → `foo@bar`
    ///   `"  foo@bar  "` → `foo@bar`
    public static func extractAddrSpec(_ raw: String) -> String {
        if let lt = raw.firstIndex(of: "<"), let gt = raw.lastIndex(of: ">"), lt < gt {
            return String(raw[raw.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    /// RFC 5321 §4.5.2: every line in DATA that starts with `.` must be doubled.
    /// Also enforce CRLF everywhere — input is expected to be CRLF already, but we guard.
    public static func dotStuff(_ input: Data) -> Data {
        let crlf = Data("\r\n".utf8)
        var out = Data()
        out.reserveCapacity(input.count)
        var lineStart = 0
        var i = 0
        while i < input.count {
            // Find next CRLF
            if i + 1 < input.count && input[i] == 0x0D && input[i + 1] == 0x0A {
                if input[lineStart] == 0x2E {
                    out.append(0x2E)
                }
                out.append(input.subdata(in: lineStart..<i))
                out.append(crlf)
                i += 2
                lineStart = i
            } else {
                i += 1
            }
        }
        // Trailing partial (no final CRLF) — handle the same way.
        if lineStart < input.count {
            if input[lineStart] == 0x2E {
                out.append(0x2E)
            }
            out.append(input.subdata(in: lineStart..<input.count))
        }
        return out
    }
}
