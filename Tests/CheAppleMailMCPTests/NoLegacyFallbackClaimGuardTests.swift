import XCTest
@testable import CheAppleMailMCP

/// #475 verify R4 — #304 deleted the legacy (AppleScript body-injection) compose
/// path, so no user-facing text may claim that compose "falls back to the legacy
/// path" or "still works" without Accessibility. Round 3 swept tool descriptions
/// and the README but missed the text `check_accessibility` actually RETURNS and
/// the setup window — a caller who reads the denied output was told the opposite
/// of the tool's own description. This guard covers the runtime strings and scans
/// every Swift source for the stale claims.
final class NoLegacyFallbackClaimGuardTests: XCTestCase {

    private static let staleClaims = ["legacy path", "still work", "falls back", "fall back to the legacy",
                                      "legacy AppleScript injection —", "body is wrapped"]

    func testAccessibilityRuntimeTextMakesNoLegacyClaim() {
        for text in [AccessibilityStatus.summary(.denied), AccessibilityStatus.guidance()] {
            for claim in Self.staleClaims {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(claim), "stale claim \"\(claim)\" in: \(text)")
            }
        }
        XCTAssertTrue(AccessibilityStatus.summary(.denied).contains("fail"),
                      "the denied summary must say the GUI compose paths fail")
        XCTAssertTrue(AccessibilityStatus.guidance().contains("CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT"),
                      "the guidance must name the direct-write exception")
    }

    func testNoSourceStringClaimsALegacyFallback() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        // Compose-specific phrasings only: "fall back to the legacy display_name form"
        // (account references) is a different, still-true statement.
        let stale = ["to the legacy path", "legacy injection path", "compose still works",
                     "still work but route through the legacy", "retrying via the legacy path",
                     "(c) legacy AppleScript injection —"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for claim in stale {
                XCTAssertFalse(text.contains(claim), "\(file.lastPathComponent) still contains \"\(claim)\"")
            }
        }
    }
}
