import Foundation

/// The account-ambiguity refusal, in the two places it can be detected.
///
/// One account name spanning two accounts has to be refused rather than resolved, because
/// every resolution available is arbitrary: the Envelope Index returns a set, and Mail's
/// `whose({name:})` returns them in enumeration order. Acting on "whichever comes first" is
/// the silent wrong-account read the check exists to prevent, and it is worse for writes,
/// which are not reversible from here.
///
/// Until now only ONE of the two detectors existed. `EnvelopeIndex.accountUUIDs(matching:)`
/// needs the Envelope Index, and `--engine jxa` opens no database by contract, so under that
/// engine the check simply did not run and the hint fell through to first-match — for reads
/// and writes alike. This type holds the second detector, which needs no database at all:
/// `Mail.accounts.whose({name: hint})()` returning more than one result IS the ambiguity.
///
/// Both messages live here so the refusal is authored once, and so the JXA one can say
/// something true. They are deliberately NOT the same string: the index can suggest an
/// account UUID because it can resolve one, and JXA cannot resolve anything but a name.
enum AccountAmbiguity {
    /// Prefix on the JS `Error` the helper throws, so `runJXA` can tell this refusal apart
    /// from a genuine script failure. Not user-facing: `runJXA` strips it from stderr on the
    /// uncaught path and from stdout on the caught one, and refuses either way.
    static let jxaMarker = "APPLE_PIM_ACCOUNT_AMBIGUOUS:"

    /// The Envelope Index refusal. Unchanged wording: it is asserted by
    /// `EnvelopeIndexAccountTests` and `EngineFallbackTests`, and the advice is sound there
    /// because that path really can resolve a UUID.
    static func envelopeIndexMessage(requestedName: String) -> String {
        "Account matches multiple logical accounts: \(requestedName). "
            + "Use the display name or account UUID instead."
    }

    /// JS helper resolving an account hint, refusing rather than picking a first match.
    ///
    /// Emitted as a function DECLARATION so hoisting makes placement in the generated script
    /// irrelevant — several scripts call it from a helper defined above the point it is
    /// interpolated. `mailApp` is a parameter rather than a closed-over `Mail` so the
    /// declaration is position-independent in scripts that build `const Mail` themselves.
    ///
    /// A hint matching nothing returns the empty array, exactly as the expression it
    /// replaces did: "no such account" is each call site's own error to report, and several
    /// already word it their own way.
    ///
    /// `assertAccountHintResolvable` exists because a throw is only a refusal if nobody
    /// catches it. `batch-update` and `batch-delete` wrap each entry's `findMsg()` in a JS
    /// `try/catch` that records the error and continues, which swallowed this refusal
    /// wholesale: osascript exited 0, `runJXA` never looked at stderr, and the marker below
    /// was rendered to the user once per message id. Calling this once at SCRIPT TOP LEVEL,
    /// outside every loop and every `try`, refuses before any message is touched -- which is
    /// also the right semantics for a batch: an ambiguous scope invalidates the whole run,
    /// not each entry separately.
    ///
    /// It is a separate function, and guarded on `hint`, so that the no-hint case stays as
    /// lazy as it was: with no `--account` this does no work at all, rather than enumerating
    /// every account up front on a path that may never need them.
    static func jxaHelperSource() -> String {
        """
        function resolveAccountsByHint(mailApp, hint) {
            if (!hint) return mailApp.accounts();
            const matched = mailApp.accounts.whose({name: hint})();
            if (matched.length > 1) {
                throw new Error('\(jxaMarker)Account name matches ' + matched.length
                    + ' accounts in Mail: ' + hint
                    + '. Mail resolves accounts by name here, so there is nothing to'
                    + ' disambiguate with: rename one of them in Mail, or use --engine auto'
                    + ' to select by account UUID.');
            }
            return matched;
        }

        function assertAccountHintResolvable(mailApp, hint) {
            if (hint) { resolveAccountsByHint(mailApp, hint); }
        }
        """
    }

    /// Recover the refusal from osascript's stderr, or nil when this was some other failure.
    ///
    /// osascript wraps an uncaught throw as
    /// `execution error: Error: Error: <message> (-2700)`, so both the prefix and the
    /// trailing error number have to come off. The number is stripped only when it is the
    /// last thing on the line, and every message this builds ends in prose, so an account
    /// name that happens to contain parentheses is not at risk.
    static func messageFromJXAStderr(_ stderr: String) -> String? {
        guard let markerRange = stderr.range(of: jxaMarker) else { return nil }
        var message = String(stderr[markerRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trailing = message.range(of: #" \(-?\d+\)$"#, options: .regularExpression) {
            message.removeSubrange(trailing)
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Recover the refusal from a script's *stdout*, or nil when it is not in there.
    ///
    /// The uncaught path puts it on stderr; this is the caught one, where a JS `catch` has
    /// already folded it into the script's JSON result. `assertAccountHintResolvable` is what
    /// stops that happening, and this is the backstop for if it ever happens again: it makes
    /// "the marker never reaches a user" true by construction rather than by auditing every
    /// `catch` block in every generated script.
    ///
    /// Reads to the first unescaped quote, because the marker sits inside a JSON string
    /// value, then undoes JSON's two escapes so an account name containing a quote or a
    /// backslash comes back as itself.
    static func messageFromJXAOutput(_ stdout: String) -> String? {
        guard let markerRange = stdout.range(of: jxaMarker) else { return nil }
        var message = ""
        var iterator = stdout[markerRange.upperBound...].makeIterator()
        while let character = iterator.next() {
            if character == "\\" {
                // JSON escape: take the next character literally, mapping the two that can
                // legally appear inside a message this code authored.
                guard let escaped = iterator.next() else { break }
                message.append(escaped == "n" ? "\n" : escaped)
                continue
            }
            if character == "\"" { break }
            message.append(character)
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
