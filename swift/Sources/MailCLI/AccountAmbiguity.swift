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
    /// from a genuine script failure. Not user-facing; stripped before the message surfaces.
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
}
