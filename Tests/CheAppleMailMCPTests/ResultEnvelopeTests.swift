import XCTest
@testable import CheAppleMailMCP

/// Truncation-envelope shape (#204): search_emails / list_emails wrap their
/// results in { results, returned, limit, truncated } instead of a bare array.
final class ResultEnvelopeTests: XCTestCase {

    func testEnvelopeShape_truncated() {
        let env = CheAppleMailMCPServer.resultEnvelope(
            results: [["id": "1"], ["id": "2"]], limit: 2, truncated: true)
        XCTAssertEqual(Set(env.keys), ["results", "returned", "limit", "truncated"])
        XCTAssertEqual(env["returned"] as? Int, 2)
        XCTAssertEqual(env["limit"] as? Int, 2)
        XCTAssertEqual(env["truncated"] as? Bool, true)
        XCTAssertEqual((env["results"] as? [[String: Any]])?.count, 2)
    }

    func testEnvelopeShape_notTruncated_emptyResults() {
        let env = CheAppleMailMCPServer.resultEnvelope(results: [], limit: 50, truncated: false)
        XCTAssertEqual(env["returned"] as? Int, 0)
        XCTAssertEqual(env["limit"] as? Int, 50)
        XCTAssertEqual(env["truncated"] as? Bool, false)
        XCTAssertEqual((env["results"] as? [[String: Any]])?.isEmpty, true)
    }

    func testEnvelopeSerializesToJSONObject() throws {
        let env = CheAppleMailMCPServer.resultEnvelope(
            results: [["id": "1", "subject": "x"]], limit: 10, truncated: false)
        let data = try JSONSerialization.data(withJSONObject: env)
        let back = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(back?["results"])
        XCTAssertEqual(back?["truncated"] as? Bool, false)
    }
}
