import XCTest
import Foundation

/// #211 (verify CODEX-1): the signed hardened-runtime binary MUST carry the
/// Apple Events automation entitlement, or every NSAppleScript call to Mail.app
/// fails with errAEEventNotPermitted (-1743) and the Automation TCC prompt never
/// appears. Pin it so a future edit can't silently drop the key and re-break all
/// Mail control under a signed build.
final class EntitlementsPlistTests: XCTestCase {

    /// Locate Sources/CheAppleMailMCP/Entitlements.plist relative to this test
    /// file: Tests/CheAppleMailMCPTests/EntitlementsPlistTests.swift → repo root.
    private func entitlementsURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/CheAppleMailMCP/Entitlements.plist")
    }

    func testEntitlementsFileExists() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: entitlementsURL().path),
            "Entitlements.plist missing at \(entitlementsURL().path)"
        )
    }

    func testAppleEventsEntitlementPresentAndTrue() throws {
        let data = try Data(contentsOf: entitlementsURL())
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try XCTUnwrap(plist as? [String: Any], "Entitlements.plist is not a dict")
        // Parse as a real plist boolean (not a substring grep): a stale <false/>
        // would otherwise pass while macOS treats the entitlement as absent.
        let value = dict["com.apple.security.automation.apple-events"] as? Bool
        XCTAssertEqual(
            value, true,
            "com.apple.security.automation.apple-events must be present and <true/>; "
            + "without it a hardened-runtime build cannot send Apple events to Mail.app (#211 CODEX-1)"
        )
    }
}
