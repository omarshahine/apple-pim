import Contacts
import XCTest

@testable import ContactsCLI

/// Tests for the identifier-preserving multivalue merge used by `contacts-cli
/// update` (see mergeLabeledStrings/mergeLabeledPhones). Reusing existing
/// CNLabeledValue instances keeps their identifiers stable so the save diff is
/// limited to genuine adds/removes/label edits.
final class LabeledValueMergeTests: XCTestCase {

    private func email(_ label: String?, _ value: String) -> CNLabeledValue<NSString> {
        CNLabeledValue(label: label, value: value as NSString)
    }

    private func phone(_ label: String?, _ value: String) -> CNLabeledValue<CNPhoneNumber> {
        CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: value))
    }

    // MARK: - Emails

    func testEmailMergeReusesIdentifierForUnchangedValue() {
        let existing = [email(CNLabelHome, "a@example.com")]
        let merged = mergeLabeledStrings(
            existing: existing,
            desired: [email(CNLabelHome, "a@example.com")]
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].identifier, existing[0].identifier)
    }

    func testEmailMergeMatchesValueCaseInsensitively() {
        let existing = [email(CNLabelHome, "A@Example.com")]
        let merged = mergeLabeledStrings(
            existing: existing,
            desired: [email(CNLabelHome, "a@example.com")]
        )
        XCTAssertEqual(merged[0].identifier, existing[0].identifier)
        // The original stored value wins when only casing differs.
        XCTAssertEqual(merged[0].value as String, "A@Example.com")
    }

    func testEmailMergeAppendsNewValueWithNewIdentifier() {
        let existing = [email(CNLabelHome, "a@example.com")]
        let merged = mergeLabeledStrings(
            existing: existing,
            desired: [
                email(CNLabelHome, "a@example.com"),
                email(CNLabelWork, "b@example.com"),
            ]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].identifier, existing[0].identifier)
        XCTAssertNotEqual(merged[1].identifier, existing[0].identifier)
        XCTAssertEqual(merged[1].value as String, "b@example.com")
    }

    func testEmailMergeDropsOmittedValues() {
        let existing = [
            email(CNLabelHome, "keep@example.com"),
            email(CNLabelWork, "drop@example.com"),
        ]
        let merged = mergeLabeledStrings(
            existing: existing,
            desired: [email(CNLabelHome, "keep@example.com")]
        )
        XCTAssertEqual(merged.map { $0.value as String }, ["keep@example.com"])
        XCTAssertEqual(merged[0].identifier, existing[0].identifier)
    }

    func testEmailMergeRelabelsExistingValueKeepingIdentifier() {
        let existing = [email(CNLabelHome, "a@example.com")]
        let merged = mergeLabeledStrings(
            existing: existing,
            desired: [email(CNLabelWork, "a@example.com")]
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].label, CNLabelWork)
        XCTAssertEqual(merged[0].identifier, existing[0].identifier)
    }

    func testEmailMergeHandlesDuplicateDesiredValues() {
        let existing = [email(CNLabelHome, "a@example.com")]
        let merged = mergeLabeledStrings(
            existing: existing,
            desired: [
                email(CNLabelHome, "a@example.com"),
                email(CNLabelOther, "a@example.com"),
            ]
        )
        // First occurrence reuses the existing entry; the duplicate becomes a
        // fresh entry rather than stealing the same instance twice.
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].identifier, existing[0].identifier)
        XCTAssertNotEqual(merged[1].identifier, existing[0].identifier)
    }

    // MARK: - Phones

    func testPhoneMergeReusesIdentifierForUnchangedValue() {
        let existing = [phone(CNLabelPhoneNumberMobile, "+1 (206) 555-0100")]
        let merged = mergeLabeledPhones(
            existing: existing,
            desired: [phone(CNLabelPhoneNumberMobile, "+1 (206) 555-0100")]
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].identifier, existing[0].identifier)
    }

    func testPhoneMergeAppendsAndDrops() {
        let existing = [
            phone(CNLabelPhoneNumberMobile, "+1 (206) 555-0100"),
            phone(CNLabelHome, "+1 (206) 555-0111"),
        ]
        let merged = mergeLabeledPhones(
            existing: existing,
            desired: [
                phone(CNLabelPhoneNumberMobile, "+1 (206) 555-0100"),
                phone(CNLabelWork, "+1 (206) 555-0122"),
            ]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].identifier, existing[0].identifier)
        XCTAssertEqual(merged[1].value.stringValue, "+1 (206) 555-0122")
    }

    func testPhoneMergeRelabelsKeepingIdentifier() {
        let existing = [phone(CNLabelPhoneNumberMobile, "+1 (206) 555-0100")]
        let merged = mergeLabeledPhones(
            existing: existing,
            desired: [phone(CNLabelWork, "+1 (206) 555-0100")]
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].label, CNLabelWork)
        XCTAssertEqual(merged[0].identifier, existing[0].identifier)
    }

    // MARK: - AppleScript escaping (fallback path)

    func testAppleScriptEscaping() {
        XCTAssertEqual(appleScriptEscaped(#"plain"#), "plain")
        XCTAssertEqual(appleScriptEscaped(#"a "quoted" value"#), #"a \"quoted\" value"#)
        XCTAssertEqual(appleScriptEscaped(#"back\slash"#), #"back\\slash"#)
    }
}
