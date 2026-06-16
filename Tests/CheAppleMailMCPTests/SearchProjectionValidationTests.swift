import XCTest
@testable import CheAppleMailMCP

/// Covers the #208 spec requirement "Search result projection and logical dedup"
/// normative clause: the system SHALL reject invalid `projection` / `dedup`
/// combinations with a parameter error. Tests the pure validation helper that
/// the `search_emails` handler delegates to.
final class SearchProjectionValidationTests: XCTestCase {

    // MARK: - Valid combinations

    func testDefaultsAreFullNone() throws {
        let r = try CheAppleMailMCPServer.validateSearchProjection(projection: "full", dedup: "none")
        XCTAssertEqual(r.projection, "full")
        XCTAssertFalse(r.dedup)
    }

    func testIdsWithLogicalDedup() throws {
        let r = try CheAppleMailMCPServer.validateSearchProjection(projection: "ids", dedup: "logical")
        XCTAssertEqual(r.projection, "ids")
        XCTAssertTrue(r.dedup)
    }

    func testCountWithLogicalDedup() throws {
        let r = try CheAppleMailMCPServer.validateSearchProjection(projection: "count", dedup: "logical")
        XCTAssertEqual(r.projection, "count")
        XCTAssertTrue(r.dedup)
    }

    func testIdsWithoutDedup() throws {
        let r = try CheAppleMailMCPServer.validateSearchProjection(projection: "ids", dedup: "none")
        XCTAssertEqual(r.projection, "ids")
        XCTAssertFalse(r.dedup)
    }

    // MARK: - Rejected combinations (spec: SHALL reject)

    func testUnknownProjectionRejected() {
        XCTAssertThrowsError(
            try CheAppleMailMCPServer.validateSearchProjection(projection: "bogus", dedup: "none"))
    }

    func testUnknownDedupRejected() {
        XCTAssertThrowsError(
            try CheAppleMailMCPServer.validateSearchProjection(projection: "ids", dedup: "bogus"))
    }

    func testDedupLogicalWithFullProjectionRejected() {
        // Spec scenario: "dedup with full projection is rejected".
        XCTAssertThrowsError(
            try CheAppleMailMCPServer.validateSearchProjection(projection: "full", dedup: "logical"))
    }
}
