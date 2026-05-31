import Darwin
import Foundation
import Network
import Security

/// Abstract I/O for the SMTP state machine. A real deployment uses `NWConnectionTransport`;
/// unit tests use a `FakeTransport` that scripts a conversation.
public protocol SMTPTransport: AnyObject, Sendable {
    /// Send raw bytes to the peer.
    func send(_ data: Data) async throws

    /// Read one line, terminated by CRLF. Returns the line without the CRLF.
    /// Throws on EOF before CRLF or on timeout.
    func receiveLine() async throws -> String

    /// Close the connection. Idempotent.
    func close() async
}

/// A single SMTP status reply, possibly multi-line.
public struct SMTPResponse: Sendable, CustomStringConvertible {
    public let code: Int
    public let lines: [String]

    public var description: String {
        lines.map { "\(code) \($0)" }.joined(separator: "\n")
    }
    public var firstText: String { lines.first ?? "" }
}

/// Errors raised by the SMTP transport layer.
public enum SMTPTransportError: Error, CustomStringConvertible {
    case connectFailed(host: String, port: Int, underlying: Error)
    case sendFailed(Error)
    case connectionClosed
    case timedOut(stage: String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .connectFailed(let h, let p, let e):
            return "failed to connect to \(h):\(p): \(e.localizedDescription)"
        case .sendFailed(let e): return "send failed: \(e.localizedDescription)"
        case .connectionClosed: return "connection closed by peer mid-read"
        case .timedOut(let stage): return "timed out during \(stage)"
        case .invalidResponse(let s): return "invalid SMTP response: \(s)"
        }
    }
}

// MARK: - Line reader helpers usable across transports

/// Parse a multi-line SMTP response from a transport.
/// Example multi-line reply:
///   `250-smtp.example.com greets you`
///   `250-AUTH LOGIN PLAIN`
///   `250 8BITMIME`
/// A dash after the code (`NNN-...`) indicates more lines follow; a space (`NNN ...`) terminates.
public func readSMTPResponse(from transport: SMTPTransport) async throws -> SMTPResponse {
    var lines: [String] = []
    var code: Int = 0
    while true {
        let line = try await transport.receiveLine()
        guard line.count >= 4 else {
            throw SMTPTransportError.invalidResponse(line)
        }
        let codePrefix = String(line.prefix(3))
        guard let parsedCode = Int(codePrefix) else {
            throw SMTPTransportError.invalidResponse(line)
        }
        code = parsedCode
        let separator = line[line.index(line.startIndex, offsetBy: 3)]
        let text = String(line.dropFirst(4))
        lines.append(text)
        if separator == " " { break }
        if separator != "-" {
            throw SMTPTransportError.invalidResponse(line)
        }
    }
    return SMTPResponse(code: code, lines: lines)
}

// MARK: - Production transport backed by Network.framework

/// TLS-enabled TCP transport using `NWConnection` and `NWProtocolTLS`.
/// Suitable for implicit-TLS SMTP on port 465.
///
/// This class is a reference type so `NWConnection` can be retained across
/// async hops. It is marked `@unchecked Sendable` because all mutable state
/// is serialized through a private `DispatchQueue`.
public final class NWConnectionTransport: SMTPTransport, @unchecked Sendable {

    private let host: String
    private let port: Int
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let timeout: TimeInterval

    // Buffer for partial line accumulation, serialized on `queue`.
    private var buffer: Data = Data()
    // Continuation to signal the next waiting reader when new data arrives.
    private var waitingReader: CheckedContinuation<Void, Error>? = nil
    private var closed: Bool = false
    private var receiveError: Error? = nil

    /// Open a TLS connection to `host:port`.
    /// Blocks the caller's async context until the connection is ready or fails.
    public init(host: String, port: Int, timeout: TimeInterval = 30) async throws {
        self.host = host
        self.port = port
        self.timeout = timeout
        self.queue = DispatchQueue(label: "apple-pim.smtp.\(UUID().uuidString.prefix(8))")

        let tlsOptions = NWProtocolTLS.Options()
        // Default options use the system trust store and verify the server certificate.
        let params = NWParameters(tls: tlsOptions)
        let endpointHost = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw SMTPTransportError.connectFailed(host: host, port: port,
                underlying: NSError(domain: "SMTPTransport", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "invalid port: \(port)"]))
        }
        self.connection = NWConnection(host: endpointHost, port: endpointPort, using: params)

        // Wait for the connection to become .ready, with a timeout.
        try await withConnectTimeout(timeout: timeout) { [self] in
            try await withCheckedThrowingContinuation { cont in
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        cont.resume()
                        self.connection.stateUpdateHandler = { [weak self] st in self?.handleSteadyState(st) }
                        self.startReceiveLoop()
                    case .failed(let err):
                        cont.resume(throwing: SMTPTransportError.connectFailed(host: host, port: port, underlying: err))
                    case .cancelled:
                        cont.resume(throwing: SMTPTransportError.connectionClosed)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err {
                    cont.resume(throwing: SMTPTransportError.sendFailed(err))
                } else {
                    cont.resume()
                }
            })
        }
    }

    public func receiveLine() async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let line = try takeLineFromBuffer() { return line }
            if Date() > deadline {
                throw SMTPTransportError.timedOut(stage: "receiveLine")
            }
            try await waitForData(until: deadline)
        }
    }

    public func close() async {
        queue.sync {
            if closed { return }
            closed = true
            connection.cancel()
            if let w = waitingReader {
                w.resume(throwing: SMTPTransportError.connectionClosed)
                waitingReader = nil
            }
        }
    }

    // MARK: - Private

    private func startReceiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                }
                if let error {
                    self.receiveError = error
                    self.fulfillReader(throwing: error)
                    return
                }
                if isComplete {
                    self.closed = true
                    self.fulfillReader(throwing: nil)
                    return
                }
                // Wake any waiting reader and then continue receiving.
                self.fulfillReader(throwing: nil)
                self.startReceiveLoop()
            }
        }
    }

    private func fulfillReader(throwing err: Error?) {
        if let cont = waitingReader {
            waitingReader = nil
            if let err { cont.resume(throwing: err) }
            else { cont.resume() }
        }
    }

    private func handleSteadyState(_ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            queue.async {
                self.closed = true
                if let w = self.waitingReader {
                    w.resume(throwing: SMTPTransportError.connectionClosed)
                    self.waitingReader = nil
                }
            }
        default:
            break
        }
    }

    /// Pull a CRLF-terminated line out of the buffer if available.
    /// Runs on any thread — uses `queue.sync` for buffer access.
    private func takeLineFromBuffer() throws -> String? {
        try queue.sync {
            if let err = receiveError {
                receiveError = nil
                throw err
            }
            guard let crlfRange = buffer.range(of: Data("\r\n".utf8)) else {
                if closed && buffer.isEmpty { throw SMTPTransportError.connectionClosed }
                return nil
            }
            let lineData = buffer.subdata(in: 0..<crlfRange.lowerBound)
            buffer.removeSubrange(0..<crlfRange.upperBound)
            guard let s = String(data: lineData, encoding: .utf8) else {
                throw SMTPTransportError.invalidResponse("non-UTF8 SMTP reply")
            }
            return s
        }
    }

    private func waitForData(until deadline: Date) async throws {
        // Schedule ourselves into `waitingReader` and suspend until `fulfillReader` fires.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.closed {
                    cont.resume(throwing: SMTPTransportError.connectionClosed)
                    return
                }
                if !self.buffer.isEmpty {
                    // Data arrived between calls — return immediately.
                    cont.resume()
                    return
                }
                self.waitingReader = cont
                // Arm a timeout on the queue.
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 {
                    self.queue.asyncAfter(deadline: .now() + remaining) { [weak self] in
                        guard let self else { return }
                        if let w = self.waitingReader {
                            self.waitingReader = nil
                            w.resume(throwing: SMTPTransportError.timedOut(stage: "receive"))
                        }
                    }
                }
            }
        }
    }
}

/// Bound a connect operation by wall-clock timeout.
private func withConnectTimeout<T: Sendable>(
    timeout: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw SMTPTransportError.timedOut(stage: "connect")
        }
        guard let first = try await group.next() else {
            throw SMTPTransportError.timedOut(stage: "connect")
        }
        group.cancelAll()
        return first
    }
}

// MARK: - STARTTLS transport (plaintext → TLS upgrade on port 587)

// Secure Transport (SSLContext) I/O callbacks. Top-level functions with C-compatible
// signatures so they can be passed to `SSLSetIOFuncs`. The connection ref is a pointer
// to the socket file descriptor (see `STARTTLSTransport.doTLSHandshake`).

private func startTLSReadCallback(
    _ connection: SSLConnectionRef,
    _ data: UnsafeMutableRawPointer,
    _ dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fd = connection.assumingMemoryBound(to: Int32.self).pointee
    let requested = dataLength.pointee
    var read = 0
    while read < requested {
        let n = recv(fd, data.advanced(by: read), requested - read, 0)
        if n > 0 { read += n; continue }
        if n == 0 { dataLength.pointee = read; return errSSLClosedGraceful }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            dataLength.pointee = read
            return errSSLWouldBlock
        }
        dataLength.pointee = read
        return errSSLClosedAbort
    }
    dataLength.pointee = read
    return noErr
}

private func startTLSWriteCallback(
    _ connection: SSLConnectionRef,
    _ data: UnsafeRawPointer,
    _ dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fd = connection.assumingMemoryBound(to: Int32.self).pointee
    let total = dataLength.pointee
    var wrote = 0
    while wrote < total {
        let n = Darwin.send(fd, data.advanced(by: wrote), total - wrote, 0)
        if n > 0 { wrote += n; continue }
        if n == 0 { dataLength.pointee = wrote; return errSSLClosedAbort }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            dataLength.pointee = wrote
            return errSSLWouldBlock
        }
        dataLength.pointee = wrote
        return errSSLClosedAbort
    }
    dataLength.pointee = wrote
    return noErr
}

/// Plaintext-then-TLS SMTP transport for STARTTLS servers (typically port 587).
///
/// `Network.framework` has no `startTLS()` primitive — you cannot upgrade a live
/// `NWConnection` from plaintext to TLS — so this transport is backed by a POSIX
/// socket whose I/O path is swapped to Secure Transport (`SSLContext`) after the
/// STARTTLS command is accepted.
///
/// `init` performs the full pre-TLS dance (greeting → EHLO → STARTTLS → 220), then
/// upgrades the socket to TLS and seeds the read buffer with a synthetic `220`
/// greeting. That lets the standard `SMTPClient` conversation run unchanged: its
/// first read consumes the synthetic greeting, and its EHLO is the (required)
/// re-EHLO over the now-encrypted channel. See issue #62.
///
/// `@unchecked Sendable`: all mutable state is serialized through `queue`.
///
/// Concurrency note: I/O is blocking, serialized on a single dedicated
/// `DispatchQueue`. `receiveLine()` can hold that queue's thread in `recv()` for
/// up to `timeout` seconds, and `send()` serializes behind it. This is fine for
/// the intended single-shot, strictly-sequential SMTP conversation (one transport
/// per `smtp-send` invocation, its own private queue — never a shared pool). It
/// is NOT safe to reuse one instance for overlapping/concurrent sends.
public final class STARTTLSTransport: SMTPTransport, @unchecked Sendable {

    private let host: String
    private let port: Int
    private let timeout: TimeInterval
    private let insecureSkipVerify: Bool
    private let verbose: Bool
    private let logSink: SMTPLogSink

    private let queue: DispatchQueue
    private var fd: Int32 = -1
    private var fdPtr: UnsafeMutablePointer<Int32>?
    private var sslContext: SSLContext?
    private var tlsActive = false
    private var buffer = Data()
    private var closed = false

    public init(
        host: String,
        port: Int,
        ehloHostname: String,
        insecureSkipVerify: Bool = false,
        verbose: Bool = false,
        logSink: SMTPLogSink = StderrSink(),
        timeout: TimeInterval = 30
    ) async throws {
        self.host = host
        self.port = port
        self.timeout = timeout
        self.insecureSkipVerify = insecureSkipVerify
        self.verbose = verbose
        self.logSink = logSink
        self.queue = DispatchQueue(label: "apple-pim.starttls.\(UUID().uuidString.prefix(8))")

        try await connectPlaintext()
        // Pre-TLS SMTP exchange runs over `self` (plaintext socket I/O).
        try await negotiateSTARTTLS(over: self, ehloHostname: ehloHostname)
        try await upgradeToTLS()
        // Seed a synthetic greeting so SMTPClient.runConversation's first read (220) succeeds.
        queue.sync { buffer.append(Data("220 STARTTLS handshake complete\r\n".utf8)) }
        if verbose { logSink.log("S: 220 STARTTLS handshake complete (synthetic; TLS now active)") }
    }

    // MARK: SMTPTransport

    public func send(_ data: Data) async throws {
        if data.isEmpty { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.writeAll(data); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    public func receiveLine() async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queue.async {
                do { cont.resume(returning: try self.readLineBlocking()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    public func close() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if !self.closed {
                    self.closed = true
                    if let ctx = self.sslContext { SSLClose(ctx) }
                }
                if self.fd >= 0 { Darwin.close(self.fd); self.fd = -1 }
                self.fdPtr?.deallocate()
                self.fdPtr = nil
                self.sslContext = nil
                cont.resume()
            }
        }
    }

    // MARK: - Connect (plaintext)

    private func connectPlaintext() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.doConnect(); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func doConnect() throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var res: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(host, String(port), &hints, &res)
        guard gai == 0, let first = res else {
            throw SMTPTransportError.connectFailed(
                host: host, port: port,
                underlying: posixError("getaddrinfo failed (\(gai))"))
        }
        defer { freeaddrinfo(res) }

        var lastErr: Error = posixError("no usable address")
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let cur = node {
            let s = socket(cur.pointee.ai_family, cur.pointee.ai_socktype, cur.pointee.ai_protocol)
            if s >= 0 {
                if connectWithTimeout(s, cur.pointee.ai_addr, cur.pointee.ai_addrlen) {
                    configureSocket(s)
                    self.fd = s
                    return
                }
                lastErr = posixError("connect failed: \(String(cString: strerror(errno)))")
                Darwin.close(s)
            }
            node = cur.pointee.ai_next
        }
        throw SMTPTransportError.connectFailed(host: host, port: port, underlying: lastErr)
    }

    /// Non-blocking connect bounded by `timeout`, then restore blocking mode.
    private func connectWithTimeout(_ s: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ addrlen: socklen_t) -> Bool {
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(s, F_SETFL, flags) }

        let rc = connect(s, addr, addrlen)
        if rc == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(min(timeout, Double(Int32.max) / 1000) * 1000)
        let pr = poll(&pfd, 1, ms)
        guard pr > 0 else { return false }

        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(s, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0, soErr == 0 else {
            errno = soErr
            return false
        }
        return true
    }

    private func configureSocket(_ s: Int32) {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    // MARK: - TLS upgrade

    private func upgradeToTLS() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.doTLSHandshake(); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func doTLSHandshake() throws {
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw tlsError(errSecAllocate, stage: "create-context")
        }
        sslContext = ctx

        let holder = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        holder.pointee = fd
        fdPtr = holder

        var status = SSLSetIOFuncs(ctx, startTLSReadCallback, startTLSWriteCallback)
        guard status == noErr else { throw tlsError(status, stage: "set-io-funcs") }
        status = SSLSetConnection(ctx, holder)
        guard status == noErr else { throw tlsError(status, stage: "set-connection") }

        // SNI + hostname for certificate validation.
        host.withCString { ptr in
            _ = SSLSetPeerDomainName(ctx, ptr, strlen(ptr))
        }
        if insecureSkipVerify {
            // Defer trust evaluation to us, then accept unconditionally. This
            // disables MITM protection for a connection over which credentials
            // (AUTH LOGIN) are about to be sent — warn loudly and unconditionally,
            // regardless of verbose mode. Intended only for self-signed test relays.
            let warning = "WARNING: --tls-insecure-skip-verify is set — TLS certificate verification is DISABLED for \(host):\(port). "
                + "Credentials will be sent over an UNAUTHENTICATED channel vulnerable to man-in-the-middle. "
                + "Use only against trusted test servers.\n"
            FileHandle.standardError.write(Data(warning.utf8))
            SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            status = SSLHandshake(ctx)
            if status == noErr { break }
            // errSSLServerAuthCompleted is a C #define alias for errSSLPeerAuthCompleted
            // (not visible to Swift) — use the canonical name.
            if status == errSSLPeerAuthCompleted && insecureSkipVerify {
                continue  // skip verification, resume handshake
            }
            if status == errSSLWouldBlock {
                if Date() > deadline { throw SMTPTransportError.timedOut(stage: "tls-handshake") }
                continue
            }
            throw tlsError(status, stage: "handshake")
        }
        tlsActive = true
    }

    // MARK: - Blocking I/O (runs on `queue`)

    private func writeAll(_ data: Data) throws {
        if closed { throw SMTPTransportError.connectionClosed }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var total = 0
            while total < data.count {
                if tlsActive, let ctx = sslContext {
                    var processed = 0
                    let status = SSLWrite(ctx, base.advanced(by: total), data.count - total, &processed)
                    total += processed
                    if status == noErr { continue }
                    if status == errSSLWouldBlock { throw SMTPTransportError.timedOut(stage: "send") }
                    throw tlsError(status, stage: "write")
                } else {
                    let n = Darwin.send(fd, base.advanced(by: total), data.count - total, 0)
                    if n > 0 { total += n; continue }
                    if n < 0 && errno == EINTR { continue }
                    if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                        throw SMTPTransportError.timedOut(stage: "send")
                    }
                    throw SMTPTransportError.sendFailed(posixError("send: \(String(cString: strerror(errno)))"))
                }
            }
        }
    }

    private func readLineBlocking() throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let line = try takeLineFromBuffer() { return line }
            if closed {
                if buffer.isEmpty { throw SMTPTransportError.connectionClosed }
            }
            if Date() > deadline { throw SMTPTransportError.timedOut(stage: "receiveLine") }
            try readMore()
        }
    }

    private func takeLineFromBuffer() throws -> String? {
        guard let range = buffer.range(of: Data("\r\n".utf8)) else {
            if closed && buffer.isEmpty { throw SMTPTransportError.connectionClosed }
            return nil
        }
        let lineData = buffer.subdata(in: 0..<range.lowerBound)
        buffer.removeSubrange(0..<range.upperBound)
        guard let s = String(data: lineData, encoding: .utf8) else {
            throw SMTPTransportError.invalidResponse("non-UTF8 SMTP reply")
        }
        return s
    }

    private func readMore() throws {
        var chunk = [UInt8](repeating: 0, count: 8192)
        let count: Int = try chunk.withUnsafeMutableBytes { rawBuf in
            let base = rawBuf.baseAddress!
            if tlsActive, let ctx = sslContext {
                var processed = 0
                let status = SSLRead(ctx, base, 8192, &processed)
                if status == errSSLClosedGraceful || status == errSSLClosedNoNotify {
                    closed = true
                    return processed
                }
                if status == errSSLWouldBlock {
                    if processed > 0 { return processed }
                    throw SMTPTransportError.timedOut(stage: "receive")
                }
                if status != noErr && processed == 0 {
                    throw tlsError(status, stage: "read")
                }
                return processed
            } else {
                let r = recv(fd, base, 8192, 0)
                if r == 0 { closed = true; return 0 }
                if r < 0 {
                    if errno == EINTR { return 0 }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw SMTPTransportError.timedOut(stage: "receive")
                    }
                    throw SMTPTransportError.connectionClosed
                }
                return r
            }
        }
        if count > 0 { buffer.append(contentsOf: chunk[0..<count]) }
    }

    // MARK: - Errors

    private func posixError(_ msg: String) -> Error {
        NSError(domain: "STARTTLSTransport", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func tlsError(_ status: OSStatus, stage: String) -> Error {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "TLS \(stage) failed (OSStatus \(status))"])
    }
}

// MARK: - Fake transport for unit tests

/// Test double that scripts both sides of an SMTP conversation.
/// Construct with a list of `Script.Step` values; each `.expectSend` asserts on the
/// next client write, each `.reply` emits server lines for the next `receiveLine`.
public final class FakeTransport: SMTPTransport, @unchecked Sendable {
    public enum Step: Sendable {
        /// The next `send(_:)` call is expected to write a string that satisfies this predicate.
        case expectSend(@Sendable (String) -> Bool, label: String)
        /// `receiveLine()` returns these lines in order (no CRLF included).
        case reply(lines: [String])
        /// The client should have closed by this point.
        case expectClose
    }

    public private(set) var sentPayloads: [Data] = []
    public private(set) var closed = false

    private var script: [Step]
    private var pendingReplyLines: [String] = []

    public init(_ script: [Step]) {
        self.script = script
    }

    public func send(_ data: Data) async throws {
        sentPayloads.append(data)
        guard !script.isEmpty else {
            throw SMTPTransportError.invalidResponse("FakeTransport: unexpected send (script exhausted)")
        }
        let step = script.removeFirst()
        guard case let .expectSend(predicate, label) = step else {
            throw SMTPTransportError.invalidResponse(
                "FakeTransport: expected reply/close, got send of \(data.count) bytes (next step: \(step))"
            )
        }
        let s = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        if !predicate(s) {
            throw SMTPTransportError.invalidResponse(
                "FakeTransport: send predicate '\(label)' failed for payload: \(s)"
            )
        }
    }

    public func receiveLine() async throws -> String {
        if pendingReplyLines.isEmpty {
            guard !script.isEmpty else {
                throw SMTPTransportError.connectionClosed
            }
            let step = script.removeFirst()
            guard case let .reply(lines) = step else {
                throw SMTPTransportError.invalidResponse("FakeTransport: expected reply, got \(step)")
            }
            pendingReplyLines = lines
        }
        return pendingReplyLines.removeFirst()
    }

    public func close() async {
        closed = true
        if let step = script.first, case .expectClose = step {
            script.removeFirst()
        }
    }

    /// Assert the script ran to completion.
    public func verifyComplete() throws {
        guard script.isEmpty else {
            throw SMTPTransportError.invalidResponse(
                "FakeTransport: \(script.count) scripted step(s) unused"
            )
        }
    }
}
