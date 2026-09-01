import XCTest
@testable import MailCLI

/// The JXA half of the account-ambiguity refusal (#119).
///
/// These EXECUTE the shipped JS. That is possible without breaking the rule the rest of the
/// suite works under — "running osascript against Mail.app is off limits in the build
/// environment" — because `resolveAccountsByHint` takes the application as a parameter
/// rather than closing over `Mail`. So the tests hand it a plain JS object, and osascript
/// runs pure JavaScript with no `Application("Mail")` anywhere and no automation permission
/// involved.
///
/// That is worth the extra machinery here specifically. A string-shape assertion could pin
/// that the helper is emitted; it could not pin that it refuses, and refusing is the change.
final class AccountAmbiguityTests: XCTestCase {

    // MARK: - Running the emitted helper

    /// Stand-in for `Application("Mail")`: `accounts` is callable AND carries `.whose`,
    /// which is the shape the helper actually uses.
    private static func fakeMailApp(_ names: [String]) -> String {
        let list = names.map { "'\($0)'" }.joined(separator: ", ")
        return """
        (function () {
            const names = [\(list)];
            const accounts = function () { return names.map(function (n) { return {name: n}; }); };
            accounts.whose = function (pred) {
                return function () {
                    return names.filter(function (n) { return n === pred.name; })
                                .map(function (n) { return {name: n}; });
                };
            };
            return {accounts: accounts};
        })()
        """
    }

    private struct JXARun {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    /// Run the emitted helper plus one expression through osascript.
    private func runHelper(accounts: [String], hint: String?) throws -> JXARun {
        let hintLiteral = hint.map { "'\($0)'" } ?? "null"
        let script = """
        \(AccountAmbiguity.jxaHelperSource())

        JSON.stringify(
            resolveAccountsByHint(\(Self.fakeMailApp(accounts)), \(hintLiteral))
                .map(function (a) { return a.name; })
        );
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-l", "JavaScript", "-e", script]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        // Read before waiting: these outputs are tiny, but the pipe-deadlock shape is the
        // same one runJXA documents, and copying the safe order costs nothing.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return JXARun(
            stdout: String(decoding: outData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            status: proc.terminationStatus)
    }

    func testAUniqueAccountNameStillResolves() throws {
        let run = try runHelper(accounts: ["Work", "Home"], hint: "Work")
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(run.stdout, "[\"Work\"]")
    }

    func testNoHintStillEnumeratesEveryAccount() throws {
        let run = try runHelper(accounts: ["Work", "Home"], hint: nil)
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(run.stdout, "[\"Work\",\"Home\"]")
    }

    /// A hint matching nothing is each call site's own "Account not found", not this
    /// helper's error. Several sites word that message themselves and must keep doing so.
    func testAHintThatMatchesNothingIsNotAnAmbiguityError() throws {
        let run = try runHelper(accounts: ["Work", "Home"], hint: "Nope")
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(run.stdout, "[]")
    }

    /// The bug in #119: two accounts sharing a display name resolved to whichever enumerated
    /// first. It now refuses, with no database open anywhere.
    func testAnAmbiguousAccountNameRefusesInsteadOfPickingTheFirst() throws {
        let run = try runHelper(accounts: ["Shared", "Shared"], hint: "Shared")
        XCTAssertNotEqual(run.status, 0, "an ambiguous hint must not resolve")
        XCTAssertTrue(run.stderr.contains(AccountAmbiguity.jxaMarker),
                      "stderr must carry the marker runJXA keys on: \(run.stderr)")
        XCTAssertFalse(run.stdout.contains("Shared"),
                       "nothing may be returned for an ambiguous hint: \(run.stdout)")
    }

    /// End to end across the seam: real osascript wrapping, real stderr, real parser. This is
    /// what proves `runJXA` turns the thrown Error into the refusal the user sees, rather
    /// than into a generic `CLIError.jxaError` carrying a marker nobody stripped.
    func testTheThrownErrorSurvivesOsascriptWrappingAndParsesBackToAMessage() throws {
        let run = try runHelper(accounts: ["Shared", "Shared"], hint: "Shared")

        guard let message = AccountAmbiguity.messageFromJXAStderr(run.stderr) else {
            return XCTFail("parser did not recognize its own marker in: \(run.stderr)")
        }
        XCTAssertTrue(message.hasPrefix("Account name matches 2 accounts in Mail: Shared"),
                      "message was: \(message)")
        XCTAssertFalse(message.contains(AccountAmbiguity.jxaMarker), "marker must be stripped")
        // osascript appends " (-2700)"; a user-facing message must not end in an OSA code.
        XCTAssertFalse(message.hasSuffix(")"), "trailing error number must be stripped: \(message)")
        XCTAssertTrue(message.contains("--engine auto"), "must name a remedy that exists")
    }

    // MARK: - The stderr parser on its own

    func testParserIgnoresUnrelatedFailures() {
        XCTAssertNil(AccountAmbiguity.messageFromJXAStderr(
            "execution error: Error: Mail got an error: Can't get account 1. (-1728)"))
        XCTAssertNil(AccountAmbiguity.messageFromJXAStderr(""))
    }

    /// Only a trailing OSA code comes off. An account name with parentheses in it must not
    /// be truncated by the same rule.
    func testParserStripsOnlyATrailingErrorNumber() {
        let stderr = "execution error: Error: Error: "
            + AccountAmbiguity.jxaMarker
            + "Account name matches 2 accounts in Mail: Work (old). Rename one. (-2700)"
        XCTAssertEqual(
            AccountAmbiguity.messageFromJXAStderr(stderr),
            "Account name matches 2 accounts in Mail: Work (old). Rename one.")
    }

    // MARK: - Both engines refuse, and say something true

    /// The two refusals are deliberately worded differently, and the JXA one must not repeat
    /// the index's advice: under JXA a hint is matched against the display name, so "use the
    /// display name" is exactly the thing that already failed, and no UUID can be resolved.
    func testTheJXARefusalDoesNotRepeatAdviceThatCannotWorkThere() throws {
        let indexMessage = AccountAmbiguity.envelopeIndexMessage(requestedName: "Shared")
        XCTAssertEqual(indexMessage,
                       "Account matches multiple logical accounts: Shared. "
                       + "Use the display name or account UUID instead.")

        let run = try runHelper(accounts: ["Shared", "Shared"], hint: "Shared")
        let jxaMessage = try XCTUnwrap(AccountAmbiguity.messageFromJXAStderr(run.stderr))
        XCTAssertNotEqual(jxaMessage, indexMessage)
        XCTAssertFalse(jxaMessage.contains("Use the display name"))
    }
}

/// Which emitted scripts route their account hint through the refusal.
///
/// Shape assertions, unlike the tests above, because these pin WIRING: that no generator
/// quietly keeps a raw first-match resolution. A site that regresses stops appearing here.
final class AccountAmbiguityWiringTests: XCTestCase {

    /// The raw expression the fix replaces. Its only surviving use is `getAccountByName`,
    /// which resolves a name this code produced rather than one the user typed.
    private let rawResolution = "Mail.accounts.whose({name:"

    func testTheReadPathFinderResolvesThroughTheRefusal() {
        let script = findMessageJXA(targetId: "<m@x>", mailbox: nil, account: "Shared")
        XCTAssertTrue(script.contains("function resolveAccountsByHint(mailApp, hint)"),
                      "the helper must travel with the script that calls it")
        XCTAssertTrue(script.contains("resolveAccountsByHint(Mail, acctHint)"))
        XCTAssertFalse(script.contains(rawResolution),
                       "the read path must not keep a first-match resolution")
    }

    func testTheWritePathFinderResolvesThroughTheRefusal() {
        let script = generateUnifiedFindMsgJXA(
            rowidMapJS: "{}", backend: "sqlite", mailbox: nil, account: "Shared")
        XCTAssertTrue(script.contains("function resolveAccountsByHint(mailApp, hint)"))
        XCTAssertTrue(script.contains("resolveAccountsByHint(Mail, acctHint)"))
        // Exactly one raw resolution survives, and it is the deliberate exclusion.
        XCTAssertEqual(script.components(separatedBy: rawResolution).count - 1, 1,
                       "only getAccountByName may resolve a name without refusing")
        XCTAssertTrue(script.contains("function getAccountByName(name)"))
    }

    /// #119 calls out that this is not a read/write split, so pin that it is closed on both
    /// sides at once. The two finders are independently generated and have drifted before.
    func testBothShippedFindersRefuseAmbiguityTheSameWay() {
        let read = findMessageJXA(targetId: "<m@x>", mailbox: nil, account: "Shared")
        let write = generateUnifiedFindMsgJXA(
            rowidMapJS: "{}", backend: "sqlite", mailbox: nil, account: "Shared")
        for script in [read, write] {
            XCTAssertTrue(script.contains(AccountAmbiguity.jxaMarker),
                          "both finders must carry the same refusal marker")
        }
    }

    func testTheMoveDestinationAccountHintAlsoRefuses() {
        let script = MoveMessage.buildScript(
            id: "<m@x>", toMailbox: "Archive", toAccount: "Shared",
            findHelper: generateUnifiedFindMsgJXA(
                rowidMapJS: "{}", backend: "sqlite", mailbox: nil, account: nil))
        // `--to-account` is a second, independent hint on the same command; the source
        // account travels through the finder above.
        XCTAssertTrue(script.contains("resolveAccountsByHint(Mail, destAccountName)"))
        XCTAssertTrue(script.contains("function resolveAccountsByHint(mailApp, hint)"),
                      "the finder must bring the helper into this script")
    }
}

/// Does the generated JXA actually parse?
///
/// Nothing asked this before. The suite reads emitted scripts as strings and checks for
/// substrings, which cannot tell a well-formed script from one a bad interpolation broke --
/// and #119 edited seven of them. `osacompile` answers it without running anything: it
/// compiles, never executes, so no Mail.app and no automation permission is involved. It
/// reports a syntax error on stderr while still exiting 0, so stderr is the signal.
final class GeneratedScriptSyntaxTests: XCTestCase {

    /// Compile `js` and return the compiler's complaint, or nil when it parsed.
    private func compilationError(_ js: String) throws -> String? {
        let osacompile = URL(fileURLWithPath: "/usr/bin/osacompile")
        guard FileManager.default.isExecutableFile(atPath: osacompile.path) else {
            throw XCTSkip("/usr/bin/osacompile unavailable")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("script.js")
        try js.write(to: source, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = osacompile
        proc.arguments = ["-l", "JavaScript",
                          "-o", dir.appendingPathComponent("out.scpt").path,
                          source.path]
        let err = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = err
        try proc.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    /// Proves the check can fail, so a green run means something.
    func testTheSyntaxCheckRejectsBrokenJavaScript() throws {
        let error = try compilationError("function broken( { const x =")
        XCTAssertNotNil(error, "osacompile must report a syntax error on malformed input")
    }

    func testTheHelperItselfParses() throws {
        XCTAssertNil(try compilationError(AccountAmbiguity.jxaHelperSource()))
    }

    func testTheReadPathFinderParsesWithHintsAndWithout() throws {
        for account in ["Shared 'quoted'", nil] {
            let script = findMessageJXA(targetId: "<m'x@y>", mailbox: "Inbox \"A\"", account: account)
            XCTAssertNil(try compilationError(script), "account hint: \(account ?? "nil")")
        }
    }

    func testTheWritePathFinderParsesWithHintsAndWithout() throws {
        for account in ["Shared 'quoted'", nil] {
            let script = generateUnifiedFindMsgJXA(
                rowidMapJS: "{\"a@b\":[{\"r\":7,\"acct\":\"X\"}]}", backend: "sqlite",
                mailbox: "Inbox \"A\"", account: account)
            XCTAssertNil(try compilationError(script), "account hint: \(account ?? "nil")")
        }
    }

    /// The one command carrying two independent account hints, so the finder's copy of the
    /// helper and the destination lookup's call to it appear in a single script.
    func testTheMoveScriptParsesWithBothAccountHints() throws {
        let script = MoveMessage.buildScript(
            id: "<m'x@y>", toMailbox: "Archive \"2026\"", toAccount: "Shared 'quoted'",
            findHelper: generateUnifiedFindMsgJXA(
                rowidMapJS: "{}", backend: "jxa-only", mailbox: nil, account: "Shared 'quoted'"))
        XCTAssertNil(try compilationError(script))
    }
}
