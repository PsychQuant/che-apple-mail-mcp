import XCTest
@testable import CheAppleMailMCP

/// Opt-in, read-only mailbox metadata verification. No mailbox/message creation.
final class SpecialMailboxNativeProofLiveTests: XCTestCase {
    private struct Fixture: Decodable {
        let account: String
        let role: String
        let leaf: String
        let components: [String]
        let expectedMatch: Bool
        let expectedAvailable: Bool?
    }

    @MainActor
    func testRecordedNativeCandidatesMatchExpectedRoles() async throws {
        guard ProcessInfo.processInfo.environment["MAIL_APP_INTEGRATION_TESTS"] != nil,
              let path = ProcessInfo.processInfo.environment["MAIL_SPECIAL_MAILBOX_FIXTURE"] else {
            throw XCTSkip("Set MAIL_APP_INTEGRATION_TESTS and MAIL_SPECIAL_MAILBOX_FIXTURE for known native mailbox metadata")
        }
        try XCTSkipUnless(AutomationStatus.probe() == .granted, "An existing Mail Automation grant is required")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(fixtures.isEmpty)
        XCTAssertTrue(fixtures.contains { $0.expectedMatch }, "fixture must include a known positive, not only absent paths")
        for (account, rows) in Dictionary(grouping: fixtures, by: \.account) {
            let candidates = rows.map { SpecialMailboxPathCandidate(key: $0.role, leaf: $0.leaf,
                path: $0.components.joined(separator: "/"), components: $0.components) }
            let proof = try await MailController.shared.confirmSpecialMailboxPaths(accountId: account, candidates: candidates)
            for result in proof.results {
                if let expectedAvailable = rows[result.index].expectedAvailable {
                    XCTAssertEqual(result.available, expectedAvailable, "native availability differs for fixture index \(result.index)")
                }
                XCTAssertEqual(result.matches, rows[result.index].expectedMatch, "native identity differs for fixture index \(result.index)")
            }
        }
    }
}
