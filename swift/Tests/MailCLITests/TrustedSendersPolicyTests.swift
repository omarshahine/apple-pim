import Foundation
import XCTest
@testable import MailCLI

/// How `auth-check` reacts to the state of its policy file. A security check that no-ops
/// when its config is missing is worse than one the operator knows is switched off, so
/// these pin which states continue and which refuse.
final class TrustedSendersPolicyTests: XCTestCase {
    private lazy var tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailcli-policy-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testAbsentFileContinuesWithNobodyEnrolled() {
        let path = tempDir.appendingPathComponent("missing.json").path

        guard case .absent(let warning) = loadTrustedSendersPolicy(at: path) else {
            return XCTFail("A missing policy file must not stop header evaluation")
        }
        XCTAssertTrue(warning.contains("no sender is enrolled"), warning)
        XCTAssertTrue(warning.contains(path), warning)
    }

    func testMalformedFileRefusesToEvaluate() throws {
        let path = tempDir.appendingPathComponent("broken.json").path
        try "{ not json".write(toFile: path, atomically: true, encoding: .utf8)

        guard case .unreadable(let message) = loadTrustedSendersPolicy(at: path) else {
            return XCTFail("A policy that exists but will not parse must fail loudly")
        }
        XCTAssertTrue(message.contains(path), message)
        // The operator's policy is not being applied; say so rather than quietly
        // evaluating against an empty one.
        XCTAssertTrue(message.contains("failed to load"), message)
    }

    func testUnreadableFileIsAMisconfigurationNotAnAbsence() {
        // `Data(contentsOf:)` fails on a directory, but the path is present: the operator
        // put something there, so absence is the wrong reading.
        guard case .unreadable = loadTrustedSendersPolicy(at: tempDir.path) else {
            return XCTFail("A present-but-unreadable path must not be treated as absent")
        }
    }

    func testValidFileLoads() throws {
        let path = tempDir.appendingPathComponent("good.json").path
        try """
        {"version": 1,
         "trustedSenders": [{"name": "Friend", "emails": ["friend@example.com"],
                             "expectedDkimDomains": ["example.com"]}],
         "trustedAuthservIds": {"*": ["mx.example.com"]}}
        """.write(toFile: path, atomically: true, encoding: .utf8)

        guard case .loaded(let file) = loadTrustedSendersPolicy(at: path) else {
            return XCTFail("Expected the policy to load")
        }
        XCTAssertEqual(file.trustedSenders.first?.emails, ["friend@example.com"])
        XCTAssertEqual(file.trustedAuthservIds?["*"], ["mx.example.com"])
    }

    func testUnevaluatedPayloadSaysSoExplicitly() {
        let payload = unevaluatedAuthPayload(
            verdict: "unknown", sender: "someone@example.com",
            matchedContact: "", warnings: ["nothing ran"])

        // `unknown` alone is ambiguous between "checked, inconclusive" and "never checked".
        XCTAssertEqual(payload["evaluated"] as? Bool, false)
        XCTAssertTrue((payload["checks"] as? [String: Any])?.isEmpty ?? false)
        XCTAssertEqual(payload["sender"] as? String, "someone@example.com")
    }
}
