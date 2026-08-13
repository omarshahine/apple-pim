import Foundation
import SQLite3
import XCTest
@testable import MailCLI

/// Cover for the write-path message locator: Message-ID -> ranked Envelope-Index ROWID
/// candidates, and the JS those candidates are emitted as. Runs against a throwaway Envelope
/// Index (no Mail.app, FDA, or `osascript`). Fixture harness duplicated from
/// `EnvelopeIndexLabelsTests` (its `openFixture` is private) rather than shared.
final class MessageLocatorTests: XCTestCase {

    // Fixture mailbox ROWIDs.
    private let allMailRowID: Int64 = 1    // imap://GMAIL-ACCOUNT/[Gmail]/All Mail  (nested)
    private let inboxRowID: Int64 = 2      // imap://GMAIL-ACCOUNT/INBOX
    private let otherInboxRowID: Int64 = 3 // ews://OTHER-ACCOUNT/Inbox
    private let trashRowID: Int64 = 4      // imap://GMAIL-ACCOUNT/[Gmail]/Trash  (nested)
    private let receiptsRowID: Int64 = 6   // imap://GMAIL-ACCOUNT/Receipts   (top-level, unranked)
    private let oldMailRowID: Int64 = 7    // imap://GMAIL-ACCOUNT/Old Mail   (top-level, unranked)

    private let gmailAccount = "GMAIL-ACCOUNT"
    private let otherAccount = "OTHER-ACCOUNT"

    private lazy var tempDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailcli-locator-\(UUID().uuidString)")

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - The Gmail assertion

    func testGmailAllMailCandidateCarriesTheLeafNameAndThePathComponents() throws {
        // THE regression this port exists to avoid. The old branch emitted Foundation's
        // `URL.path` minus its leading slash — the FULL path, "[Gmail]/All Mail". JXA's
        // mailbox `name` is the LEAF, so that string matched no mailbox, every Gmail
        // candidate was skipped, and the acceleration silently no-opped (right answer,
        // zero speedup) on the exact account type this fork targets.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(
            messageIds: ["<gmail-only@example.com>"], mailbox: nil, account: nil)

        let candidates = try XCTUnwrap(refs["gmail-only@example.com"])
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidate.mailboxName, "All Mail")
        XCTAssertEqual(candidate.mailboxPathComponents, ["[Gmail]", "All Mail"])
        XCTAssertEqual(candidate.rowid, 201)
        XCTAssertEqual(candidate.accountUUID, gmailAccount)

        // Negative: the joined form must appear in no field the JXA side reads.
        XCTAssertNotEqual(candidate.mailboxName, "[Gmail]/All Mail")
        XCTAssertFalse(candidate.mailboxPathComponents.contains("[Gmail]/All Mail"))
    }

    // MARK: - Physical-vs-logical mailbox

    func testLocatorResolvesToThePHYSICALMailboxNotTheLogicalOne() throws {
        // Pins the write path to the PHYSICAL mailbox (on-disk store), not the logical one a
        // Gmail label displays it under — see `SQLiteEngine.mailboxRef(forURL:)`. The fixture
        // makes the two genuinely differ so this isn't vacuous: message 201 is stored under
        // [Gmail]/All Mail but labeled INBOX.
        let engine = try SQLiteEngine(index: try openFixture(extraSQL: Self.gmailLabelRows))

        // Half 1 — the divergence is real and observable, not a premise this test asserts of
        // itself. The READ path, scoped to INBOX, reports this very message as living in
        // "INBOX": that is `mailboxRef(forRow:)` preferring `logical_mailbox_rowid`. Without
        // this half, half 2 would pass on a fixture where the two never differed and would
        // pin nothing.
        let read = try engine.search(query: "Fixture subject", field: "subject",
                                     mailbox: "INBOX", account: nil, limit: 50, since: nil)
        let readMessages = try XCTUnwrap(read["messages"] as? [[String: Any]])
        let readRow = try XCTUnwrap(readMessages.first {
            $0["messageId"] as? String == "gmail-only@example.com"
        })
        XCTAssertEqual(readRow["mailbox"] as? String, "INBOX")

        // Half 2 — the locator, on the same message in the same database, reports the
        // PHYSICAL mailbox.
        let refs = try engine.resolve(
            messageIds: ["<gmail-only@example.com>"], mailbox: nil, account: nil)
        let candidate = try XCTUnwrap(refs["gmail-only@example.com"]?.first)
        XCTAssertEqual(candidate.rowid, 201)
        XCTAssertEqual(candidate.mailboxURL, "imap://GMAIL-ACCOUNT/%5BGmail%5D/All%20Mail")
        XCTAssertEqual(candidate.mailboxName, "All Mail")
        XCTAssertEqual(candidate.mailboxPathComponents, ["[Gmail]", "All Mail"])

        // Negative: no field the JXA side reads may name the logical mailbox.
        XCTAssertNotEqual(candidate.mailboxName, "INBOX")
        XCTAssertFalse(candidate.mailboxPathComponents.contains("INBOX"))
        XCTAssertNotEqual(candidate.mailboxURL, "imap://GMAIL-ACCOUNT/INBOX")

        // Scope of the check, stated so a later reader does not over-read it: today
        // `findMessage` — the locator's only row source — does not project
        // `logical_mailbox_rowid` at all, so swapping this call to `mailboxRef(forRow:)` would
        // not by itself redden this test. What it catches is the change that makes the hazard
        // live: routing `resolve` through a mailbox-scoped query, whose rows DO carry the
        // logical value (half 1 is that query).
    }

    func testEmittedJSCarriesNoMailboxPathForJXAToMatchOn() throws {
        // The JXA side addresses a candidate by account + rowid and never by mailbox name, so
        // the server-side path stays on the Swift side (`headMatchesJXASweep` reads it) and
        // never reaches the script. Asserted on the string that actually reaches JXA, because
        // shipping a path is what invites a name compare back in: `[Gmail]` is Mail's
        // server-side container, and JXA's own mailbox list has no such entry to match it.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(
            messageIds: ["<gmail-only@example.com>"], mailbox: nil, account: nil)
        let js = buildRowidMapJS(refs)

        XCTAssertFalse(js.contains("[Gmail]"))
        XCTAssertFalse(js.contains("\"path\""), "no path key may be emitted")

        let map = try parseRowidMap(js)
        let entry = try XCTUnwrap(map["gmail-only@example.com"]?.first)
        // The leaf name stays: it is the per-message lookup telemetry's "where SQLite said this
        // copy lives", never an argument to a Mail lookup.
        XCTAssertEqual(entry["mb"] as? String, "All Mail")
        XCTAssertNil(entry["path"])
    }

    // MARK: - Message-ID forms

    func testBracketedAndBareRequestsBothResolve() throws {
        let engine = try openFixtureEngine()
        for requested in ["<gmail-only@example.com>", "gmail-only@example.com"] {
            let refs = try engine.resolve(messageIds: [requested], mailbox: nil, account: nil)
            XCTAssertEqual(refs["gmail-only@example.com"]?.count, 1,
                           "request form \(requested) must resolve")
        }
    }

    func testAHeaderStoredWithoutAngleBracketsStillResolves() throws {
        // The old locator bound only "<\(id)>", so any bare-stored header missed and the
        // command fell back to the slow scan silently. `messageIDCandidates` tries both.
        let engine = try openFixtureEngine()
        for requested in ["<bare@example.com>", "bare@example.com"] {
            let refs = try engine.resolve(messageIds: [requested], mailbox: nil, account: nil)
            XCTAssertEqual(refs["bare@example.com"]?.first?.rowid, 204,
                           "request form \(requested) must resolve a bare-stored header")
        }
    }

    func testNormalizeMessageIDForLookupTrimsThenStripsBrackets() throws {
        // Must agree with the JS twin emitted into every script, or the JXA side looks the
        // candidate list up under a key that is not there.
        XCTAssertEqual(normalizeMessageIDForLookup("  <a@b>  "), "a@b")
        XCTAssertEqual(normalizeMessageIDForLookup("<a@b>"), "a@b")
        XCTAssertEqual(normalizeMessageIDForLookup("a@b"), "a@b")
        XCTAssertEqual(normalizeMessageIDForLookup(" a@b "), "a@b")
    }

    // MARK: - Batch contract

    func testEveryRequestedIdIsAKeyIncludingOnesThatResolveToNothing() throws {
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(
            messageIds: ["<gmail-only@example.com>", "<nope@example.com>", "<multi@example.com>"],
            mailbox: nil, account: nil)

        XCTAssertEqual(Set(refs.keys),
                       ["gmail-only@example.com", "nope@example.com", "multi@example.com"])
        XCTAssertEqual(refs["nope@example.com"]?.isEmpty, true)
    }

    // MARK: - Account hard filter

    func testAccountFilterNarrowsCandidatesToThatAccount() throws {
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(
            messageIds: ["<gmail-only@example.com>", "<other-acct@example.com>"],
            mailbox: nil, account: otherAccount)

        XCTAssertEqual(refs["gmail-only@example.com"]?.isEmpty, true)
        XCTAssertEqual(refs["other-acct@example.com"]?.count, 1)
        XCTAssertEqual(refs["other-acct@example.com"]?.first?.accountUUID, otherAccount)
    }

    func testUnresolvableAccountYieldsEmptyCandidatesAndDoesNotThrow() throws {
        // `resolveMailboxes` throws .notFound on an unknown account. A write-path locator
        // must not: under `--engine auto` the JXA scan still runs with its own acctHint and
        // also finds nothing, so the two engines agree. Throwing would fail the write.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(
            messageIds: ["<gmail-only@example.com>"], mailbox: nil,
            account: "no-such-account-4C2F")

        XCTAssertEqual(refs["gmail-only@example.com"]?.isEmpty, true)
    }

    func testAnAMBIGUOUSAccountHintFailsOPENToEmptyCandidates() throws {
        // The other account-hint failure: `accountUUIDs(matching:)` THROWS `.ambiguous` for a
        // name spanning two logical accounts. A write must not inherit that (JXA still
        // completes the write under `--engine auto`), so `resolve`'s `try?` fails OPEN. Every
        // other fixture leaves the throw unreachable; this one reaches it.
        let index = try openFixture(accountsSQL: Self.sharedUsernameAccountRows)

        // Precondition: the throw actually fires here. Without it this test's outcome is
        // indistinguishable from `testUnresolvableAccountYieldsEmptyCandidatesAndDoesNotThrow`
        // above — an account that merely matched nothing — and the swallow would still be
        // untested.
        XCTAssertThrowsError(try index.accountUUIDs(matching: "shared@example.com")) { error in
            guard case EnvelopeIndexError.ambiguous(let message) = error else {
                return XCTFail("fixture precondition: expected .ambiguous, got \(error)")
            }
            XCTAssertTrue(message.contains("multiple logical accounts"))
        }

        let engine = try SQLiteEngine(index: index)

        // Control, same database, same seam: an UNAMBIGUOUS hint still resolves. This is what
        // separates "the swallow fired" from "the accounts store never loaded" — an unwired
        // seam would empty this arm too.
        let unambiguous = try engine.resolve(
            messageIds: ["<gmail-only@example.com>"], mailbox: nil, account: "Shared A")
        XCTAssertEqual(unambiguous["gmail-only@example.com"]?.count, 1)
        XCTAssertEqual(unambiguous["gmail-only@example.com"]?.first?.accountUUID, gmailAccount)

        // The fail-open. A throw out of `resolve` fails this test outright (it propagates);
        // what is asserted is the shape the comment promises — every requested id still a key,
        // every one carrying an empty candidate list, including ids in BOTH of the accounts the
        // ambiguous username spans.
        let refs = try engine.resolve(
            messageIds: ["<gmail-only@example.com>", "<other-acct@example.com>",
                         "<nope@example.com>"],
            mailbox: nil, account: "shared@example.com")

        XCTAssertEqual(Set(refs.keys),
                       ["gmail-only@example.com", "other-acct@example.com", "nope@example.com"])
        for (id, candidates) in refs {
            XCTAssertTrue(candidates.isEmpty, "\(id) must resolve to no candidates")
        }

        // And the same thing as JXA sees it: the comment's claim is about `lookup.candidates`,
        // which the JS side reads off this map. Every array empty is `candidates.length === 0`
        // for every id, so the `whose` scan makes every selection — v3.11's behaviour exactly.
        let map = try parseRowidMap(buildRowidMapJS(refs))
        XCTAssertEqual(Set(map.keys),
                       ["gmail-only@example.com", "other-acct@example.com", "nope@example.com"])
        for (id, entries) in map {
            XCTAssertTrue(entries.isEmpty, "\(id) must reach JXA with an empty candidate array")
        }
    }

    // MARK: - Candidate ordering

    func testPriorityRankSelectsInboxOverTrashRegardlessOfRowOrder() throws {
        // `findMessage` returns date_received DESC, and the Trash copy is the newer one
        // (rowid 202), so trusting row order would select Trash. INBOX (rowid 203) is
        // top-level with a strictly better rank under both readings of the by-name specifier,
        // so it is certified and it is the ONLY candidate emitted.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(messageIds: ["<multi@example.com>"], mailbox: nil, account: nil)
        let candidates = try XCTUnwrap(refs["multi@example.com"])

        XCTAssertEqual(candidates.map { $0.mailboxName }, ["INBOX"])
        XCTAssertEqual(candidates.first?.rowid, 203)
    }

    func testMailboxHintOutranksThePriorityList() throws {
        // The hinted copy is TOP-LEVEL, so v3.11's `mailboxes.whose({name: 'Receipts'})` loop
        // reaches it, and that loop runs before the priority sweep — INBOX's rank 0 does not
        // get to decide. `Receipts` carries no priority entry, so nothing but the hint could
        // select it.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(
            messageIds: ["<hinted@example.com>"], mailbox: "Receipts", account: nil)
        let candidates = try XCTUnwrap(refs["hinted@example.com"])

        XCTAssertEqual(candidates.map { $0.mailboxName }, ["Receipts"])
        XCTAssertEqual(candidates.first?.rowid, 216)
    }

    func testACaseFoldedHintDoesNotDecideBetweenTWOCopies() throws {
        // The Swift hint compare is case-insensitive while Mail's own `whose({name:…})` is a
        // separate implementation of the same idea (it folded case when probed on macOS 26.5,
        // which is not a guarantee across versions). A case-folded hint is therefore not
        // provably the thing that decides in v3.11, so the head is not provably the scan's own
        // pick — decline rather than guess. Same id, same mailboxes as the test above; only
        // the hint's case differs, which is the whole discrimination.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(
            messageIds: ["<hinted@example.com>"], mailbox: "receipts", account: nil)

        XCTAssertEqual(refs["hinted@example.com"]?.isEmpty, true)
    }

    func testAHintTwoCopiesBothAnswerToDoesNotSelectBetweenThem() throws {
        // Top-level `Trash` and the index's `[Gmail]/Trash` share a leaf name, so `--mailbox
        // Trash` matches both and the hint stops discriminating. v3.11's hint loop returns
        // whichever ones its specifier reaches, in an order that is Mail's — so the head here
        // is the scan's own pick only under one reading of how Mail presents that second copy.
        let index = try openFixture()
        XCTAssertEqual(try index.findMessage(messageIDHeader: "<two-trashes@example.com>").count, 2,
                       "fixture precondition: both copies must be present, or the decline is vacuous")

        let refs = try SQLiteEngine(index: index).resolve(
            messageIds: ["<two-trashes@example.com>"], mailbox: "Trash", account: nil)

        XCTAssertEqual(refs["two-trashes@example.com"]?.isEmpty, true)
    }

    func testAHintNoCopyAnswersToLeavesThePriorityOrderInCharge() throws {
        // The hint is not a filter: matching nothing must fall through to the priority sweep,
        // not decline. INBOX is still the certified head and the id stays accelerated.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(
            messageIds: ["<multi@example.com>"], mailbox: "No Such Mailbox", account: nil)
        let candidates = try XCTUnwrap(refs["multi@example.com"])

        XCTAssertEqual(candidates.map { $0.mailboxName }, ["INBOX"])
    }

    func testAHintMatchingANestedLeafDeclinesInsteadOfPromotingThatCopy() throws {
        // The hint matches LEAF names, so "All Mail" promotes the copy the index files under a
        // parent — and whether v3.11's by-name specifier reaches that copy first depends on how
        // Mail presents it (flat on every account probed, nested in principle — issue #67).
        // Declines rather than guess. Also pins leaf- vs joined-path comparison: joined, the
        // hint would match nothing and this would resolve two candidates instead of none.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(
            messageIds: ["<in-both@example.com>"], mailbox: "All Mail", account: nil)

        XCTAssertEqual(refs["in-both@example.com"]?.isEmpty, true)
    }

    // MARK: - Within-account copy selection

    func testANestedCopyOutrankingATopLevelOneIsNotAccelerated() throws {
        // Order is selection within one account too. `[Gmail]/Trash` ranks 9, top-level
        // `Receipts` is unranked, so leaf-name ranking heads the list with the deeper copy —
        // but v3.11's sweep reaches it at rank 9 only if Mail presents it as a top-level
        // `Trash`; if it is a child, the by-name specifier may not reach it at all (issue #67)
        // and the sweep finds it last. Declines rather than guess.
        let index = try openFixture()
        XCTAssertEqual(try index.findMessage(messageIDHeader: "<nested-outranks@example.com>").count, 2,
                       "fixture precondition: both copies must be present, or the decline is vacuous")

        let refs = try SQLiteEngine(index: index).resolve(
            messageIds: ["<nested-outranks@example.com>"], mailbox: nil, account: nil)

        XCTAssertEqual(refs["nested-outranks@example.com"]?.isEmpty, true)
    }

    func testTwoCopiesThePriorityListCannotSeparateAreNotAccelerated() throws {
        // Both top-level, both unranked, so v3.11 reaches neither through the priority sweep:
        // both fall to the final `account.mailboxes()` loop, whose enumeration order is Mail's
        // and is not in the Envelope Index. Ranking them by rowid would be an invention.
        let index = try openFixture()
        XCTAssertEqual(try index.findMessage(messageIDHeader: "<two-unranked@example.com>").count, 2,
                       "fixture precondition: both copies must be present, or the decline is vacuous")

        let refs = try SQLiteEngine(index: index).resolve(
            messageIds: ["<two-unranked@example.com>"], mailbox: nil, account: nil)

        XCTAssertEqual(refs["two-unranked@example.com"]?.isEmpty, true)
    }

    func testACaseVariantOfAPriorityNameIsNotOutrankedByALowerEntry() throws {
        // AppleScript's default string compare FOLDS CASE. `Archive` (rank 4 exact) beats
        // unranked `Inbox` under the exact compare, but a folding `whose({name:'INBOX'})` at
        // p=0 reaches Inbox first — so v3.11 could destroy a different copy while both drift
        // guards pass (same Message-ID). EWS names its inbox `Inbox`, so this is real, not
        // contrived.
        let index = try openFixture()
        XCTAssertEqual(try index.findMessage(messageIDHeader: "<case-variant@example.com>").count, 2,
                       "fixture precondition: both copies must be present, or the decline is vacuous")

        let refs = try SQLiteEngine(index: index).resolve(
            messageIds: ["<case-variant@example.com>"], mailbox: nil, account: nil)

        XCTAssertEqual(refs["case-variant@example.com"]?.isEmpty, true)
    }

    func testTheCaseFoldedRankIsCheckedAgainstTHEWHOLETAILNotTheRunnerUp() throws {
        // The list is sorted by the EXACT rank, so `ranked[1]` is the tail's best under that
        // reading ONLY. Three direct children of one account: `Archive` (exact 4, folding 4),
        // `Receipts` (unranked either way, lower message rowid so it sorts second) and `Inbox`
        // (exact unranked, folding 0). A runner-up-only check compares Archive against
        // Receipts, wins under both readings, and certifies Archive — while a case-folding
        // sweep reaches the `Inbox` copy at p=0, before Archive at p=4. Only a strict win
        // against the MINIMUM over the whole tail declines this.
        let index = try openFixture()
        XCTAssertEqual(try index.findMessage(messageIDHeader: "<three-way@example.com>").count, 3,
                       "fixture precondition: all three copies must be present, or this is vacuous")

        let refs = try SQLiteEngine(index: index).resolve(
            messageIds: ["<three-way@example.com>"], mailbox: nil, account: nil)

        XCTAssertEqual(refs["three-way@example.com"]?.isEmpty, true)
    }

    func testTwoCopiesInTheSAMEMailboxAreNotAccelerated() throws {
        // Two rows in ONE mailbox is the shape the ranking cannot separate, named rather than
        // left to be re-derived: they share a mailbox URL, hence a leaf name, hence a rank, so
        // the priority arm's strict win is unsatisfiable and the hint arm's "no other candidate
        // answers to this hint" clause fails too. Both arms are asserted, because with a hint
        // the decline comes from the other one. (Which copy `byId` would have returned is not
        // the question — it addresses one ROWID and Layer 1 re-verifies what comes back; the
        // question is whether our order is the scan's, and here nothing can establish that.)
        let index = try openFixture()
        XCTAssertEqual(try index.findMessage(messageIDHeader: "<same-mailbox-twice@example.com>").count, 2,
                       "fixture precondition: both rows must be present, or the decline is vacuous")
        let engine = try SQLiteEngine(index: index)

        let noHint = try engine.resolve(
            messageIds: ["<same-mailbox-twice@example.com>"], mailbox: nil, account: nil)
        XCTAssertEqual(noHint["same-mailbox-twice@example.com"]?.isEmpty, true)

        let hinted = try engine.resolve(
            messageIds: ["<same-mailbox-twice@example.com>"], mailbox: "Inbox", account: nil)
        XCTAssertEqual(hinted["same-mailbox-twice@example.com"]?.isEmpty, true)
    }

    func testAPercentEncodedEWSSpecialFolderIsRankedByItsDECODEDName() throws {
        // Exchange stores its special folders with spaces, which the mailbox URL carries
        // percent-encoded (`Sent%20Items`). Ranking happens on the DECODED leaf, so a decode
        // regression would not merely rename the candidate: `Sent%20Items` matches no
        // `mailboxPriority` entry, the head would score unranked against `Archive`'s 4, the
        // strict win would fail and this id would silently stop being accelerated. The rank
        // assertion is the half that makes the certification depend on the decode.
        XCTAssertLessThan(priorityRank(forMailboxName: "Sent Items"),
                          priorityRank(forMailboxName: "Archive"))

        let index = try openFixture()
        XCTAssertEqual(try index.findMessage(messageIDHeader: "<pct-encoded-head@example.com>").count, 2,
                       "fixture precondition: both copies must be present, or this is vacuous")

        let refs = try SQLiteEngine(index: index).resolve(
            messageIds: ["<pct-encoded-head@example.com>"], mailbox: nil, account: nil)

        let candidates = try XCTUnwrap(refs["pct-encoded-head@example.com"])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.mailboxName, "Sent Items")
        XCTAssertEqual(candidates.first?.rowid, 233, "the Sent Items copy, not the Archive one")
    }

    func testACertifiedContestedIdEmitsTheCERTIFIEDHEADALONE() throws {
        // The guard certifies `ranked[0]` and nothing else, but the emitted candidate loop does
        // not stop at the head: it `continue`s past a candidate when the account will not
        // resolve, when that account exposes no mailbox to address the rowid through, and when
        // Layer 1 sees a messageId mismatch. Any of those would land the write on an
        // UNCERTIFIED tail copy, so a certified contested id emits the head alone and a head
        // miss falls to the JXA scan.
        let index = try openFixture()
        XCTAssertEqual(try index.findMessage(messageIDHeader: "<in-both@example.com>").count, 2,
                       "fixture precondition: two copies, or 'head alone' is indistinguishable")

        let refs = try SQLiteEngine(index: index).resolve(
            messageIds: ["<in-both@example.com>"], mailbox: nil, account: nil)
        let candidates = try XCTUnwrap(refs["in-both@example.com"])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.mailboxName, "INBOX")
        XCTAssertEqual(candidates.first?.rowid, 208)
    }

    func testASINGLENestedCopyStaysAccelerated() throws {
        // Counterweight to the two nested-copy declines above: one candidate is no selection
        // to get wrong, and under the carried-labels model this IS the everyday Gmail write
        // (one physical copy under [Gmail]/All Mail, INBOX via `labels`). Declining every
        // nested candidate would turn the acceleration off for the account type this port
        // targets. A deliberate reachability change — Layer 1 still re-verifies before the
        // write.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(
            messageIds: ["<gmail-only@example.com>"], mailbox: nil, account: nil)
        let candidates = try XCTUnwrap(refs["gmail-only@example.com"])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.mailboxPathComponents, ["[Gmail]", "All Mail"])
    }

    // MARK: - On My Mac (local://) mailboxes

    func testALocalCopyNeitherWinsNorBlocksAccelerationOfTheServerCopy() throws {
        // Mail's scripting dictionary declares `account` with POP / IMAP / iCloud subclasses
        // and no local one; On My Mac mailboxes are an element of the APPLICATION. Every JXA
        // lookup on both arms goes through `Mail.accounts()`, so the local copy is invisible
        // to it. Counted, it would make this single-account id look cross-account and decline
        // acceleration for a copy JXA can never act on.
        let index = try openFixture()
        XCTAssertEqual(try index.findMessage(messageIDHeader: "<local-and-server@example.com>").count, 2,
                       "fixture precondition: both copies must be present, or this is vacuous")

        let refs = try SQLiteEngine(index: index).resolve(
            messageIds: ["<local-and-server@example.com>"], mailbox: nil, account: nil)

        let candidates = try XCTUnwrap(refs["local-and-server@example.com"])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.rowid, 229, "the imap INBOX copy, not the On My Mac one")
        XCTAssertEqual(candidates.first?.accountUUID, "GMAIL-ACCOUNT")
    }

    func testAnIdThatOnlyExistsOnMyMacResolvesToNothing() throws {
        // No candidate rather than one JXA cannot resolve: the fast path is skipped and the
        // `whose` scan runs exactly as it does today, minus a wasted account round trip.
        let index = try openFixture()
        XCTAssertEqual(try index.findMessage(messageIDHeader: "<local-only@example.com>").count, 1,
                       "fixture precondition: the local row must be present, or this is vacuous")

        let refs = try SQLiteEngine(index: index).resolve(
            messageIds: ["<local-only@example.com>"], mailbox: nil, account: nil)

        XCTAssertEqual(refs["local-only@example.com"]?.isEmpty, true)
    }

    func testAFileURLCopyNeitherWinsNorBlocksAccelerationOfTheServerCopy() throws {
        // `file://` is the other scheme with no account behind it — `SQLiteEngine.accounts()`
        // skips `local` and `file` side by side for that reason — and it is the worse of the
        // two here: its URL has no account authority at all, so every `file://` row shares one
        // empty account UUID. Counted, it both adds a candidate JXA cannot reach and makes a
        // single-account id look cross-account, declining acceleration outright.
        let index = try openFixture()
        XCTAssertEqual(try index.findMessage(messageIDHeader: "<file-and-server@example.com>").count, 2,
                       "fixture precondition: both copies must be present, or this is vacuous")

        let refs = try SQLiteEngine(index: index).resolve(
            messageIds: ["<file-and-server@example.com>"], mailbox: nil, account: nil)

        let candidates = try XCTUnwrap(refs["file-and-server@example.com"])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.rowid, 236, "the imap INBOX copy, not the file:// one")
        XCTAssertEqual(candidates.first?.accountUUID, "GMAIL-ACCOUNT")
    }

    func testAnIdThatOnlyExistsInAFileURLMailboxResolvesToNothing() throws {
        // As with On My Mac: no candidate rather than one JXA cannot resolve.
        let index = try openFixture()
        XCTAssertEqual(try index.findMessage(messageIDHeader: "<file-only@example.com>").count, 1,
                       "fixture precondition: the file:// row must be present, or this is vacuous")

        let refs = try SQLiteEngine(index: index).resolve(
            messageIds: ["<file-only@example.com>"], mailbox: nil, account: nil)

        XCTAssertEqual(refs["file-only@example.com"]?.isEmpty, true)
    }

    // MARK: - Cross-account copy selection

    func testAMessageIdPresentInTwoAccountsIsNotAcceleratedAtAll() throws {
        // v3.11 is account-OUTER (exhausts one account before the next), so with the message
        // in GMAIL/Trash and OTHER/INBOX it picks Gmail's copy. Ranking by priority alone would
        // invert that and pick a different account's copy — undetectable to either drift guard
        // (same Message-ID). SQLite can't know Mail's account order, so it declines instead.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(
            messageIds: ["<cross-acct@example.com>"], mailbox: nil, account: nil)

        XCTAssertEqual(refs["cross-acct@example.com"]?.isEmpty, true)
    }

    func testDuplicatesWithinONEAccountAreStillAccelerated() throws {
        // The decline above must not swallow every duplicate: two copies in one account stay
        // accelerated when the head is what v3.11's scan reaches first (INBOX, rank 0). Fixture
        // is a plain-IMAP shape, not Gmail's (see `testASINGLENestedCopyStaysAccelerated`).
        // Asserts NOT-DECLINED only; which copy survives is
        // `testACertifiedContestedIdEmitsTheCERTIFIEDHEADALONE`.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(messageIds: ["<in-both@example.com>"], mailbox: nil, account: nil)
        let candidates = try XCTUnwrap(refs["in-both@example.com"])

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertEqual(Set(candidates.compactMap { $0.accountUUID }), [gmailAccount])
    }

    func testAnAccountFilterRestoresAccelerationForACrossAccountId() throws {
        // `--account` is a hard filter applied before the count, so a scoped write is
        // unambiguous about which account it means and keeps the fast path.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(
            messageIds: ["<cross-acct@example.com>"], mailbox: nil, account: gmailAccount)
        let candidates = try XCTUnwrap(refs["cross-acct@example.com"])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.accountUUID, gmailAccount)
        XCTAssertEqual(candidates.first?.mailboxName, "Trash")
    }

    func testCopiesStoredInDIFFERENTHEADERFORMSAreAllSeenBeforeTheDecision() throws {
        // The decline above can only be as complete as the row set it counts. `findMessage`
        // matches `message_id_header` EXACTLY, and the candidate loop used to stop at the
        // first form that returned rows — so a Message-ID stored bracketed in one account
        // and bare in another was seen as single-account, the guard passed, and the fast
        // path picked one copy while JXA (which matches Mail's own normalized `messageId`
        // property, not the stored bytes) would have seen both. `messageIDCandidates` exists
        // because bare storage happens in the wild, so this is reachable, not theoretical.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(messageIds: ["<mixed@example.com>"], mailbox: nil, account: nil)

        XCTAssertEqual(refs["mixed@example.com"]?.isEmpty, true)
    }

    func testBothHeaderFormsAreUnionedNotShortCircuited() throws {
        // Same union mechanism, both copies in one account: shows up as SELECTION, not a
        // count. `messageIDCandidates` yields the bracketed form first, which alone would
        // certify the wrong copy (rowid 213); unioning finds the bare-stored INBOX copy (214,
        // outranks Trash), so the two rowids are what discriminate.
        let index = try openFixture()
        XCTAssertEqual(try index.findMessage(messageIDHeader: "<mixedsame@example.com>")
                        .compactMap { $0["rowid"] as? Int64 }, [213],
                       "precondition: the bracketed form alone resolves to the Trash copy, "
                        + "which is what makes the unioned head a different physical copy")

        let refs = try SQLiteEngine(index: index).resolve(
            messageIds: ["mixedsame@example.com"], mailbox: nil, account: nil)
        let candidates = try XCTUnwrap(refs["mixedsame@example.com"])

        XCTAssertEqual(candidates.map { $0.mailboxName }, ["INBOX"])
        XCTAssertEqual(candidates.first?.rowid, 214)
    }

    // MARK: - Deleted rows

    func testATombstonedRowProducesNoCandidate() throws {
        // `findMessage` filters m.deleted = 0. A deleted=1 ROWID is not addressable from
        // JXA anyway, so the message takes the slow path rather than a doomed byId.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(messageIds: ["<deleted@example.com>"], mailbox: nil, account: nil)

        XCTAssertEqual(refs["deleted@example.com"]?.isEmpty, true)
    }

    // MARK: - buildRowidMapJS shape

    func testRowidMapKeysAreBracketStrippedAndValuesAreCandidateArrays() throws {
        // The JS contract is an ARRAY per id — the finder loops it — even though a contested id
        // now contributes exactly one element (the certified head).
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(messageIds: ["<multi@example.com>"], mailbox: nil, account: nil)
        let map = try parseRowidMap(buildRowidMapJS(refs))

        XCTAssertEqual(Array(map.keys), ["multi@example.com"])
        let entries = try XCTUnwrap(map["multi@example.com"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.map { $0["mb"] as? String }, ["INBOX"])
        XCTAssertEqual(entries.first?["r"] as? Int64, 203)
        XCTAssertEqual(entries.first?["acctId"] as? String, gmailAccount)
    }

    func testRowidMapOmitsAccountNameWhenTheAccountsStoreDoesNotKnowIt() throws {
        // The fixture's account UUIDs are synthetic, so `accountNames()` has no entry and
        // `acct` must be absent. `acctId` (matched against JXA `account.id()`) is the robust
        // key; `acct` is only the fallback.
        let engine = try openFixtureEngine()
        let refs = try engine.resolve(messageIds: ["<gmail-only@example.com>"], mailbox: nil, account: nil)
        let entry = try XCTUnwrap(try parseRowidMap(buildRowidMapJS(refs))["gmail-only@example.com"]?.first)

        XCTAssertNotNil(entry["acctId"])
        XCTAssertNil(entry["acct"])
    }

    func testEmptyResolutionEmitsAnEmptyObject() throws {
        // The Full-Disk-Access-absent contract: an empty map means `candidates.length === 0`
        // for every id, so the JXA `whose` scan runs exactly as it does today.
        XCTAssertEqual(buildRowidMapJS([:]), "{}")
    }

    func testAnIdThatResolvedToNothingEmitsAnEmptyCandidateArray() throws {
        let js = buildRowidMapJS(["a@b": []])
        let map = try parseRowidMap(js)
        XCTAssertEqual(map["a@b"]?.isEmpty, true)
    }

    // MARK: - The finder the write commands embed

    func testTheWriteFinderSeamEmitsTheUnifiedFinderNotALegacyOne() throws {
        // All five write commands build their `findMsg` through this one function. The legacy
        // finders are still live on the read side and take the same hints, so a swap here
        // would compile and would silently drop both the rowid fast path and the post-`byId`
        // messageId verify that makes it safe. Asserting the seam is what stops that being
        // invisible; `--engine jxa` is used so the assertion needs no Envelope Index.
        let finder = try unifiedWriteFinderJXA(
            for: ["<m@x>"], mailbox: nil, account: nil, engine: .jxa)

        XCTAssertTrue(finder.contains("const rowidMap = {\"m@x\":[]};"),
                      "the seam must emit the resolved rowid map")
        XCTAssertTrue(finder.contains("mb.messages.byId(cand.r)"),
                      "the seam must emit the rowid fast path")
        XCTAssertTrue(finder.contains("normalizeMessageId(msg.messageId()) === normalized"),
                      "the seam must emit the post-byId messageId verify")
        XCTAssertTrue(finder.contains("function getLookupSummary()"),
                      "the seam must emit the locator telemetry helper")
        XCTAssertTrue(finder.contains("const _locatorBackend = 'jxa-only';"),
                      "the seam must report the backend it actually built")
    }

    // MARK: - Noop locator / engine selection

    func testJXAEngineBuildsANoopLocatorThatNeverResolvesAnything() throws {
        let locator = try makeMessageLocator(engine: .jxa)
        XCTAssertFalse(locator.isAvailable())

        let refs = try locator.resolve(
            messageIds: ["<a@b>", "c@d"], mailbox: "INBOX", account: "Anything")
        XCTAssertEqual(Set(refs.keys), ["a@b", "c@d"])
        XCTAssertEqual(refs["a@b"]?.isEmpty, true)
        XCTAssertEqual(refs["c@d"]?.isEmpty, true)
    }

    func testJXAEngineResolutionReportsTheJXAOnlyBackend() throws {
        // The backend label is what the acceptance evidence reads to tell "byId fast path
        // working" from "silently falling back to the same slow scan".
        let resolved = try resolveRowidMap(
            for: ["<a@b>"], mailbox: nil, account: nil, engine: .jxa)
        XCTAssertEqual(resolved.backend, "jxa-only")
        XCTAssertEqual(try parseRowidMap(resolved.js)["a@b"]?.isEmpty, true)
    }

    // MARK: - Fixture

    private func parseRowidMap(_ js: String) throws -> [String: [[String: Any]]] {
        let data = try XCTUnwrap(js.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: [[String: Any]]])
    }

    private func openFixtureEngine() throws -> SQLiteEngine {
        try SQLiteEngine(index: try openFixture())
    }

    /// Build a throwaway Envelope Index and open it through the production reader.
    /// `extraSQL` is appended verbatim after the base schema and rows, for the one test that
    /// needs a `labels` table the rest of the file deliberately does without. `accountsSQL`,
    /// when given, builds an accounts store at the seam path below, for the one test that
    /// needs `accountNames()` to answer with something.
    private func openFixture(extraSQL: String = "",
                             accountsSQL: String? = nil) throws -> EnvelopeIndex {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("Envelope Index")

        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            dbPath.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openResult == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw EnvelopeIndexError.notAvailable("Fixture open failed: code \(openResult)")
        }

        let rc = sqlite3_exec(handle, Self.schema + Self.rows + extraSQL, nil, nil, nil)
        let detail = rc == SQLITE_OK ? "" : String(cString: sqlite3_errmsg(handle))
        sqlite3_close_v2(handle)
        guard rc == SQLITE_OK else {
            throw EnvelopeIndexError.queryFailed("Fixture setup failed: \(detail)")
        }

        // The accounts store is always addressed inside the throwaway directory, so no test
        // here can read the developer's real `Accounts4.sqlite`. Without `accountsSQL` the
        // file is simply never created and `accountNames()` returns an empty map.
        let accountsPath = tempDir.appendingPathComponent("Accounts4.sqlite")
        if let accountsSQL {
            try createDatabase(at: accountsPath, sql: accountsSQL)
        }

        return try EnvelopeIndex(databasePath: dbPath, accountsDatabasePath: accountsPath)
    }

    private func createDatabase(at path: URL, sql: String) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            path.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openResult == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw EnvelopeIndexError.notAvailable("Fixture open failed: code \(openResult)")
        }

        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        let detail = result == SQLITE_OK ? "" : String(cString: sqlite3_errmsg(handle))
        sqlite3_close_v2(handle)
        guard result == SQLITE_OK else {
            throw EnvelopeIndexError.queryFailed("Fixture setup failed: \(detail)")
        }
    }

    /// Accounts store where ONE username spans TWO logical accounts (`accountUUIDs(matching:)`
    /// throws `.ambiguous`) — `EnvelopeIndexAccountTests`' SHARED-PARENT pair, children rebound
    /// to this file's mailbox hosts. Description/username are NULL on the children, carried by
    /// parents via the production COALESCE join, so `shared@example.com` can only match via the
    /// username branch.
    private static let sharedUsernameAccountRows = """
        CREATE TABLE ZACCOUNT (
            Z_PK INTEGER PRIMARY KEY,
            ZIDENTIFIER TEXT,
            ZACCOUNTDESCRIPTION TEXT,
            ZUSERNAME TEXT,
            ZPARENTACCOUNT INTEGER
        );
        INSERT INTO ZACCOUNT
            (Z_PK, ZIDENTIFIER, ZACCOUNTDESCRIPTION, ZUSERNAME, ZPARENTACCOUNT)
        VALUES
            (1, 'SHARED-PARENT-A', 'Shared A', 'shared@example.com', NULL),
            (2, 'GMAIL-ACCOUNT', NULL, NULL, 1),
            (3, 'SHARED-PARENT-B', 'Shared B', 'shared@example.com', NULL),
            (4, 'OTHER-ACCOUNT', NULL, NULL, 3);
        """

    /// A Gmail label membership for message 201, whose PHYSICAL home is `[Gmail]/All Mail`:
    /// the message is *displayed* in INBOX (mailbox 2) but *stored* under All Mail. This is
    /// the shape the carried labels fix models, and the only fixture in this file where the
    /// logical and physical mailbox differ.
    private static let gmailLabelRows = """
        CREATE TABLE labels (message_id INTEGER REFERENCES messages(ROWID) ON DELETE CASCADE,
        mailbox_id INTEGER REFERENCES mailboxes(ROWID) ON DELETE CASCADE,
        PRIMARY KEY(message_id, mailbox_id)) WITHOUT ROWID;
        CREATE INDEX labels_mailbox_id_index on labels(mailbox_id);

        INSERT INTO labels (message_id, mailbox_id) VALUES (201, 2);

        """

    /// Mail's own CREATE TABLE statements, copied from a live Envelope Index (the same
    /// subset `EnvelopeIndexLabelsTests` pins). No `labels` table: the locator resolves by
    /// message-id, never by mailbox scope, so the Gmail labels arm is not in its path.
    private static let schema = """
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id INTEGER NOT NULL DEFAULT 0,
        global_message_id INTEGER NOT NULL,
        remote_id INTEGER,
        document_id TEXT COLLATE BINARY,
        sender INTEGER,
        subject_prefix TEXT COLLATE BINARY,
        subject INTEGER NOT NULL,
        summary INTEGER,
        date_sent INTEGER,
        date_received INTEGER,
        mailbox INTEGER NOT NULL,
        remote_mailbox INTEGER,
        flags INTEGER NOT NULL DEFAULT 0,
        read INTEGER NOT NULL DEFAULT 0,
        flagged INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        size INTEGER NOT NULL DEFAULT 0,
        conversation_id INTEGER NOT NULL DEFAULT 0,
        date_last_viewed INTEGER,
        list_id_hash INTEGER,
        unsubscribe_type INTEGER,
        searchable_message INTEGER,
        brand_indicator INTEGER,
        display_date INTEGER,
        flag_color INTEGER,
        is_urgent INTEGER NOT NULL DEFAULT 0,
        color TEXT COLLATE BINARY,
        type INTEGER,
        fuzzy_ancestor INTEGER,
        automated_conversation INTEGER DEFAULT 0,
        root_status INTEGER DEFAULT -1);

        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT COLLATE BINARY NOT NULL,
        total_count INTEGER NOT NULL DEFAULT 0,
        unread_count INTEGER NOT NULL DEFAULT 0,
        deleted_count INTEGER NOT NULL DEFAULT 0,
        unseen_count INTEGER NOT NULL DEFAULT 0,
        unread_count_adjusted_for_duplicates INTEGER NOT NULL DEFAULT 0,
        change_identifier TEXT COLLATE BINARY,
        source INTEGER,
        alleged_change_identifier TEXT COLLATE BINARY,
        UNIQUE(url) ON CONFLICT ABORT);

        CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id INTEGER,
        follow_up_start_date INTEGER,
        follow_up_end_date INTEGER,
        follow_up_jsonstringformodelevaluationforsuggestions TEXT COLLATE BINARY,
        download_state INTEGER NOT NULL DEFAULT 0,
        read_later_date INTEGER,
        send_later_date INTEGER,
        validation_state INTEGER NOT NULL DEFAULT 0,
        model_category INTEGER,
        model_subcategory INTEGER,
        category_model_version INTEGER,
        category_is_temporary INTEGER,
        model_analytics TEXT COLLATE BINARY,
        model_high_impact INTEGER NOT NULL DEFAULT 0,
        generated_summary INTEGER,
        urgent INTEGER,
        message_id_header TEXT COLLATE BINARY,
        UNIQUE(message_id) ON CONFLICT ABORT);

        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        subject TEXT COLLATE RTRIM NOT NULL,
        UNIQUE(subject) ON CONFLICT ABORT);

        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        address TEXT COLLATE NOCASE NOT NULL,
        comment TEXT COLLATE BINARY NOT NULL,
        UNIQUE(address, comment) ON CONFLICT ABORT);

        CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        message INTEGER NOT NULL REFERENCES messages(ROWID) ON DELETE CASCADE,
        attachment_id TEXT COLLATE BINARY,
        name TEXT COLLATE BINARY,
        UNIQUE(message, attachment_id) ON CONFLICT ABORT);

        """

    /// Mailboxes 1/4 nest two deep under Gmail (leaf-vs-path); 5 is a second account's INBOX
    /// (cross-account selection); 6/7 are top-level and unranked (within-account cases); 3/9/10
    /// are direct children of the second account (case-folding: `Inbox` unranked exact, rank 0
    /// folding — EWS's real spelling); 11 is `local://` ("On My Mac") and 13 is `file://`,
    /// neither of which any JXA account can reach; 12 is an EWS special folder named only after
    /// percent-decoding. Headers 1-2, 4-23 stored bracketed; header 3 stored bare.
    private static let rows = """
        INSERT INTO mailboxes (ROWID, url) VALUES
        (1, 'imap://GMAIL-ACCOUNT/%5BGmail%5D/All%20Mail'),
        (2, 'imap://GMAIL-ACCOUNT/INBOX'),
        (3, 'ews://OTHER-ACCOUNT/Inbox'),
        (4, 'imap://GMAIL-ACCOUNT/%5BGmail%5D/Trash'),
        (5, 'ews://OTHER-ACCOUNT/INBOX'),
        (6, 'imap://GMAIL-ACCOUNT/Receipts'),
        (7, 'imap://GMAIL-ACCOUNT/Old%20Mail'),
        (8, 'imap://GMAIL-ACCOUNT/Trash'),
        (9, 'ews://OTHER-ACCOUNT/Archive'),
        (10, 'ews://OTHER-ACCOUNT/Receipts'),
        (11, 'local://LOCAL-ACCOUNT/Saved'),
        (12, 'ews://OTHER-ACCOUNT/Sent%20Items'),
        (13, 'file:///Users/example/Library/Mail/V10/Mailboxes/Saved.mbox');

        INSERT INTO addresses (ROWID, address, comment) VALUES
        (1, 'sender@example.com', 'Example Sender');

        INSERT INTO subjects (ROWID, subject) VALUES (1, 'Fixture subject');

        INSERT INTO message_global_data (ROWID, message_id_header) VALUES
        (1, '<gmail-only@example.com>'),
        (2, '<multi@example.com>'),
        (3, 'bare@example.com'),
        (4, '<deleted@example.com>'),
        (5, '<other-acct@example.com>'),
        (6, '<in-both@example.com>'),
        (7, '<cross-acct@example.com>'),
        (8, '<mixed@example.com>'),
        (9, 'mixed@example.com'),
        (10, '<mixedsame@example.com>'),
        (11, 'mixedsame@example.com'),
        (12, '<hinted@example.com>'),
        (13, '<nested-outranks@example.com>'),
        (14, '<two-unranked@example.com>'),
        (15, '<two-trashes@example.com>'),
        (16, '<case-variant@example.com>'),
        (17, '<three-way@example.com>'),
        (18, '<local-and-server@example.com>'),
        (19, '<local-only@example.com>'),
        (20, '<same-mailbox-twice@example.com>'),
        (21, '<pct-encoded-head@example.com>'),
        (22, '<file-and-server@example.com>'),
        (23, '<file-only@example.com>');

        INSERT INTO messages
        (ROWID, global_message_id, sender, subject, date_received, date_sent, mailbox, read, deleted)
        VALUES
        (201, 1, 1, 1, 2000, 2000, 1, 0, 0),
        (202, 2, 1, 1, 3000, 3000, 4, 0, 0),
        (203, 2, 1, 1, 1000, 1000, 2, 0, 0),
        (204, 3, 1, 1, 2000, 2000, 2, 0, 0),
        (205, 4, 1, 1, 2000, 2000, 2, 0, 1),
        (206, 5, 1, 1, 2000, 2000, 3, 0, 0),
        (207, 6, 1, 1, 2000, 2000, 1, 0, 0),
        (208, 6, 1, 1, 1000, 1000, 2, 0, 0),
        (209, 7, 1, 1, 3000, 3000, 4, 0, 0),
        (210, 7, 1, 1, 1000, 1000, 5, 0, 0),
        (211, 8, 1, 1, 3000, 3000, 4, 0, 0),
        (212, 9, 1, 1, 1000, 1000, 5, 0, 0),
        (213, 10, 1, 1, 3000, 3000, 4, 0, 0),
        (214, 11, 1, 1, 1000, 1000, 2, 0, 0),
        (215, 12, 1, 1, 1000, 1000, 2, 0, 0),
        (216, 12, 1, 1, 3000, 3000, 6, 0, 0),
        (217, 13, 1, 1, 1000, 1000, 4, 0, 0),
        (218, 13, 1, 1, 3000, 3000, 6, 0, 0),
        (219, 14, 1, 1, 3000, 3000, 6, 0, 0),
        (220, 14, 1, 1, 1000, 1000, 7, 0, 0),
        (221, 15, 1, 1, 1000, 1000, 8, 0, 0),
        (222, 15, 1, 1, 3000, 3000, 4, 0, 0),
        (223, 16, 1, 1, 1000, 1000, 9, 0, 0),
        (224, 16, 1, 1, 2000, 2000, 3, 0, 0),
        (225, 17, 1, 1, 1000, 1000, 9, 0, 0),
        (226, 17, 1, 1, 2000, 2000, 10, 0, 0),
        (227, 17, 1, 1, 3000, 3000, 3, 0, 0),
        (228, 18, 1, 1, 3000, 3000, 11, 0, 0),
        (229, 18, 1, 1, 1000, 1000, 2, 0, 0),
        (230, 19, 1, 1, 2000, 2000, 11, 0, 0),
        (231, 20, 1, 1, 1000, 1000, 3, 0, 0),
        (232, 20, 1, 1, 3000, 3000, 3, 0, 0),
        (233, 21, 1, 1, 1000, 1000, 12, 0, 0),
        (234, 21, 1, 1, 3000, 3000, 9, 0, 0),
        (235, 22, 1, 1, 3000, 3000, 13, 0, 0),
        (236, 22, 1, 1, 1000, 1000, 2, 0, 0),
        (237, 23, 1, 1, 2000, 2000, 13, 0, 0);

        """
}
