import Foundation

/// A single email attachment: filename, MIME type, and raw bytes.
public struct Attachment: Sendable {
    public let filename: String
    public let contentType: String
    public let data: Data

    public init(filename: String, contentType: String = "application/octet-stream", data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

/// Errors produced while rendering a MIME message.
public enum MIMEError: Error, CustomStringConvertible {
    case missingBody
    case emptyRecipients
    case invalidFromAddress(String)
    case boundaryCollision

    public var description: String {
        switch self {
        case .missingBody: return "message must have at least one of .text or .html"
        case .emptyRecipients: return "message must have at least one To recipient"
        case .invalidFromAddress(let s): return "From address could not be parsed: \(s)"
        case .boundaryCollision: return "generated MIME boundary appeared in message content (retry)"
        }
    }
}

/// An RFC 5322 email message with MIME body. Pure value type — `render()` has no
/// side effects and is safe to call from any context.
///
/// Design decisions:
/// - **Base64 for attachments**, **quoted-printable for text/* bodies**, **RFC 2047
///   encoded-word (base64 variant)** for non-ASCII header values. This combination
///   keeps text parts human-readable in raw source while staying safe for all
///   8-bit-unclean relays.
/// - **Bcc recipients are intentionally not serialized into headers.** They go only
///   into `RCPT TO` at the SMTP layer (see `allRecipients`).
/// - **CRLF everywhere.** Any bare LF in user input is normalized to CRLF before
///   encoding.
/// - **Boundary strings** are `=_Part_<uuid>`. Before emitting the final body we
///   verify the boundary does not appear as a substring in any encoded part; if
///   it does we re-generate (see `boundaryFactory`).
public struct MIMEMessage: Sendable {
    public var from: String
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var text: String?
    public var html: String?
    public var attachments: [Attachment]
    public var messageID: String?
    public var date: Date

    /// When `true` (default) and the message has `html` but no `text`, a plain-text
    /// fallback is synthesized from the HTML so the message is emitted as
    /// `multipart/alternative` rather than a single `text/html` part. Set to `false`
    /// to preserve the legacy single-part `text/html` shape.
    public var autoDeriveTextFallback: Bool = true

    // Injection points for deterministic tests. Never surfaced via the public init.
    var boundaryFactory: @Sendable () -> String = { "=_Part_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))" }
    var messageIDFactory: @Sendable (_ domain: String) -> String = { domain in "<\(UUID().uuidString)@\(domain)>" }

    public init(
        from: String,
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        text: String? = nil,
        html: String? = nil,
        attachments: [Attachment] = [],
        messageID: String? = nil,
        date: Date = Date(),
        autoDeriveTextFallback: Bool = true
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.html = html
        self.attachments = attachments
        self.messageID = messageID
        self.date = date
        self.autoDeriveTextFallback = autoDeriveTextFallback
    }

    /// All recipients (To + Cc + Bcc) for the SMTP `RCPT TO` phase.
    /// Bcc is included here but NOT in `.render()` output.
    public func allRecipients() -> [String] {
        to + cc + bcc
    }

    /// Render the message as RFC 5322 bytes (CRLF line endings, dot-stuffing NOT applied —
    /// the SMTP client adds that at the DATA phase).
    public func render() throws -> Data {
        guard !to.isEmpty else { throw MIMEError.emptyRecipients }
        guard text != nil || html != nil else { throw MIMEError.missingBody }

        let fromDomain = try Self.extractDomain(from: from)
        let resolvedMessageID = messageID ?? messageIDFactory(fromDomain)

        // Build the body first so we can detect boundary collisions before we commit.
        let (bodyHeaders, bodyBytes) = try buildBody()

        // Assemble top-level headers.
        var headers: [(String, String)] = []
        headers.append(("From", from))
        headers.append(("To", to.joined(separator: ", ")))
        if !cc.isEmpty { headers.append(("Cc", cc.joined(separator: ", "))) }
        headers.append(("Subject", subject))
        headers.append(("Date", Self.formatRFC5322Date(date)))
        headers.append(("Message-ID", resolvedMessageID))
        headers.append(("MIME-Version", "1.0"))
        for (name, value) in bodyHeaders {
            headers.append((name, value))
        }

        var output = Data()
        for (name, value) in headers {
            output.append(Self.encodeHeader(name: name, value: value))
        }
        output.append(Self.crlf)
        output.append(bodyBytes)
        return output
    }

    // MARK: - Body construction

    /// The plain-text content to use for rendering. When the caller supplied no
    /// `text` but did supply `html` and `autoDeriveTextFallback` is on, a fallback
    /// is synthesized from the HTML (see `htmlToPlainText`). Otherwise this is the
    /// caller's `text` verbatim (possibly nil).
    private var effectiveText: String? {
        if let t = text { return t }
        if let h = html, autoDeriveTextFallback { return Self.htmlToPlainText(h) }
        return nil
    }

    /// Returns (top-level Content-Type + CTE headers, body bytes).
    private func buildBody() throws -> ([(String, String)], Data) {
        // Resolve the plain-text part once (may be derived from HTML).
        let plainText = effectiveText

        // Case 1: attachments present → multipart/mixed wrapping either a single
        // content part or a multipart/alternative sub-part.
        //
        // Allocate the OUTER boundary first so the factory is called in
        // lexical order (outer, then inner via renderAlternative()). This is
        // visible to tests that inject a deterministic factory and matters
        // only for that — protocol-wise either order is fine.
        if !attachments.isEmpty {
            var boundary = boundaryFactory()
            let contentPart: Data = try {
                if plainText != nil && html != nil {
                    // Nested multipart/alternative for the content side.
                    return try renderAlternative(text: plainText!, html: html!)
                } else if let t = plainText {
                    return renderTextPart(t, subtype: "plain")
                } else if let h = html {
                    return renderTextPart(h, subtype: "html")
                } else {
                    throw MIMEError.missingBody
                }
            }()

            // Collision check: if the outer boundary appears in any attached
            // content or in the inner multipart, regenerate up to a few times.
            var attempts = 0
            while Self.boundaryCollides(boundary, with: contentPart)
                    || attachments.contains(where: { Self.boundaryCollides(boundary, with: $0.data) })
                    || Self.boundaryCollides(boundary, with: Data(subject.utf8)) {
                attempts += 1
                if attempts >= 4 { throw MIMEError.boundaryCollision }
                boundary = boundaryFactory()
            }

            var body = Data()
            // First part: the content (already formatted if multipart/alternative, else wrap).
            // When both text and html exist, contentPart is a complete multipart/alternative
            // section (its own Content-Type line + sub-parts); otherwise it's a single part.
            body.append(Self.boundaryLine(boundary))
            body.append(contentPart)
            // Attachment parts.
            for att in attachments {
                body.append(Self.crlf)
                body.append(Self.boundaryLine(boundary))
                body.append(renderAttachmentPart(att))
            }
            body.append(Self.crlf)
            body.append(Self.finalBoundaryLine(boundary))

            return (
                [
                    ("Content-Type", "multipart/mixed; boundary=\"\(boundary)\""),
                ],
                body
            )
        }

        // Case 2: text + html with no attachments → multipart/alternative at the top level.
        if let t = plainText, let h = html {
            var boundary = boundaryFactory()
            let textData = Data(Self.normalizeLineEndings(t).utf8)
            let htmlData = Data(Self.normalizeLineEndings(h).utf8)
            var attempts = 0
            while Self.boundaryCollides(boundary, with: textData)
                    || Self.boundaryCollides(boundary, with: htmlData) {
                attempts += 1
                if attempts >= 4 { throw MIMEError.boundaryCollision }
                boundary = boundaryFactory()
            }

            var body = Data()
            body.append(Self.boundaryLine(boundary))
            body.append(renderTextPart(t, subtype: "plain"))
            body.append(Self.crlf)
            body.append(Self.boundaryLine(boundary))
            body.append(renderTextPart(h, subtype: "html"))
            body.append(Self.crlf)
            body.append(Self.finalBoundaryLine(boundary))

            return (
                [("Content-Type", "multipart/alternative; boundary=\"\(boundary)\"")],
                body
            )
        }

        // Case 3: single part (text OR html). HTML reaches here only when
        // autoDeriveTextFallback is off (otherwise plainText is non-nil → Case 2).
        if let t = plainText {
            let bodyBytes = renderTextPartPayload(t)
            return (
                [
                    ("Content-Type", "text/plain; charset=utf-8"),
                    ("Content-Transfer-Encoding", "quoted-printable"),
                ],
                bodyBytes
            )
        }
        if let h = html {
            let bodyBytes = renderTextPartPayload(h)
            return (
                [
                    ("Content-Type", "text/html; charset=utf-8"),
                    ("Content-Transfer-Encoding", "quoted-printable"),
                ],
                bodyBytes
            )
        }
        throw MIMEError.missingBody
    }

    /// Build a complete multipart/alternative section (part headers + both sub-parts +
    /// closing boundary) as used inside a multipart/mixed wrapper.
    private func renderAlternative(text: String, html: String) throws -> Data {
        var innerBoundary = boundaryFactory()
        let textData = Data(Self.normalizeLineEndings(text).utf8)
        let htmlData = Data(Self.normalizeLineEndings(html).utf8)
        var attempts = 0
        while Self.boundaryCollides(innerBoundary, with: textData)
                || Self.boundaryCollides(innerBoundary, with: htmlData) {
            attempts += 1
            if attempts >= 4 { throw MIMEError.boundaryCollision }
            innerBoundary = boundaryFactory()
        }

        var out = Data()
        out.append(Self.headerLine("Content-Type", "multipart/alternative; boundary=\"\(innerBoundary)\""))
        out.append(Self.crlf)
        out.append(Self.boundaryLine(innerBoundary))
        out.append(renderTextPart(text, subtype: "plain"))
        out.append(Self.crlf)
        out.append(Self.boundaryLine(innerBoundary))
        out.append(renderTextPart(html, subtype: "html"))
        out.append(Self.crlf)
        out.append(Self.finalBoundaryLine(innerBoundary))
        return out
    }

    /// Returns the bytes of a single text/* sub-part (headers + blank + QP body).
    private func renderTextPart(_ content: String, subtype: String) -> Data {
        var out = Data()
        out.append(Self.headerLine("Content-Type", "text/\(subtype); charset=utf-8"))
        out.append(Self.headerLine("Content-Transfer-Encoding", "quoted-printable"))
        out.append(Self.crlf)
        out.append(renderTextPartPayload(content))
        return out
    }

    /// QP-encoded body with CRLF line endings, no trailing CRLF.
    private func renderTextPartPayload(_ content: String) -> Data {
        let normalized = Self.normalizeLineEndings(content)
        return Data(Self.quotedPrintable(normalized).utf8)
    }

    /// Returns the bytes of a single attachment sub-part (headers + blank + base64 body).
    private func renderAttachmentPart(_ att: Attachment) -> Data {
        var out = Data()
        let quotedName = Self.quoteHeaderParameter(att.filename)
        out.append(Self.headerLine("Content-Type", "\(att.contentType); name=\(quotedName)"))
        out.append(Self.headerLine("Content-Disposition", "attachment; filename=\(quotedName)"))
        out.append(Self.headerLine("Content-Transfer-Encoding", "base64"))
        out.append(Self.crlf)
        out.append(Self.base64Wrapped(att.data))
        return out
    }

    // MARK: - Line / header / encoding helpers

    static let crlf = Data("\r\n".utf8)

    static func headerLine(_ name: String, _ value: String) -> Data {
        var d = Data("\(name): \(value)".utf8)
        d.append(crlf)
        return d
    }

    /// Produce `name: value\r\n` with:
    /// - RFC 2047 encoded-word encoding when `value` is non-ASCII (or contains control bytes)
    /// - Line folding after 78 chars at whitespace boundaries
    static func encodeHeader(name: String, value: String) -> Data {
        let encodedValue: String
        if value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 && $0.value != 127 }) {
            encodedValue = value
        } else {
            encodedValue = encodeHeaderWords(value)
        }
        let raw = "\(name): \(encodedValue)"
        let folded = foldHeader(raw)
        var d = Data(folded.utf8)
        d.append(crlf)
        return d
    }

    /// Fold long header lines at whitespace to stay under 78 chars per physical line.
    /// Continuation lines start with a single space per RFC 5322.
    static func foldHeader(_ line: String) -> String {
        let maxLen = 78
        if line.count <= maxLen { return line }

        var result: [String] = []
        var current = ""
        for word in line.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            if current.isEmpty {
                current = word
                continue
            }
            if current.count + 1 + word.count > maxLen {
                result.append(current)
                current = word
            } else {
                current += " " + word
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.joined(separator: "\r\n ")
    }

    /// RFC 2047 "encoded-word" encoding using base64 (B-encoding).
    /// Splits into multiple encoded-words when UTF-8 payload exceeds the 75-octet limit.
    static func encodeHeaderWords(_ value: String) -> String {
        // Each encoded-word is `=?UTF-8?B?<base64>?=` with a 75-octet total cap.
        // Overhead: `=?UTF-8?B??=` = 12 octets. Payload base64 limit = 75 - 12 = 63 octets,
        // which corresponds to (63 / 4) * 3 = 47 bytes of UTF-8 per word (rounded down, and
        // we must respect UTF-8 codepoint boundaries).
        let maxUTF8PerWord = 45  // conservative — gives multi-byte codepoints headroom
        let bytes = Array(value.utf8)

        var words: [String] = []
        var i = 0
        while i < bytes.count {
            var chunkLen = min(maxUTF8PerWord, bytes.count - i)
            // Back up to the last complete UTF-8 codepoint boundary.
            while chunkLen > 0 && (bytes[i + chunkLen - 1] & 0b11000000) == 0b10000000 {
                chunkLen -= 1
            }
            if chunkLen == 0 { chunkLen = min(maxUTF8PerWord, bytes.count - i) }  // safety
            let chunk = Data(bytes[i..<(i + chunkLen)])
            let b64 = chunk.base64EncodedString()
            words.append("=?UTF-8?B?\(b64)?=")
            i += chunkLen
        }
        return words.joined(separator: " ")
    }

    /// Quoted-printable encoding per RFC 2045 §6.7.
    /// - Normalizes line endings to CRLF (caller should do this too, but idempotent).
    /// - Encodes `=` as `=3D`, bytes outside `[ !-<>-~]` as `=HH`, and trailing whitespace.
    /// - Soft-wraps at 76 chars with `=` + CRLF.
    static func quotedPrintable(_ input: String) -> String {
        let crlf = "\r\n"
        var lines: [String] = []
        for line in input.components(separatedBy: crlf) {
            lines.append(qpEncodeLine(line))
        }
        return lines.joined(separator: crlf)
    }

    /// Encode one logical line. Handles soft line breaks internally.
    private static func qpEncodeLine(_ line: String) -> String {
        let maxLineLen = 76
        var out = ""
        var current = ""

        func flushSoftBreak() {
            out += current + "=\r\n"
            current = ""
        }

        let bytes = Array(line.utf8)
        for (idx, b) in bytes.enumerated() {
            let needsEncode: Bool
            if b == 0x3D {  // '=' always encoded
                needsEncode = true
            } else if b == 0x09 || b == 0x20 {  // tab/space: encode only if trailing
                needsEncode = (idx == bytes.count - 1)
            } else if b >= 0x21 && b <= 0x7E {  // printable ASCII except '='
                needsEncode = false
            } else {
                needsEncode = true
            }

            let token: String
            if needsEncode {
                token = String(format: "=%02X", b)
            } else {
                token = String(UnicodeScalar(b))
            }

            // Ensure room for this token + potential `=` soft-break marker.
            // Keep 1 char in reserve so a soft-break placement doesn't overflow.
            if current.count + token.count > maxLineLen - 1 {
                flushSoftBreak()
            }
            current += token
        }
        out += current
        return out
    }

    /// Quote a header parameter value if it contains special characters (RFC 2045 tspecials).
    /// Always returns the value wrapped in double quotes when it's anything other than a pure token.
    static func quoteHeaderParameter(_ value: String) -> String {
        // Escape backslashes and quotes, then wrap in quotes. Non-ASCII filenames will
        // appear as-is; modern clients handle UTF-8 in quoted strings fine. Strict RFC
        // 2231 encoding is out of scope for v1.
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Base64-encode `data` wrapped at 76 chars per line with CRLF separators.
    static func base64Wrapped(_ data: Data) -> Data {
        let full = data.base64EncodedString()
        var out = ""
        var i = full.startIndex
        while i < full.endIndex {
            let j = full.index(i, offsetBy: 76, limitedBy: full.endIndex) ?? full.endIndex
            out += full[i..<j]
            out += "\r\n"
            i = j
        }
        return Data(out.utf8)
    }

    static func boundaryLine(_ boundary: String) -> Data {
        Data("--\(boundary)\r\n".utf8)
    }

    static func finalBoundaryLine(_ boundary: String) -> Data {
        Data("--\(boundary)--\r\n".utf8)
    }

    static func boundaryCollides(_ boundary: String, with data: Data) -> Bool {
        guard let needle = "--\(boundary)".data(using: .utf8) else { return false }
        return data.range(of: needle) != nil
    }

    /// Normalize `\r`, `\n`, and mixed line endings to CRLF.
    /// Empty-line and trailing-newline handling: preserves count/position, only normalizes.
    static func normalizeLineEndings(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\r" {
                out.append("\r\n")
                if i + 1 < scalars.count && scalars[i + 1] == "\n" { i += 2 } else { i += 1 }
            } else if c == "\n" {
                out.append("\r\n")
                i += 1
            } else {
                out.unicodeScalars.append(c)
                i += 1
            }
        }
        return out
    }

    // MARK: - HTML → plain-text fallback

    /// Derive a plain-text fallback from an HTML body. Deterministic, no DOM (see issue #61).
    ///
    /// Rules:
    /// - `<script>` / `<style>` blocks (and their contents) are dropped entirely.
    /// - Block-closing tags (`</p>`, `</div>`, `</tr>`, `</li>`, `</h1>`–`</h6>`) → newline.
    /// - `<br>` / `<br/>` / `<br />` → newline.
    /// - All other tags are stripped.
    /// - HTML entities (named + numeric) are decoded.
    /// - Horizontal whitespace runs collapse to one space; 3+ blank lines collapse to two.
    /// - Leading/trailing whitespace is trimmed.
    ///
    /// This is intentionally NOT a "pretty" converter (no link/blockquote/alignment
    /// preservation) — just a reasonable, readable text alternative.
    static func htmlToPlainText(_ html: String) -> String {
        var s = html

        // 1. Remove <script>…</script> and <style>…</style> including their contents.
        s = replaceRegex(s, pattern: "<(script|style)\\b[^>]*>[\\s\\S]*?</\\1\\s*>", with: "", dotAll: true)

        // 2. <br> variants → newline.
        s = replaceRegex(s, pattern: "<br\\s*/?>", with: "\n")

        // 3. Block-closing tags → newline.
        s = replaceRegex(s, pattern: "</(p|div|tr|li|h[1-6])\\s*>", with: "\n")

        // 4. Strip all remaining tags.
        s = replaceRegex(s, pattern: "<[^>]+>", with: "")

        // 5. Decode HTML entities.
        s = decodeHTMLEntities(s)

        // 6. Collapse horizontal whitespace, tidy newlines.
        s = replaceRegex(s, pattern: "[ \\t\\x0B\\f\\r]+", with: " ", caseInsensitive: false)
        s = replaceRegex(s, pattern: " *\\n *", with: "\n", caseInsensitive: false)
        s = replaceRegex(s, pattern: "\\n{3,}", with: "\n\n", caseInsensitive: false)

        // 7. Trim.
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// NSRegularExpression-backed replace. Returns the input unchanged if the pattern
    /// fails to compile (defensive — patterns here are all literals).
    static func replaceRegex(
        _ s: String,
        pattern: String,
        with template: String,
        caseInsensitive: Bool = true,
        dotAll: Bool = false
    ) -> String {
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        if dotAll { opts.insert(.dotMatchesLineSeparators) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        // `template` is passed through verbatim — callers here use literal characters
        // (real newline / space / empty), never `$`/`\` backreference syntax.
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }

    /// Decode the common named HTML entities plus numeric (`&#NN;` / `&#xHH;`) forms.
    /// Unrecognized entities are left verbatim.
    static func decodeHTMLEntities(_ s: String) -> String {
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": " ", "mdash": "—", "ndash": "–", "hellip": "…",
            "copy": "©", "reg": "®", "trade": "™",
            "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        ]
        var result = ""
        result.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&",
               let semi = s[i...].firstIndex(of: ";"),
               s.distance(from: i, to: semi) <= 32 {
                let entity = String(s[s.index(after: i)..<semi])
                if entity.hasPrefix("#") {
                    let numStr = entity.dropFirst()
                    let scalarVal: UInt32? = (numStr.first == "x" || numStr.first == "X")
                        ? UInt32(numStr.dropFirst(), radix: 16)
                        : UInt32(numStr, radix: 10)
                    if let v = scalarVal, let scalar = Unicode.Scalar(v) {
                        result.unicodeScalars.append(scalar)
                        i = s.index(after: semi)
                        continue
                    }
                } else if let rep = named[entity] {
                    result += rep
                    i = s.index(after: semi)
                    continue
                }
            }
            result.append(c)
            i = s.index(after: i)
        }
        return result
    }

    // MARK: - Address + date helpers

    /// Pull the domain out of a raw From value (e.g. `"Name <foo@bar.com>"` → `"bar.com"`).
    static func extractDomain(from raw: String) throws -> String {
        if let at = raw.lastIndex(of: "@") {
            let tail = raw[raw.index(after: at)...]
            // Strip trailing `>` if present (common in display-name form).
            let trimmed = tail.trimmingCharacters(in: CharacterSet(charactersIn: ">"))
            if !trimmed.isEmpty { return String(trimmed) }
        }
        throw MIMEError.invalidFromAddress(raw)
    }

    /// RFC 5322 date: `Fri, 17 Apr 2026 12:34:56 -0700`.
    static func formatRFC5322Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }
}
