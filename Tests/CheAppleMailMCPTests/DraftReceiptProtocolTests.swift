import XCTest
@testable import CheAppleMailMCP

final class DraftReceiptProtocolTests: XCTestCase {
    private struct Fixture: Decodable { let name: String; let payload: String; let expected: String; let expectedCandidateCount: Int? }

    func testWireFixturesValidateShapeAndAccountWithoutLeakingRejectedAddresses() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/draft-receipt-wire.json")))
        let account = try XCTUnwrap(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        for fixture in fixtures {
            let result = decodeDraftReceiptWire(Data(fixture.payload.utf8), expectedAccountID: account)
            let status: String
            switch result {
            case .found(let record):
                status = "found"
                XCTAssertEqual(record.accountID, account, fixture.name)
                XCTAssertEqual(record.id, "102", fixture.name)
                XCTAssertEqual(record.subject, "共同主旨", fixture.name)
                XCTAssertEqual(record.to, ["To@Example.test"], fixture.name)
                XCTAssertEqual(record.cc, ["cc@example.test"], fixture.name)
                XCTAssertEqual(record.bcc, [], fixture.name)
            case .notFound: status = "not_found"
            case .ambiguous(let count):
                status = "ambiguous"
                XCTAssertEqual(count, fixture.expectedCandidateCount ?? 2, fixture.name)
            case .unavailable(let reason): status = "unavailable:" + reason.rawValue
            }
            XCTAssertEqual(status, fixture.expected, fixture.name)
            if fixture.expected.hasPrefix("unavailable:") {
                XCTAssertFalse(String(describing: result).contains("never-disclose@example.test"), fixture.name)
            }
        }
    }
}
