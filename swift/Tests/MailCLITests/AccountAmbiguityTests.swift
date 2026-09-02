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

    // MARK: - The stdout backstop

    /// One JSON result carrying the marker, as a caught throw would produce it.
    private func resultJSON(message: String) -> String {
        "{\"results\":[],\"errors\":[{\"id\":\"<a@x>\",\"error\":\""
            + AccountAmbiguity.jxaMarker + message
            + "\"}],\"_lookup\":{\"backend\":\"jxa-only\"}}"
    }

    /// The caught path: a `catch` folded the marker into the script's JSON result and the
    /// script exited 0. `assertAccountHintResolvable` stops scripts getting here; this makes
    /// "the marker is not user-facing" hold even if one ever does again.
    func testTheMarkerIsRecoveredFromAJSONResult() {
        let json = resultJSON(message: "Account name matches 2 accounts in Mail: Shared. Rename one.")
        XCTAssertEqual(AccountAmbiguity.messageFromJXAOutput(json),
                       "Account name matches 2 accounts in Mail: Shared. Rename one.")
    }

    /// Stops at the JSON string's own closing quote rather than swallowing the rest of the
    /// document.
    func testTheRecoveredMessageStopsAtTheStringItLivesIn() {
        let message = AccountAmbiguity.messageFromJXAOutput(
            resultJSON(message: "Two accounts named Shared."))
        XCTAssertEqual(message, "Two accounts named Shared.")
        XCTAssertFalse(message?.contains("_lookup") ?? true, "must not run past its own string")
    }

    /// An account name carrying a quote or a backslash arrives JSON-escaped. It must come
    /// back as itself rather than truncating the message at the escape.
    func testJSONEscapesInTheAccountNameSurvive() {
        // JSON source: ... matches 2 accounts in Mail: He said \"hi\" C:\\Mail. Rename one.
        let json = resultJSON(
            message: "Matches 2 accounts in Mail: He said \\\"hi\\\" C:\\\\Mail. Rename one.")
        XCTAssertEqual(AccountAmbiguity.messageFromJXAOutput(json),
                       "Matches 2 accounts in Mail: He said \"hi\" C:\\Mail. Rename one.")
    }

    func testOrdinaryOutputIsNotMistakenForARefusal() {
        XCTAssertNil(AccountAmbiguity.messageFromJXAOutput(
            "{\"results\":[{\"id\":\"<a@x>\"}],\"errors\":[]}"))
        XCTAssertNil(AccountAmbiguity.messageFromJXAOutput(""))
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
    fileprivate func compilationError(_ js: String) throws -> String? {
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

/// The batch commands, which swallowed the refusal.
///
/// `batch-update` and `batch-delete` wrap each entry's `findMsg()` in a JS `try/catch` that
/// records the error and continues. That caught `resolveAccountsByHint`'s throw, so osascript
/// exited 0, `runJXA`'s non-zero guard never fired, and the internal marker was rendered to
/// the user once per message id — while `--engine sqlite` refused the same input non-zero.
/// It also bit `--engine auto` without Full Disk Access, where `NoopLocator` resolves nothing
/// and raises nothing, so no Swift-side check ran either.
///
/// These run the REAL emitted scripts against a fake Mail. The wiring assertions below would
/// not have caught the original bug on their own — the helper WAS present and WAS called, one
/// layer too deep — so the executable ones carry the weight here.
final class BatchCommandAmbiguityTests: XCTestCase {

    /// A fake `Mail` with `accounts` callable and carrying `.whose`, plus enough of a mailbox
    /// surface for the finder's scan to complete when it is allowed to run.
    private static func fakeMailDeclaration(accountNames: [String]) -> String {
        let list = accountNames.map { "'\($0)'" }.joined(separator: ", ")
        return """
        function __acct(n) {
            return {
                name: function () { return n; },
                mailboxes: Object.assign(function () { return []; },
                                         {whose: function () { return function () { return []; }; }})
            };
        }
        const __names = [\(list)];
        const __accounts = Object.assign(
            function () { return __names.map(__acct); },
            {whose: function (p) {
                return function () {
                    return __names.filter(function (n) { return n === p.name; }).map(__acct);
                };
            }});
        const Mail = {accounts: __accounts, delete: function () {}, move: function () {}};
        """
    }

    private struct Run { let stdout: String; let stderr: String; let status: Int32 }

    /// Swap `Application("Mail")` for the fake and execute. Nothing here touches Mail.app.
    private func run(_ script: String, accountNames: [String]) throws -> Run {
        let real = "const Mail = Application(\"Mail\");"
        XCTAssertTrue(script.contains(real), "script must declare Mail the usual way")
        let js = script.replacingOccurrences(
            of: real, with: Self.fakeMailDeclaration(accountNames: accountNames))

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("script.js")
        try js.write(to: file, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-l", "JavaScript", file.path]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return Run(stdout: String(decoding: outData, as: UTF8.self),
                   stderr: String(decoding: errData, as: UTF8.self),
                   status: proc.terminationStatus)
    }

    private func finder(account: String?) -> String {
        generateUnifiedFindMsgJXA(rowidMapJS: "{}", backend: "jxa-only",
                                  mailbox: nil, account: account)
    }

    private func batchScripts(account: String?) -> [(String, String)] {
        [("batch-update",
          BatchUpdateMessages.buildScript(jsUpdates: "{id: '<a@x>', read: true}, {id: '<b@x>', read: true}",
                                          findHelper: finder(account: account))),
         ("batch-delete",
          BatchDeleteMessages.buildScript(jsIds: "'<a@x>', '<b@x>'",
                                          findHelper: finder(account: account)))]
    }

    /// The bug: exit 0, and the marker rendered into the result once per id.
    func testAnAmbiguousAccountRefusesTheWholeBatch() throws {
        for (name, script) in batchScripts(account: "Shared") {
            let result = try run(script, accountNames: ["Shared", "Shared"])

            XCTAssertNotEqual(result.status, 0,
                              "\(name): an ambiguous scope must fail the run, not each entry")
            XCTAssertFalse(result.stdout.contains(AccountAmbiguity.jxaMarker),
                           "\(name): the marker must never reach a result: \(result.stdout)")
            XCTAssertTrue(result.stderr.contains(AccountAmbiguity.jxaMarker),
                          "\(name): the refusal must reach the stderr runJXA reads")
            // The refusal fires before any message is touched, so no per-entry error is
            // recorded at all -- one refusal for the batch, not N.
            XCTAssertFalse(result.stdout.contains("<a@x>"),
                           "\(name): nothing may be reported per entry: \(result.stdout)")
        }
    }

    /// Whatever the fix does, it must not refuse a batch that is fine. Two distinct accounts
    /// with a hint naming one, and no hint at all, both still run.
    func testUnambiguousBatchesStillRun() throws {
        for (name, script) in batchScripts(account: "Work") {
            let result = try run(script, accountNames: ["Work", "Home"])
            XCTAssertEqual(result.status, 0, "\(name) with a unique hint: \(result.stderr)")
            XCTAssertTrue(result.stdout.contains("results"), "\(name): \(result.stdout)")
        }
        for (name, script) in batchScripts(account: nil) {
            let result = try run(script, accountNames: ["Work", "Home"])
            XCTAssertEqual(result.status, 0, "\(name) with no hint: \(result.stderr)")
        }
    }

    /// Wiring: the assert is emitted, and emitted *before* the `try` that would eat it.
    /// Position is the whole point, so it is asserted rather than mere presence.
    func testTheAssertIsEmittedAheadOfThePerEntryTryCatch() {
        for (name, script) in batchScripts(account: "Shared") {
            guard let assertion = script.range(of: "assertAccountHintResolvable(Mail, acctHint);"),
                  let firstTry = script.range(of: "try {") else {
                return XCTFail("\(name): expected both the assert and a per-entry try")
            }
            XCTAssertLessThan(assertion.lowerBound, firstTry.lowerBound,
                              "\(name): the assert must run before anything can catch it")
        }
    }

    /// The generated batch scripts still parse with the assert in them.
    func testTheBatchScriptsStillCompile() throws {
        let syntax = GeneratedScriptSyntaxTests()
        for (name, script) in batchScripts(account: "Shared 'quoted'") {
            XCTAssertNil(try syntax.compilationErrorForTesting(script), name)
        }
    }
}

extension GeneratedScriptSyntaxTests {
    /// Exposed so `BatchCommandAmbiguityTests` can reuse the compiler check.
    func compilationErrorForTesting(_ js: String) throws -> String? {
        try compilationError(js)
    }
}
