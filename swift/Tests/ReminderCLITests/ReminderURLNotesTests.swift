import XCTest
@testable import ReminderCLI

/// `EKReminder.url` round-trips through EventKit and syncs, but Apple Reminders renders it
/// nowhere, so a link written only there is invisible to the person the reminder is for.
/// These pin the mirroring that makes a link actually visible, and the removal that keeps
/// the visible copy from outliving the stored one.
final class ReminderURLNotesTests: XCTestCase {

    // MARK: - Create

    func testURLIsAppendedAsItsOwnLineToExistingNotes() {
        XCTAssertEqual(
            notesWithVisibleURL("Call the dentist", url: "https://example.com/booking"),
            "Call the dentist\n🔗 https://example.com/booking")
    }

    func testURLBecomesTheNotesWhenThereAreNone() {
        XCTAssertEqual(
            notesWithVisibleURL(nil, url: "https://example.com/x"),
            "🔗 https://example.com/x")
        XCTAssertEqual(
            notesWithVisibleURL("", url: "https://example.com/x"),
            "🔗 https://example.com/x")
    }

    func testNonHTTPDeepLinksRoundTrip() {
        // The case from the report: a custom-scheme deep link that persisted and synced
        // through EventKit without appearing anywhere in Apple Reminders.
        let deepLink = "example-app://open/item?id=42"
        let notes = try? XCTUnwrap(notesWithVisibleURL(nil, url: deepLink))
        XCTAssertEqual(notes, "🔗 \(deepLink)")
        XCTAssertNil(notesWithoutVisibleURL(notes ?? "", url: deepLink))
    }

    func testAnAlreadyVisibleURLIsNotDuplicated() {
        // Re-applying the same URL, or one the caller already typed into their notes,
        // must not stack copies — a second copy would survive the first one's removal.
        let mirrored = "Notes\n🔗 https://example.com/x"
        XCTAssertEqual(notesWithVisibleURL(mirrored, url: "https://example.com/x"), mirrored)

        let handWritten = "See https://example.com/x"
        XCTAssertEqual(
            notesWithVisibleURL(handWritten, url: "https://example.com/x"),
            "See https://example.com/x\n🔗 https://example.com/x")
        let handWrittenAlone = "https://example.com/x"
        XCTAssertEqual(
            notesWithVisibleURL(handWrittenAlone, url: "https://example.com/x"),
            handWrittenAlone)
    }

    func testBlankURLLeavesNotesAlone() {
        XCTAssertEqual(notesWithVisibleURL("Just notes", url: ""), "Just notes")
        XCTAssertEqual(notesWithVisibleURL("Just notes", url: "   "), "Just notes")
    }

    // MARK: - Clearing

    func testClearingRemovesOnlyTheMirroredLine() {
        let notes = "Line one\n🔗 https://example.com/x\nLine two"
        XCTAssertEqual(
            notesWithoutVisibleURL(notes, url: "https://example.com/x"),
            "Line one\nLine two")
    }

    func testClearingLeavesNilWhenTheMirrorWasTheWholeNote() {
        XCTAssertNil(notesWithoutVisibleURL("🔗 https://example.com/x", url: "https://example.com/x"))
    }

    func testClearingDoesNotTouchAURLTheCallerTyped() {
        // Their prose is their text, not our bookkeeping.
        let notes = "Booking page: https://example.com/x"
        XCTAssertEqual(notesWithoutVisibleURL(notes, url: "https://example.com/x"), notes)
    }

    func testClearingADifferentURLLeavesTheMirrorInPlace() {
        let notes = "🔗 https://example.com/x"
        XCTAssertEqual(notesWithoutVisibleURL(notes, url: "https://example.com/other"), notes)
    }

    func testClearingHandlesEmptyAndAbsentNotes() {
        XCTAssertNil(notesWithoutVisibleURL(nil, url: "https://example.com/x"))
        XCTAssertEqual(notesWithoutVisibleURL("", url: "https://example.com/x"), "")
        XCTAssertEqual(notesWithoutVisibleURL("Keep me", url: ""), "Keep me")
    }

    // MARK: - Replace

    func testReplacingSwapsTheMirroredLine() {
        // What `update --url` does: drop the old mirror, then add the new one.
        let original = "Context\n🔗 https://example.com/old"
        let cleared = notesWithoutVisibleURL(original, url: "https://example.com/old")
        XCTAssertEqual(
            notesWithVisibleURL(cleared, url: "https://example.com/new"),
            "Context\n🔗 https://example.com/new")
    }
}
