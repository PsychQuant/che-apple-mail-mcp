import XCTest
@testable import CheAppleMailMCP

final class DraftReceiptProtocolTests: XCTestCase {
    private struct Fixture: Decodable { let name: String; let payload: String; let expected: String; let expectedCandidateCount: Int? }

    func testDuplicateMembersCannotHideConflictingRecipientValues() {
        let account = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        for toFields in [#""to":[],"to":["unexpected@example.invalid"]"#,
                         #""to":["unexpected@example.invalid"],"\u0074o":[]"#] {
            let raw = #"{"version":"1","status":"found","account_id":"11111111-1111-4111-8111-111111111111","id":"101","subject":"Fixture",TO_FIELDS,"cc":[],"bcc":[]}"#.replacingOccurrences(of: "TO_FIELDS", with: toFields)
            XCTAssertEqual(decodeDraftReceiptWire(Data(raw.utf8), expectedAccountID: account), .unavailable(.invalidPayload))
        }
    }

    func testQuotedContentDoesNotActAsObjectMembers() {
        let account = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let raw = #"{"version":"1","status":"found","account_id":"11111111-1111-4111-8111-111111111111","id":"101","subject":"literal {\"to\":1,\"to\":2} — 測試\u0000","to":["\"name\" <to@example.invalid>"],"cc":[],"bcc":[]}"#
        guard case .found(let record) = decodeDraftReceiptWire(Data(raw.utf8), expectedAccountID: account) else {
            return XCTFail("quoted content was incorrectly treated as structure")
        }
        XCTAssertEqual(record.subject, "literal {\"to\":1,\"to\":2} — 測試\u{0}")
        XCTAssertEqual(record.to, ["\"name\" <to@example.invalid>"])
    }

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
