import Foundation

// Pure helpers for the Envelope Index SQLite read path. No I/O here so
// everything is unit-testable without a live database (mirrors ScriptHelpers).

/// A mailbox row from the Envelope Index `mailboxes` table.
struct MailboxRef {
    let rowid: Int64
    let url: String
    let accountUUID: String
    /// Percent-decoded path components, e.g. ["Agent", "🧾 Invoices"].
    let pathComponents: [String]
    let totalCount: Int
    let unreadCount: Int

    var name: String { pathComponents.last ?? "" }
    var scheme: String { url.components(separatedBy: "://").first ?? "" }
}

/// Parse a mailbox URL like `imap://<ACCOUNT-UUID>/Agent/%F0%9F%A7%BE%20Invoices`.
func parseMailboxRef(rowid: Int64, url: String, totalCount: Int, unreadCount: Int) -> MailboxRef? {
    guard let schemeRange = url.range(of: "://") else { return nil }
    let rest = String(url[schemeRange.upperBound...])
    var parts = rest.components(separatedBy: "/")
    guard !parts.isEmpty else { return nil }
    let accountUUID = parts.removeFirst()
    let components = parts.compactMap { $0.removingPercentEncoding ?? $0 }.filter { !$0.isEmpty }
    guard !components.isEmpty else { return nil }
    return MailboxRef(
        rowid: rowid, url: url, accountUUID: accountUUID,
        pathComponents: components, totalCount: totalCount, unreadCount: unreadCount
    )
}

/// Directory digits between `Data/` and `/Messages` for a message ROWID.
/// The scheme is the digits of (rowid / 1000), most-significant last:
/// 8632 -> ["8"], 106847 -> ["6", "0", "1"], 42 -> [].
func emlxSubpath(forRowID rowid: Int64) -> [String] {
    var quotient = rowid / 1000
    var digits: [String] = []
    while quotient > 0 {
        digits.append(String(quotient % 10))
        quotient /= 10
    }
    return digits
}

/// Format a sender/recipient the way Mail.app's JXA does: "Name <addr>" or bare address.
func formatAddress(address: String, comment: String) -> String {
    let trimmed = comment.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? address : "\(trimmed) <\(address)>"
}

/// Epoch seconds -> ISO 8601 with milliseconds, matching JXA's Date.toISOString().
func isoStringFromEpoch(_ epoch: Double) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date(timeIntervalSince1970: epoch))
}

/// Coalesce a SQLite column value to epoch seconds. Date columns in the
/// Envelope Index may surface as INTEGER or REAL depending on what Mail wrote.
func epochValue(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int64 { return Double(int) }
    return nil
}

/// Parse an ISO 8601 string (date-only or full) to epoch seconds for SQL binding.
func epochFromISO8601(_ input: String) -> Double? {
    guard let iso = parseISO8601ForJXA(input) else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)?.timeIntervalSince1970
}

/// Escape SQL LIKE metacharacters so user query text matches literally.
/// Pair with `ESCAPE '\'` in the LIKE clause.
func escapeLikePattern(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
}

/// Mailbox names Mail.app treats as junk destinations.
private let junkMailboxNames: Set<String> = ["Junk", "Junk Mail", "Junk E-mail", "Junk Email", "Spam", "Bulk Mail"]

func isJunkMailboxName(_ name: String) -> Bool {
    junkMailboxNames.contains(name)
}

/// Full subject as JXA reports it: prefix ("Re: ", "Fwd: ") + stored subject.
func fullSubject(prefix: String?, subject: String?) -> String {
    (prefix ?? "") + (subject ?? "")
}
