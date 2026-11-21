import XCTest

@testable import MailCLI

final class AuthCheckDKIMTests: XCTestCase {
    private func evaluate(_ results: String, expected: [String] = ["example.com"])
        throws -> (verdict: String, dkim: [String: Any], warnings: [String])
    {
        let policy = TrustedSendersFile(
            version: 1,
            trustedSenders: [
                TrustedSender(name: "Example Sender", emails: ["sender@example.com"],
                              expectedDkimDomains: expected, requireSpf: true),
            ],
            trustedAuthservIds: ["Test": ["mx.example.net"]]
        )
        let payload = AuthCheck().evaluateAuthPayload(
            msgDict: [
                "senderAddress": "sender@example.com",
                "account": "Test",
                "allHeaders": """
                    Authentication-Results: mx.example.net;
                      \(results);
                      spf=pass smtp.mailfrom=sender@example.com
                    """,
            ],
            trustedFile: policy
        )
        XCTAssertEqual(payload["evaluated"] as? Bool, true)
        let checks = try XCTUnwrap(payload["checks"] as? [String: Any])
        return (
            try XCTUnwrap(payload["verdict"] as? String),
            try XCTUnwrap(checks["dkim"] as? [String: Any]),
            try XCTUnwrap(payload["warnings"] as? [String])
        )
    }

    func testPassWithoutReportedSigningDomainIsNotASignerMatch() throws {
        let report = try evaluate("dkim=pass header.i=@example.com header.s=test")
        XCTAssertEqual(report.verdict, "suspicious")
        XCTAssertEqual(report.dkim["result"] as? String, "pass")
        XCTAssertEqual(report.dkim["signingDomain"] as? String, "")
        XCTAssertEqual(report.dkim["match"] as? Bool, false)
        XCTAssertTrue(report.warnings.contains { $0.contains("did not report the signing domain (header.d)") })
        XCTAssertFalse(report.warnings.contains { $0.contains("signing domain mismatch") })
    }

    func testExplicitMatchingSigningDomainStillVerifiesWithAnotherPassMissingDomain() throws {
        let report = try evaluate("dkim=pass header.i=@example.net; dkim=pass header.d=example.com header.i=@sub.example.com")
        XCTAssertEqual(report.verdict, "verified")
        XCTAssertEqual(report.dkim["signingDomain"] as? String, "example.com")
        XCTAssertEqual(report.dkim["match"] as? Bool, true)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testReportedPassingSignerIsPreferredOverPassWithoutDomain() throws {
        let report = try evaluate("dkim=pass header.i=@example.com; dkim=pass header.d=example.net")
        XCTAssertEqual(report.verdict, "suspicious")
        XCTAssertEqual(report.dkim["signingDomain"] as? String, "example.net")
        XCTAssertEqual(report.dkim["match"] as? Bool, false)
        XCTAssertTrue(report.warnings.contains { $0.contains("signing domain mismatch") })
    }

    func testAnEmptySigningDomainIsNeverAMatch() throws {
        let report = try evaluate("dkim=pass header.i=@example.com", expected: [""])
        XCTAssertEqual(report.verdict, "suspicious")
        XCTAssertEqual(report.dkim["match"] as? Bool, false)
    }
}
