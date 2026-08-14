import XCTest
@testable import MailCLI

final class ScriptHelpersTests: XCTestCase {
    func testEscapeForJXAEscapesQuotesBackslashesAndControlChars() {
        let raw = "a\\b'c\"d\ne\rf\tg"
        let escaped = escapeForJXA(raw)
        XCTAssertEqual(escaped, "a\\\\b\\'c\\\"d\\ne\\rf\\tg")
    }

    func testFindMessageJXAUsesNullHintsWhenNotProvided() {
        let script = findMessageJXA(targetId: "<id>", mailbox: nil, account: nil)
        XCTAssertTrue(script.contains("const mboxHint = null;"))
        XCTAssertTrue(script.contains("const acctHint = null;"))
    }

    func testFindMessageJXAInjectsEscapedHints() {
        let script = findMessageJXA(
            targetId: "<id'\"\\\\>",
            mailbox: "Inbox 'Primary'",
            account: "Personal \"Account\""
        )
        XCTAssertTrue(script.contains("const targetId = '<id\\'\\\"\\\\\\\\>';"))
        XCTAssertTrue(script.contains("const mboxHint = 'Inbox \\'Primary\\'';"))
        XCTAssertTrue(script.contains("const acctHint = 'Personal \\\"Account\\\"';"))
    }

    func testBatchFindMessageJXAUsesNullHintsWhenNotProvided() {
        let script = batchFindMessageJXA(mailbox: nil, account: nil)
        XCTAssertTrue(script.contains("const mboxHint = null;"))
        XCTAssertTrue(script.contains("const acctHint = null;"))
        XCTAssertTrue(script.contains("function findMsg(targetId)"))
    }

    // MARK: - Unified finder (SQLite rowid fast path + JXA fallback)
    //
    // Nothing here executes the generated JXA: running `osascript` against Mail.app is off
    // limits in the build environment. These are string-shape assertions only. What they can
    // pin is that the emitted script asks for the right things; what they cannot pin is that
    // Mail.app answers — that is what the `_stats` telemetry on a real batch is for.

    private func unifiedScript(rowidMapJS: String = "{}", backend: String = "sqlite",
                               mailbox: String? = nil, account: String? = nil) -> String {
        generateUnifiedFindMsgJXA(
            rowidMapJS: rowidMapJS, backend: backend, mailbox: mailbox, account: account)
    }

    func testUnifiedFinderEmitsTheRowidMapAndHintsItWasGiven() {
        let script = unifiedScript(rowidMapJS: "{\"a@b\":[{\"r\":7}]}",
                                   mailbox: "Inbox 'Primary'", account: "Personal \"Account\"")
        XCTAssertTrue(script.contains("const rowidMap = {\"a@b\":[{\"r\":7}]};"))
        XCTAssertTrue(script.contains("const mboxHint = 'Inbox \\'Primary\\'';"))
        XCTAssertTrue(script.contains("const acctHint = 'Personal \\\"Account\\\"';"))
    }

    func testUnifiedFinderEmitsNullHintsWhenNotProvided() {
        let script = unifiedScript()
        XCTAssertTrue(script.contains("const rowidMap = {};"))
        XCTAssertTrue(script.contains("const mboxHint = null;"))
        XCTAssertTrue(script.contains("const acctHint = null;"))
        XCTAssertTrue(script.contains("function findMsg(targetId)"))
    }

    func testUnifiedFinderVerifiesTheMessageIdBeforeAcceptingAByIdHit() {
        // Layer 1, and the only thing that makes a stale Envelope-Index ROWID safe: a wrong
        // rowid can never be returned, only fallen through. It is also load-bearing ALONE on
        // the update paths, which carry no pre-op re-read.
        //
        // Asserted as ONE contiguous span, not as two substrings. The compare and the counter
        // can both be present while the accept has been hoisted out of the guarded block —
        // every `byId` result taken unverified, the guard decorative, and a pair of
        // `contains` checks still green. Spanning from the compare through the closing brace
        // and on to the mismatch counter is what forbids that: nothing may sit between the
        // compare and the accept, and the return may not leave the block. The span also fixes
        // the re-anchor's position; the test below is where that line is explained.
        XCTAssertTrue(
            Self.collapsingWhitespace(unifiedScript()).contains(
                "if (normalizeMessageId(msg.messageId()) === normalized) { "
                + "msg = msg.mailbox().messages.byId(cand.r); "
                + "_stats.byIdHits++; "
                + "lookup.method = 'byId'; "
                + "lookup.acctId = cand.acctId || ''; "
                + "lookup.mb = cand.mb || ''; "
                + "lookup.rowid = cand.r; "
                + "if (_debug) { "
                + "lookup._diag = {acctResolved: acct.name(), mbHandle: mb.name()}; "
                + "lookup._perfMs = Date.now() - _t0; "
                + "} "
                + "return {msg: msg, lookup: lookup}; "
                + "} "
                + "_stats.byIdMismatches++;"),
            "the byId result must be returned only from inside the messageId compare, with a "
            + "mismatch counted on the way out")
    }

    func testUnifiedFinderDeclaresAllFourTelemetryCounters() {
        // byIdHits vs byIdMismatches vs jxaFallbacks is the only instrument that can tell
        // "fast path working" from "silently falling back to the same slow scan".
        let script = unifiedScript()
        for counter in ["byIdHits", "byIdMismatches", "jxaFallbacks", "notFound"] {
            XCTAssertTrue(script.contains(counter), "missing counter \(counter)")
        }
        XCTAssertTrue(script.contains("function getLookupSummary()"))
    }

    func testUnifiedFinderReportsTheBackendSwiftActuallyBuilt() {
        // Derived in JS from "did any rowidMap entry have candidates", the label cannot tell
        // "no Full Disk Access" from "SQLite ran and matched nothing" — exactly the
        // distinction the acceptance gate needs. Swift knows, so Swift emits it.
        XCTAssertTrue(unifiedScript(backend: "sqlite").contains("const _locatorBackend = 'sqlite';"))
        XCTAssertTrue(unifiedScript(backend: "jxa-only").contains("const _locatorBackend = 'jxa-only';"))
    }

    func testUnifiedFinderAddressesTheRowidThroughAnyMailboxOfTheAccount() {
        // `messages.byId` is keyed to the Envelope-Index ROWID and resolves GLOBALLY, so the
        // arm needs A mailbox handle, not the RIGHT one: resolve the account, take any of its
        // mailboxes, address the rowid, and let Layer 1 below decide. Asserted as one span so
        // the handle guard cannot be separated from the call it protects, and so the byId
        // result still flows straight into the messageId compare.
        XCTAssertTrue(
            Self.collapsingWhitespace(unifiedScript()).contains(
                "var acct = null; "
                + "if (cand.acctId) acct = getAccountById(cand.acctId); "
                + "if (!acct && cand.acct) acct = getAccountByName(cand.acct); "
                + "if (!acct) continue; "
                + "var mb = anyMailboxOf(acct); "
                + "if (!mb) continue; "
                + "try { "
                + "var msg = mb.messages.byId(cand.r);"),
            "the byId arm must resolve the account, take any mailbox handle of it, and address "
            + "the rowid through that handle")
    }

    func testUnifiedFinderReAnchorsTheAcceptedSpecifierThroughTheMessagesOwnMailbox() {
        // The handle that FINDS a message is not enough to ACT on it. `messages.byId` resolves
        // a ROWID globally for property access — reads and writes alike — but the `delete` and
        // `move` commands re-resolve the specifier's container chain and refuse with "Can't get
        // object." when the mailbox it was addressed through does not hold the message. Flag
        // writes are property access, so they never saw it; every delete and move the fast path
        // located failed. The accepted specifier is therefore re-addressed through the
        // message's OWN mailbox before it leaves the finder.
        //
        // One span, and the ORDER inside it is the assertion: the re-anchor must sit between
        // the accept and `byIdHits++`. There, a re-anchor that throws leaves the counter
        // untouched and falls out of the guarded block to the scan, which counts its own
        // fallback. Below the counter, the same throw would leave a phantom hit behind and one
        // message would report as both a hit and a fallback.
        XCTAssertTrue(
            Self.collapsingWhitespace(unifiedScript()).contains(
                "if (normalizeMessageId(msg.messageId()) === normalized) { "
                + "msg = msg.mailbox().messages.byId(cand.r); "
                + "_stats.byIdHits++;"),
            "the accepted specifier must be re-anchored through its own mailbox, before the hit "
            + "is counted")
    }

    func testTheFastPathsMailLookupsDegradeToTheScanInsteadOfThrowing() {
        // Every Mail call on the byId arm answers null on failure so the write falls through
        // to the `whose` scan — correct but slow, never wrong. An unguarded call breaks that:
        // the exception leaves `findMsg` and fails a write the scan could have completed.
        // Spanning from the `try` through the call proves the call is inside it.
        let collapsed = Self.collapsingWhitespace(unifiedScript())
        XCTAssertTrue(collapsed.contains(
            "var matches = []; try { matches = Mail.accounts.whose({name: name})(); } "
            + "catch(e) { return null; }"),
            "the by-name account lookup must degrade to null, not throw")
        XCTAssertTrue(collapsed.contains("try { accts = Mail.accounts(); } catch(e) {}"),
                      "the by-id account enumeration must stay guarded too")
        XCTAssertTrue(collapsed.contains(
            "var mbs = []; try { mbs = acct.mailboxes(); } catch(e) { return null; } "
            + "return mbs.length > 0 ? mbs[0] : null;"),
            "the mailbox-handle lookup must degrade to null, not throw")
    }

    func testUnifiedFinderKeepsTheExistingWhoseScanAsItsFallback() {
        let script = unifiedScript()
        XCTAssertTrue(script.contains("mbox.messages.whose({messageId: targetId})"))
        XCTAssertTrue(script.contains("_stats.jxaFallbacks++"))
        // Visited-mailbox bookkeeping is a Set, as in `batchFindMessageJXA`: a plain object
        // keyed by account/mailbox names is a prototype lookup wearing a map's clothes, the
        // same hazard the rowid map is read with `hasOwnProperty.call` to avoid.
        XCTAssertTrue(script.contains("var searched = new Set();"))
        XCTAssertFalse(script.contains("searched["))
    }

    func testUnifiedFinderPriorityListMatchesTheSwiftConstant() {
        let emitted = Self.jsStringArray(in: unifiedScript(), after: "const MAILBOX_PRIORITY = [")
        XCTAssertEqual(emitted, mailboxPriority)
    }

    func testTheLegacyFindersMailboxPriorityCopyHasNotDrifted() {
        // `findMessageJXA` keeps five live callers, so its inline literal stays. Together with
        // the emitted list above — pinned against the same Swift constant — this is what stops
        // the two shipped finders sweeping different mailboxes in a different order.
        //
        // `batchFindMessageJXA` carries a third copy of the literal and is deliberately NOT
        // asserted here: nothing calls it, so drift in it ships nothing. See its own NOTE.
        let legacySingle = Self.jsStringArray(
            in: findMessageJXA(targetId: "<id>", mailbox: nil, account: nil),
            after: "const priority = [")

        XCTAssertEqual(legacySingle, mailboxPriority)
    }

    func testBothShippedFindersSweepAccountOuterNotPriorityOuter() {
        // Traversal ORDER, which the array comparison above cannot see and which decides
        // WHICH PHYSICAL COPY a delete or a move acts on when the same Message-ID exists in
        // two accounts. Account-outer exhausts one account's whole priority list before
        // looking at the next, so a copy in A/Trash wins over a copy in B/INBOX.
        // Priority-outer inverts that and silently retargets the write at another account.
        //
        // The two finders with callers: the read/reply/attachment scan, and the write path's
        // emitter. `batchFindMessageJXA` sweeps the same way and is not asserted — no caller,
        // so its order decides nothing.
        let cases: [(String, String, String)] = [
            (findMessageJXA(targetId: "<id>", mailbox: nil, account: nil),
             "for (let a = 0; a < accounts.length; a++) {",
             "for (let p = 0; p < priority.length; p++) {"),
            (unifiedScript(),
             "for (var a = 0; a < accounts.length; a++) {",
             "for (var p = 0; p < MAILBOX_PRIORITY.length; p++) {"),
        ]
        for (script, accountLoop, priorityLoop) in cases {
            guard let between = Self.textBetweenNearestEnclosingLoop(
                in: script, outer: accountLoop, inner: priorityLoop) else {
                return XCTFail("finder must sweep accounts and the priority list")
            }
            XCTAssertTrue(between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          "the priority loop must sit DIRECTLY inside the account loop; found "
                          + "\(between.debugDescription) between them")
        }
    }

    /// Text between the nearest preceding `outer` loop header and the `inner` loop header.
    /// Whitespace-only means `inner` is `outer`'s immediate body, i.e. `outer` is the outer
    /// loop. Anything else means some other block closed in between.
    private static func textBetweenNearestEnclosingLoop(
        in script: String, outer: String, inner: String) -> String? {
        guard let innerRange = script.range(of: inner) else { return nil }
        let head = script[script.startIndex..<innerRange.lowerBound]
        guard let outerRange = head.range(of: outer, options: .backwards) else { return nil }
        return String(script[outerRange.upperBound..<innerRange.lowerBound])
    }

    func testUnifiedFinderNeverLooksACandidateMailboxUpByName() {
        // Neither a path walk nor a leaf-name `whose` arm. Both were ways to find the mailbox
        // that HOLDS the message, which `byId` does not need, and both rest on the Envelope
        // Index's mailbox name (the SERVER's folder name) matching JXA's `mb.name()` (what Mail
        // displays, renamed for Gmail's special mailboxes) — an assumption that bought nothing
        // and cost the whole Gmail fast path when it failed.
        let script = unifiedScript()
        XCTAssertFalse(script.contains("cand.path"))
        XCTAssertFalse(script.contains("findMailboxByPath"))
        XCTAssertFalse(script.contains("[cand.mb]"))
        XCTAssertFalse(script.contains("whose({name: cand"))
    }

    func testUnifiedFinderSkipsTheFastPathForAnEmptyMessageId() {
        // An empty id normalizes to '' and so does a message whose messageId() is null, so
        // Layer 1's compare would pass on any rowid carrying an empty header. The `whose`
        // scan could never address such a message; the rowid path can, so it is gated off.
        let script = unifiedScript()
        XCTAssertTrue(script.contains("var _own = normalized && "))
        XCTAssertTrue(script.contains("var candidates = _own ? rowidMap[normalized] : [];"))
    }

    func testUnifiedFinderReadsTheRowidMapWithAnOwnPropertyCheck() {
        // A bare `rowidMap[normalized]` resolves an id that normalizes to an Object.prototype
        // member ('constructor', 'hasOwnProperty', 'isPrototypeOf', 'propertyIsEnumerable') to
        // the INHERITED function. Those four have `.length >= 1`, so the candidate loop runs
        // once with `candidates[0] === undefined` and throws a TypeError out of the write —
        // never a wrong copy, but a crafted Message-ID should not be able to fail a command.
        let script = unifiedScript()
        XCTAssertTrue(script.contains("Object.prototype.hasOwnProperty.call(rowidMap, normalized)"))
        XCTAssertFalse(script.contains("rowidMap[normalized] || []"))
    }

    func testMailboxPriorityJSONParsesBackToTheSwiftConstant() {
        let data = mailboxPriorityJSON().data(using: .utf8)
        XCTAssertEqual(data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String],
                       mailboxPriority)
    }

    func testPriorityRankPrefersInboxAndSortsUnknownMailboxesLast() {
        XCTAssertEqual(priorityRank(forMailboxName: "INBOX"), 0)
        XCTAssertLessThan(priorityRank(forMailboxName: "All Mail"),
                          priorityRank(forMailboxName: "Trash"))
        XCTAssertEqual(priorityRank(forMailboxName: "Some Custom Folder"), mailboxPriority.count)
        // The leaf, not the joined path: this is the ranking half of the Gmail defect.
        XCTAssertLessThan(priorityRank(forMailboxName: "All Mail"),
                          priorityRank(forMailboxName: "[Gmail]/All Mail"))
    }

    func testTheTwoPriorityRanksDisagreeExactlyOnACaseVariant() {
        // The write-path guard certifies a head only if it wins under BOTH readings of
        // `mailboxes.whose({name: …})`, so the two ranks must be genuinely different functions.
        // `Inbox` is the case that matters: unranked to the exact compare, rank 0 to the
        // folding one — over-ranking a non-head candidate is the dangerous direction, because
        // the head then looks certified when the scan would reach the other copy first.
        XCTAssertEqual(priorityRank(forMailboxName: "Inbox"), mailboxPriority.count)
        XCTAssertEqual(priorityRankFoldingCase(forMailboxName: "Inbox"), 0)

        // Agreement everywhere else: an exact entry, and a name in neither list.
        XCTAssertEqual(priorityRankFoldingCase(forMailboxName: "INBOX"), 0)
        XCTAssertEqual(priorityRankFoldingCase(forMailboxName: "Some Custom Folder"),
                       mailboxPriority.count)
        // Folding is case only — a hyphen difference is still a different mailbox name.
        XCTAssertEqual(priorityRankFoldingCase(forMailboxName: "Junk E-Mail"),
                       mailboxPriority.firstIndex(of: "Junk E-mail"))
    }

    // MARK: - messageId drift guard (Layer 2), and its deliberate asymmetry

    func testDestructiveCommandScriptsRefuseToActOnADriftedMessageId() {
        // Two spans per command, because there are two ways to keep the drift guard's text
        // while removing the guard. The COMPARE span carries its operands, so a guard reduced
        // to a constant condition — the drift message still sitting in a dead arm — fails it.
        // The ACT span runs from the guarded arm's brace through the destructive call, so a
        // call hoisted out of that arm fails it. Substring checks for the drift message and
        // for `preOpId` survive both, which is what makes them insufficient here.
        let finder = unifiedScript()
        let move = MoveMessage.buildScript(
            id: "<m@x>", toMailbox: "Archive", toAccount: nil, findHelper: finder)
        let delete = DeleteMessage.buildScript(id: "<m@x>", findHelper: finder)
        let batchDelete = BatchDeleteMessages.buildScript(jsIds: "'<m@x>'", findHelper: finder)

        let cases: [(name: String, script: String, compare: String, act: String)] = [
            ("move", move,
             "var preOpId = normalizeMessageId(msg.messageId()); "
                + "if (preOpId !== normalizeMessageId('<m@x>')) {",
             "} else { const fromMailbox = msg.mailbox().name(); "
                + "Mail.move(msg, {to: destMbox});"),
            ("delete", delete,
             "var preOpId = normalizeMessageId(msg.messageId()); "
                + "if (preOpId !== normalizeMessageId('<m@x>')) {",
             "} else { const subject = msg.subject(); const mboxName = msg.mailbox().name(); "
                + "Mail.delete(msg);"),
            ("batch-delete", batchDelete,
             "var preOpId = normalizeMessageId(msg.messageId()); "
                + "if (preOpId !== normalizeMessageId(targetId)) {",
             "continue; } const subject = msg.subject(); "
                + "const mboxName = msg.mailbox().name(); Mail.delete(msg);"),
        ]

        for (name, script, compare, act) in cases {
            let collapsed = Self.collapsingWhitespace(script)
            XCTAssertTrue(collapsed.contains(compare),
                          "\(name): the pre-op re-read must be compared against the requested id")
            XCTAssertTrue(collapsed.contains(act),
                          "\(name): the destructive call must sit inside the arm the compare guards")
        }

        XCTAssertTrue(move.contains("messageId drift detected before move"))
        XCTAssertTrue(delete.contains("messageId drift detected before delete"))
        XCTAssertTrue(batchDelete.contains("messageId drift detected before delete"))
        // The batch keeps going after a drifted id rather than abandoning the rest.
        XCTAssertTrue(batchDelete.contains("errors.push"))
        XCTAssertTrue(batchDelete.contains("continue;"))
    }

    func testFlagUpdateScriptsCarryNoPreOpReReadByDesign() {
        // Asserted as deliberately as the presence above. A flag flip is reversible and a
        // delete is not, so the old branch guarded only the destructive ops — which leaves
        // the post-byId messageId verify (Layer 1) load-bearing alone on precisely the
        // flag-write path this port exists to accelerate. Pinned so it stays a choice.
        let finder = unifiedScript()
        let update = UpdateMessage.buildScript(
            id: "<m@x>", updateCode: "msg.readStatus = true;", findHelper: finder)
        let batchUpdate = BatchUpdateMessages.buildScript(
            jsUpdates: "{id: '<m@x>', read: true}", findHelper: finder)

        for script in [update, batchUpdate] {
            XCTAssertFalse(script.contains("preOpId"))
            XCTAssertFalse(script.contains("messageId drift detected"))
        }
    }

    /// The five write scripts, built from one finder so a test can vary the debug mode.
    private func writeScriptsUnderTest(debug: Bool = false)
        -> [(name: String, script: String)] {
        let finder = generateUnifiedFindMsgJXA(
            rowidMapJS: "{}", backend: "sqlite", mailbox: nil, account: nil, debug: debug)
        return [
            ("update", UpdateMessage.buildScript(
                id: "<m@x>", updateCode: "", findHelper: finder)),
            ("move", MoveMessage.buildScript(
                id: "<m@x>", toMailbox: "Archive", toAccount: nil, findHelper: finder)),
            ("delete", DeleteMessage.buildScript(id: "<m@x>", findHelper: finder)),
            ("batch-update", BatchUpdateMessages.buildScript(
                jsUpdates: "", findHelper: finder)),
            ("batch-delete", BatchDeleteMessages.buildScript(jsIds: "", findHelper: finder)),
        ]
    }

    func testEveryWriteCommandScriptAttachesLookupTelemetryToBothItsResultAndItsErrorPath() {
        // Two anchors per script, not one `contains`. Every one of these attaches the lookup
        // at a success site AND at a not-found site, so a lone substring match would stay
        // green with the success attachment deleted from all five — the site a consumer reads
        // on the happy path, and the one the test's name claims to cover.
        let successAnchors = [
            "isJunk: msg.junkMailStatus() }, _r.lookup));",
            "moved: true }, _r.lookup));",
            "deleted: true }, _r.lookup));",
            "isJunk: msg.junkMailStatus() }, _r.lookup));",
            "results.push(attachLookup({id: targetId, subject: subject, "
                + "fromMailbox: mboxName}, _r.lookup));",
        ]
        let notFoundAnchors = [
            "JSON.stringify(attachLookupWithStats({error: \"Message not found: <m@x>\"}, "
                + "_r.lookup));",
            "JSON.stringify(attachLookupWithStats({error: \"Message not found: <m@x>\"}, "
                + "_r.lookup));",
            "JSON.stringify(attachLookupWithStats({error: \"Message not found: <m@x>\"}, "
                + "_r.lookup));",
            "errors.push(attachLookup({id: u.id, error: 'Message not found'}, _r.lookup));",
            "errors.push(attachLookup({id: targetId, error: 'Message not found'}, _r.lookup));",
        ]

        for (index, (name, script)) in writeScriptsUnderTest().enumerated() {
            let collapsed = Self.collapsingWhitespace(script)
            XCTAssertTrue(collapsed.contains(successAnchors[index]),
                          "\(name): the result path must carry the lookup")
            XCTAssertTrue(collapsed.contains(notFoundAnchors[index]),
                          "\(name): the not-found error path must carry the lookup")
            XCTAssertTrue(script.contains("const _r = findMsg("))
        }
    }

    func testSingleMessageCommandsCarryTheRunCountersInsideTheirLookup() {
        // A single-message command runs exactly one `findMsg`, so the process counters ARE
        // that lookup's own tally — `stats` means the same four numbers there as in the batch
        // summary. Without them a single-op caller can read only `method`, and cannot tell a
        // byId hit from a scan fallback the way a batch caller can. The counters ride the
        // SAME debug gate: this helper delegates to `attachLookup`, so nothing new reaches
        // the un-gated surface.
        let withStats = "function attachLookupWithStats(obj, lookup) { "
            + "if (_debug) lookup.stats = _stats; return attachLookup(obj, lookup); }"
        let scripts = writeScriptsUnderTest()

        for (name, script) in scripts.prefix(3) {
            let collapsed = Self.collapsingWhitespace(script)
            XCTAssertTrue(collapsed.contains(withStats),
                          "\(name): the counter-carrying helper is missing or reshaped")
            XCTAssertTrue(collapsed.contains("attachLookupWithStats({"),
                          "\(name): the single-message attach sites must carry the counters")
            // EVERY attach site, not merely one: a lone `contains` above stays green with the
            // counters added at the success site and dropped from the error sites. Inside a
            // single-message script the bare helper is only ever called by the one above,
            // which passes `obj` — never an object literal.
            XCTAssertFalse(collapsed.contains("attachLookup({"),
                           "\(name): an attach site still emits a lookup without the counters")
        }

        for (name, script) in scripts.suffix(2) {
            // A batch entry attaches mid-loop, where the counters are a running total rather
            // than that entry's own; its caller reads the whole-run summary at the end.
            XCTAssertFalse(script.contains("attachLookupWithStats({"),
                           "\(name): batch entries must keep the bare per-message lookup")
            XCTAssertTrue(script.contains("attachLookup({"),
                          "\(name): the per-entry lookup must still be attached")
        }
    }

    func testOnlyTheBatchCommandsEmitTheProcessLevelSummary() {
        // The shared helper defines `getLookupSummary()` in all five scripts; only the two
        // batch commands call it, and only they put the counters on the UN-gated surface. The
        // single-message commands carry the same counters behind `MAIL_CLI_DEBUG=1`, inside
        // their `_lookup` (above). Asserted so the absence stays a choice.
        let scripts = writeScriptsUnderTest()
        for (name, script) in scripts.prefix(3) {
            XCTAssertFalse(script.contains("output._lookup = getLookupSummary();"),
                           "\(name): single-message commands emit no aggregate")
        }
        for (name, script) in scripts.suffix(2) {
            XCTAssertTrue(script.contains("output._lookup = getLookupSummary();"),
                          "\(name): the aggregate must be emitted")
        }
    }

    func testPerMessageLookupDetailIsEmittedOnlyBehindTheDebugGate() {
        // The per-message lookup names an internal account UUID and an Envelope-Index ROWID,
        // and repeats on every entry of a batch, so it belongs on the debug surface. One
        // shared helper is the only writer of `_lookup` — `attachLookupWithStats` delegates to
        // it rather than assigning its own — which is what makes the gate's presence provable:
        // strike the gated helper and the process summary — a different contract, four
        // counters and a label — and no `_lookup` may remain anywhere in any of the five.
        let gatedHelper = "function attachLookup(obj, lookup) { if (_debug) obj._lookup = lookup;"
            + " return obj; }"
        for (name, script) in writeScriptsUnderTest() {
            let collapsed = Self.collapsingWhitespace(script)
            XCTAssertTrue(collapsed.contains(gatedHelper),
                          "\(name): the per-message lookup helper is missing or reshaped")

            var stripped = collapsed.replacingOccurrences(of: gatedHelper, with: "")
            stripped = stripped.replacingOccurrences(
                of: "output._lookup = getLookupSummary();", with: "")
            XCTAssertFalse(stripped.contains("_lookup"),
                           "\(name): an un-gated per-message _lookup remains")
        }
    }

    // MARK: - The aggregate locator summary reaches production stdout
    //
    // The one thing on the normal output surface that can tell the SQLite fast path from the
    // scan it falls back to. `byIdMismatches` especially is unreachable any other way (a
    // mismatch's row reads `method: 'whose'`, indistinguishable from a plain miss). Four
    // counters + backend label, no identifiers, no Apple Events, so always emitted; everything
    // per-message stays gated — `_diag`/`_perfMs` spend Apple Events, and the per-message
    // lookup names an account UUID on every row of a batch.

    private func batchScriptsUnderTest(debug: Bool = false) -> [(name: String, script: String)] {
        Array(writeScriptsUnderTest(debug: debug).suffix(2))
    }

    func testBothBatchScriptsEmitTheLocatorSummaryUnconditionally() {
        // Asserted under BOTH debug modes: the summary's whole value is that a production
        // caller with no MAIL_CLI_DEBUG in its environment still gets it, and only building
        // the script both ways can show the gate is absent rather than merely satisfied.
        for debug in [false, true] {
            for (name, script) in batchScriptsUnderTest(debug: debug) {
                let label = "\(name) (debug=\(debug))"
                XCTAssertTrue(script.contains("const _debug = \(debug);"),
                              "\(label): the finder must carry the debug mode it was given")
                XCTAssertFalse(script.contains("if (_debug) output._lookup"),
                               "\(label): the aggregate summary must not be debug-gated")
                // Spanning the declaration through the serialize proves nothing sits between
                // them — no gate, no early return — not merely that the assignment appears.
                XCTAssertTrue(
                    Self.collapsingWhitespace(script).contains(
                        "var output = {results: results, errors: errors}; "
                        + "output._lookup = getLookupSummary(); JSON.stringify(output);"),
                    "\(label): the summary must be assigned unconditionally between the output "
                    + "declaration and JSON.stringify")
                // The payload the summary carries, which is the half a consumer parses.
                XCTAssertTrue(
                    Self.collapsingWhitespace(script).contains(
                        "function getLookupSummary() { return {backend: _locatorBackend, "
                        + "stats: _stats}; }"),
                    "\(label): the summary shape must stay backend + stats")
                XCTAssertTrue(
                    script.contains("var _stats = {byIdHits: 0, byIdMismatches: 0, "
                                    + "jxaFallbacks: 0, notFound: 0};"),
                    "\(label): the four counters must stay declared, whatever the debug mode")
            }
        }
    }

    func testBothBatchScriptsKeepPerMessageDebugDiagnosticsGated() {
        let gatedBlock = "if (_debug) { lookup._diag = {acctResolved: acct.name(), "
            + "mbHandle: mb.name()}; lookup._perfMs = Date.now() - _t0; }"
        let gatedInline = "if (_debug) lookup._perfMs = Date.now() - _t0;"

        for (name, script) in batchScriptsUnderTest() {
            let collapsed = Self.collapsingWhitespace(script)
            // Presence first: without these, a reshaped literal would surface below as a
            // phantom "un-gated _diag" rather than as the mismatch it actually is.
            XCTAssertTrue(collapsed.contains(gatedBlock),
                          "\(name): the byId diagnostics block is missing or reshaped")
            XCTAssertTrue(collapsed.contains(gatedInline),
                          "\(name): the fallback _perfMs gate is missing or reshaped")
            XCTAssertTrue(collapsed.contains("var _t0 = _debug ? Date.now() : 0;"),
                          "\(name): the _t0 clock must stay debug-gated")

            var stripped = collapsed.replacingOccurrences(of: gatedBlock, with: "")
            stripped = stripped.replacingOccurrences(of: gatedInline, with: "")
            XCTAssertFalse(stripped.contains("_perfMs"), "\(name): an un-gated _perfMs remains")
            XCTAssertFalse(stripped.contains("_diag"), "\(name): an un-gated _diag remains")
        }
    }

    /// Whitespace-collapsed copy of a script, so a needle may span emitted lines without
    /// pinning the indentation the string interpolation happens to produce.
    private static func collapsingWhitespace(_ script: String) -> String {
        script.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
    }

    func testWriteCommandScriptsDeclareMailBeforeTheFinderHelper() {
        // The emitted helper closes over `Mail`; the caller must declare it first.
        let finder = unifiedScript()
        let script = UpdateMessage.buildScript(id: "<m@x>", updateCode: "", findHelper: finder)
        guard let mailDecl = script.range(of: "const Mail = Application(\"Mail\");"),
              let helperUse = script.range(of: "function findMsg(targetId)") else {
            return XCTFail("script must declare Mail and embed the finder helper")
        }
        XCTAssertLessThan(mailDecl.lowerBound, helperUse.lowerBound)
    }

    /// Pull a JS array of single- or double-quoted strings out of an emitted script.
    private static func jsStringArray(in script: String, after marker: String) -> [String]? {
        guard let start = script.range(of: marker) else { return nil }
        let rest = script[start.upperBound...]
        guard let end = rest.range(of: "]") else { return nil }
        return rest[..<end.lowerBound]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t'\"")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Reply script (issue #67)

    func testReplyScriptDoesNotUseBrittleByNameMailboxSpecifier() {
        // The -1728 bug came from addressing `mailbox "<name>" of account "<acct>"`,
        // which fails for nested Gmail mailboxes. The fix must NOT emit that form.
        let script = buildReplyAppleScript(
            bodyPath: "/tmp/body.txt",
            accountName: "Google",
            appleMailId: 12345,
            attachmentLines: ""
        )
        XCTAssertFalse(script.contains("of mailbox"),
                       "reply must not address the message via a by-name mailbox specifier")
        XCTAssertFalse(script.contains("message of mailbox"))
    }

    func testReplyScriptSearchesAccountMailboxTreeRecursively() {
        let script = buildReplyAppleScript(
            bodyPath: "/tmp/body.txt",
            accountName: "Google",
            appleMailId: 12345,
            attachmentLines: ""
        )
        // Recursive resolver present, account addressed by name, id used numerically.
        XCTAssertTrue(script.contains("on findMsgById(theId, mboxList)"))
        XCTAssertTrue(script.contains("my findMsgById(12345, (mailboxes of theAccount))"))
        XCTAssertTrue(script.contains("first account whose name is \"Google\""))
        XCTAssertTrue(script.contains("messages of mb whose id is theId"))
        XCTAssertTrue(script.contains("mailboxes of mb"))
        XCTAssertTrue(script.contains("reply origMsg without opening window"))
        XCTAssertTrue(script.contains("send replyMsg"))
    }

    func testReplyScriptComposesWithoutOpeningWindow() {
        // `with opening window` forces HTML mode, which makes the plain-text `content`
        // property read-only — the reply then sends with an empty body. See issue #73.
        let script = buildReplyAppleScript(
            bodyPath: "/tmp/body.txt",
            accountName: "Google",
            appleMailId: 12345,
            attachmentLines: ""
        )
        XCTAssertTrue(script.contains("reply origMsg without opening window"),
                      "reply must compose without opening the window to keep content writable")
        XCTAssertFalse(script.contains("reply origMsg with opening window"),
                       "opening the window regresses the empty-body bug (issue #73)")
        // Body is assigned directly, not concatenated onto the quoted original.
        XCTAssertTrue(script.contains("set content of replyMsg to replyBody"))
        XCTAssertFalse(script.contains("replyBody & return & return & content of replyMsg"))
    }

    func testReplyScriptEscapesAccountAndOmitsAttachmentBlockWhenEmpty() {
        let script = buildReplyAppleScript(
            bodyPath: "/tmp/body.txt",
            accountName: "Weird \"Acct\"",
            appleMailId: 7,
            attachmentLines: ""
        )
        XCTAssertTrue(script.contains("first account whose name is \"Weird \\\"Acct\\\"\""))
        XCTAssertFalse(script.contains("tell replyMsg"))
    }

    func testReplyScriptIncludesAttachmentBlockWhenProvided() {
        let attachmentLines = "\n        make new attachment with properties {file name:\"/tmp/a.pdf\"} at after the last paragraph"
        let script = buildReplyAppleScript(
            bodyPath: "/tmp/body.txt",
            accountName: "Google",
            appleMailId: 7,
            attachmentLines: attachmentLines
        )
        XCTAssertTrue(script.contains("tell replyMsg"))
        XCTAssertTrue(script.contains("make new attachment with properties {file name:\"/tmp/a.pdf\"}"))
    }
}
