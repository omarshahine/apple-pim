import Foundation

// Minimal .emlx reader for the SQLite fast path. An .emlx file is:
//   <byte count>\n<RFC 822 message bytes><XML plist trailer>
// We parse headers plus enough MIME to extract a plain-text body (preferring
// text/plain, falling back to tag-stripped text/html), matching what JXA's
// msg.content() returns closely enough for agent use.

struct EmlxMessage {
    let rawHeaders: String
    let headers: [(name: String, value: String)]
    /// Best-effort plain-text body.
    let content: String

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

enum EmlxError: Error, LocalizedError {
    case unreadable(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let msg): return msg
        case .malformed(let msg): return msg
        }
    }
}

func readEmlx(at url: URL) throws -> EmlxMessage {
    guard let data = try? Data(contentsOf: url) else {
        throw EmlxError.unreadable("Cannot read \(url.path)")
    }
    return try parseEmlx(data: data)
}

func parseEmlx(data: Data) throws -> EmlxMessage {
    // First line is the byte count of the RFC 822 payload.
    guard let newline = data.firstIndex(of: 0x0A) else {
        throw EmlxError.malformed("Missing byte-count line")
    }
    guard let countString = String(data: data[data.startIndex..<newline], encoding: .utf8),
          let byteCount = Int(countString.trimmingCharacters(in: .whitespaces)), byteCount > 0 else {
        throw EmlxError.malformed("Invalid byte-count line")
    }
    let messageStart = data.index(after: newline)
    let messageEnd = min(data.index(messageStart, offsetBy: byteCount, limitedBy: data.endIndex) ?? data.endIndex,
                         data.endIndex)
    return parseRFC822(data: Data(data[messageStart..<messageEnd]))
}

func parseRFC822(data: Data) -> EmlxMessage {
    let (headerData, bodyData) = splitHeadersAndBody(data)
    let rawHeaders = decodeText(headerData, charset: "utf-8")
    let headers = parseHeaderBlock(rawHeaders)
    let contentType = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? "text/plain"
    let encoding = headers.first { $0.name.caseInsensitiveCompare("Content-Transfer-Encoding") == .orderedSame }?.value ?? ""
    let body = extractBody(bodyData, contentType: contentType, transferEncoding: encoding)
    return EmlxMessage(rawHeaders: rawHeaders, headers: headers, content: body)
}

// MARK: - Header parsing

func splitHeadersAndBody(_ data: Data) -> (headers: Data, body: Data) {
    let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
    let lflf = Data([0x0A, 0x0A])
    if let range = data.range(of: crlfcrlf) {
        return (data.subdata(in: data.startIndex..<range.lowerBound),
                data.subdata(in: range.upperBound..<data.endIndex))
    }
    if let range = data.range(of: lflf) {
        return (data.subdata(in: data.startIndex..<range.lowerBound),
                data.subdata(in: range.upperBound..<data.endIndex))
    }
    return (data, Data())
}

/// Unfold and split a raw header block into (name, value) pairs.
func parseHeaderBlock(_ raw: String) -> [(name: String, value: String)] {
    var result: [(name: String, value: String)] = []
    let unfolded = raw
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\n ", with: " ")
        .replacingOccurrences(of: "\n\t", with: " ")
    for line in unfolded.components(separatedBy: "\n") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { continue }
        result.append((name: name, value: value))
    }
    return result
}

/// Extract a parameter (e.g. boundary, charset) from a header value.
func mimeParameter(_ headerValue: String, _ name: String) -> String? {
    let lower = headerValue.lowercased()
    guard let paramRange = lower.range(of: "\(name.lowercased())=") else { return nil }
    var rest = String(headerValue[paramRange.upperBound...])
    if rest.hasPrefix("\"") {
        rest.removeFirst()
        return String(rest.prefix(while: { $0 != "\"" }))
    }
    return String(rest.prefix(while: { $0 != ";" && !$0.isWhitespace }))
}

// MARK: - Body extraction

private func extractBody(_ data: Data, contentType: String, transferEncoding: String) -> String {
    let lowerType = contentType.lowercased()

    if lowerType.hasPrefix("multipart/"), let boundary = mimeParameter(contentType, "boundary") {
        let parts = splitMultipart(data, boundary: boundary)
        // Prefer text/plain anywhere in the tree; fall back to stripped text/html.
        if let plain = findPart(in: parts, matching: "text/plain") {
            return plain
        }
        if let html = findPart(in: parts, matching: "text/html") {
            return stripHTMLTags(html)
        }
        return ""
    }

    let charset = mimeParameter(contentType, "charset") ?? "utf-8"
    let decoded = decodeTransferEncoding(data, encoding: transferEncoding)
    let text = decodeText(decoded, charset: charset)
    if lowerType.hasPrefix("text/html") {
        return stripHTMLTags(text)
    }
    return text
}

private func findPart(in parts: [Data], matching type: String) -> String? {
    for part in parts {
        let (headerData, bodyData) = splitHeadersAndBody(part)
        let headers = parseHeaderBlock(decodeText(headerData, charset: "utf-8"))
        let contentType = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? "text/plain"
        let lowerType = contentType.lowercased()
        // Skip attachments even if they claim a text type.
        let disposition = headers.first { $0.name.caseInsensitiveCompare("Content-Disposition") == .orderedSame }?.value ?? ""
        if disposition.lowercased().hasPrefix("attachment") { continue }

        if lowerType.hasPrefix("multipart/"), let boundary = mimeParameter(contentType, "boundary") {
            if let nested = findPart(in: splitMultipart(bodyData, boundary: boundary), matching: type) {
                return nested
            }
            continue
        }
        guard lowerType.hasPrefix(type) else { continue }
        let encoding = headers.first { $0.name.caseInsensitiveCompare("Content-Transfer-Encoding") == .orderedSame }?.value ?? ""
        let charset = mimeParameter(contentType, "charset") ?? "utf-8"
        return decodeText(decodeTransferEncoding(bodyData, encoding: encoding), charset: charset)
    }
    return nil
}

func splitMultipart(_ data: Data, boundary: String) -> [Data] {
    guard let delimiter = "--\(boundary)".data(using: .utf8) else { return [] }
    var parts: [Data] = []
    var searchStart = data.startIndex
    var previousPartStart: Data.Index?
    while let range = data.range(of: delimiter, in: searchStart..<data.endIndex) {
        if let partStart = previousPartStart {
            parts.append(trimPartData(data.subdata(in: partStart..<range.lowerBound)))
        }
        // Move past the delimiter line (skip trailing -- or CRLF).
        var cursor = range.upperBound
        while cursor < data.endIndex, data[cursor] == 0x2D { cursor = data.index(after: cursor) } // '-'
        while cursor < data.endIndex, data[cursor] == 0x0D || data[cursor] == 0x0A {
            cursor = data.index(after: cursor)
            if data[data.index(before: cursor)] == 0x0A { break }
        }
        previousPartStart = cursor
        searchStart = cursor
        if cursor >= data.endIndex { break }
    }
    return parts
}

private func trimPartData(_ data: Data) -> Data {
    var end = data.endIndex
    while end > data.startIndex {
        let prev = data.index(before: end)
        if data[prev] == 0x0D || data[prev] == 0x0A { end = prev } else { break }
    }
    return data.subdata(in: data.startIndex..<end)
}

// MARK: - Decoding

func decodeTransferEncoding(_ data: Data, encoding: String) -> Data {
    switch encoding.trimmingCharacters(in: .whitespaces).lowercased() {
    case "base64":
        let compact = String(data: data, encoding: .ascii)?
            .components(separatedBy: .whitespacesAndNewlines).joined() ?? ""
        return Data(base64Encoded: compact) ?? data
    case "quoted-printable":
        return decodeQuotedPrintable(data)
    default:
        return data
    }
}

func decodeQuotedPrintable(_ data: Data) -> Data {
    var out = Data(capacity: data.count)
    var i = data.startIndex
    func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
    while i < data.endIndex {
        let byte = data[i]
        if byte == 0x3D { // '='
            let next = data.index(after: i)
            // Soft line break: =\r\n or =\n
            if next < data.endIndex, data[next] == 0x0D || data[next] == 0x0A {
                i = data.index(after: next)
                if i < data.endIndex, data[data.index(before: i)] == 0x0D, data[i] == 0x0A {
                    i = data.index(after: i)
                }
                continue
            }
            let second = next < data.endIndex ? data.index(after: next) : data.endIndex
            if next < data.endIndex, second < data.endIndex,
               let hi = hexValue(data[next]), let lo = hexValue(data[second]) {
                out.append(hi << 4 | lo)
                i = data.index(after: second)
                continue
            }
        }
        out.append(byte)
        i = data.index(after: i)
    }
    return out
}

func decodeText(_ data: Data, charset: String) -> String {
    let encoding: String.Encoding
    switch charset.lowercased() {
    case "utf-8", "utf8", "us-ascii", "ascii": encoding = .utf8
    case "iso-8859-1", "latin1": encoding = .isoLatin1
    case "windows-1252", "cp1252": encoding = .windowsCP1252
    case "utf-16": encoding = .utf16
    default: encoding = .utf8
    }
    if let text = String(data: data, encoding: encoding) { return text }
    // Lossy fallback so a bad charset never fails the whole read.
    return String(decoding: data, as: UTF8.self)
}

/// Crude HTML-to-text for the no-text/plain fallback.
func stripHTMLTags(_ html: String) -> String {
    var text = html
    // Drop style/script blocks entirely.
    for tag in ["style", "script", "head"] {
        while let open = text.range(of: "<\(tag)", options: .caseInsensitive),
              let close = text.range(of: "</\(tag)>", options: .caseInsensitive,
                                     range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
    }
    text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
    for (entity, replacement) in entities {
        text = text.replacingOccurrences(of: entity, with: replacement)
    }
    // Collapse runs of blank lines.
    text = text.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}
