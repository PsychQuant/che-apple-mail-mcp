import XCTest
@testable import CheAppleMailMCP

/// #465 — the repo is public. The fixtures are SYNTHETIC; this guard makes
/// "someone pasted a real log excerpt" fail loudly instead of shipping an
/// account address.
final class MailLogFixtureHygieneTests: XCTestCase {

    private func allFixtures() throws -> [(String, String)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: MailLogFixtures.directory.path)
            .filter { $0.hasSuffix(".ndjson") }
        XCTAssertFalse(names.isEmpty, "no fixtures found at \(MailLogFixtures.directory.path)")
        return try names.map { ($0, try MailLogFixtures.text($0)) }
    }

    func testEveryEmailShapedStringIsOnAReservedInvalidDomain() throws {
        let re = try NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#)
        for (name, text) in try allFixtures() {
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let hit = ns.substring(with: m.range)
                XCTAssertTrue(hit.hasSuffix("@example.invalid"), "\(name): non-synthetic address \(hit)")
            }
        }
    }

    func testNoHomePathsAndNoRealAccountMarkers() throws {
        for (name, text) in try allFixtures() {
            XCTAssertFalse(text.contains("/Users/"), "\(name) contains a home path")
            for marker in ["gmail.com", "as.edu", "tp.edu", "gapps", "icloud.com"] {
                XCTAssertFalse(text.lowercased().contains(marker), "\(name) contains \(marker)")
            }
        }
    }
}
