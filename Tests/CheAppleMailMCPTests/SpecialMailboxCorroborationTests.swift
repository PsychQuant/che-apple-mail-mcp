import XCTest
@testable import CheAppleMailMCP

/// #376: index names discover candidates; only native role evidence selects paths.
final class SpecialMailboxCorroborationTests: XCTestCase {
    private func candidates(_ leaves: [(String, String)], _ paths: [String]) -> [SpecialMailboxPathCandidate] {
        specialMailboxPathCandidates(leaves: leaves.map { (key: $0.0, leaf: $0.1) },
                                     mailboxes: paths.map { (path: $0, components: $0.components(separatedBy: "/")) })
    }
    private func proof(_ values: [Bool?]) -> SpecialMailboxPathProof {
        SpecialMailboxPathProof(version: 1, count: values.count, results: values.enumerated().map {
            .init(index: $0.offset, available: $0.element != nil, matches: $0.element == true)
        })
    }

    func testOrdinarySiblingFoldersCannotCorroborateEachOther() {
        let input = candidates([("drafts", "Drafts"), ("sent", "Sent")], ["Projects/Drafts", "Projects/Sent"])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(confirmedSpecialMailboxPaths(candidates: input, proof: proof([false, false])), [:])
        XCTAssertEqual(confirmedSpecialMailboxPaths(candidates: input, proof: proof([nil, nil])), [:])
    }

    func testOnlyConfirmedRoleIsReturned() {
        let input = candidates([("drafts", "Drafts"), ("sent", "Sent")], ["Projects/Drafts", "[Gmail]/Sent"])
        XCTAssertEqual(confirmedSpecialMailboxPaths(candidates: input, proof: proof([false, true])), ["sent": "[Gmail]/Sent"])
    }

    func testRootAndQualifiedNamesRequireEvidenceToo() {
        let input = candidates([("inbox", "INBOX"), ("drafts", "[Gmail]/Drafts")], ["INBOX", "[Gmail]/Drafts"])
        XCTAssertEqual(confirmedSpecialMailboxPaths(candidates: input, proof: proof([false, false])), [:])
        XCTAssertEqual(confirmedSpecialMailboxPaths(candidates: input, proof: proof([true, true])), ["inbox": "INBOX", "drafts": "[Gmail]/Drafts"])
    }

    func testNativeIdentityResolvesCompetingNamesWithoutParentPreference() {
        let input = candidates([("drafts", "Drafts")], ["Drafts", "Projects/Drafts", "[Gmail]/Drafts"])
        XCTAssertEqual(confirmedSpecialMailboxPaths(candidates: input, proof: proof([false, false, true])), ["drafts": "[Gmail]/Drafts"])
        XCTAssertEqual(confirmedSpecialMailboxPaths(candidates: input, proof: proof([true, true, false])), [:])
    }

    func testSharedLeafStillNeedsSeparateRoleEvidence() {
        let input = candidates([("drafts", "Drafts"), ("sent", "Drafts")], ["Projects/Drafts"])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(confirmedSpecialMailboxPaths(candidates: input, proof: proof([false, false])), [:])
        XCTAssertEqual(confirmedSpecialMailboxPaths(candidates: input, proof: proof([true, false])), ["drafts": "Projects/Drafts"])
    }

    func testUnknownOtherCandidateIsNotPositiveEvidence() {
        let input = candidates([("drafts", "Drafts")], ["Projects/Drafts", "[Gmail]/Drafts"])
        XCTAssertEqual(confirmedSpecialMailboxPaths(candidates: input, proof: proof([nil, false])), [:])
        XCTAssertEqual(confirmedSpecialMailboxPaths(candidates: input, proof: proof([nil, true])), ["drafts": "[Gmail]/Drafts"])
    }

    func testLiteralSlashAndInvalidComponentsAreNotRepresentedAsPaths() {
        let input = specialMailboxPathCandidates(leaves: [("drafts", "Projects/Drafts")], mailboxes: [
            ("Projects/Drafts", ["Projects/Drafts"]), ("Projects/Drafts", ["Projects", "Drafts"]),
            ("Projects/Drafts", []), ("Projects/Drafts", ["Projects", "", "Drafts"])
        ])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0].components, ["Projects", "Drafts"])
    }

    func testDiscoveryDeduplicatesAndPreservesLeafBoundaries() {
        let input = candidates([("drafts", "Drafts")], ["[Gmail]/Drafts", "[Gmail]/Drafts", "Projects/NotDrafts"])
        XCTAssertEqual(input.count, 1)
        XCTAssertTrue(candidates([("outbox", "Outbox")], ["Outbox"]).isEmpty)
        XCTAssertTrue(candidates([("drafts", "")], ["Drafts"]).isEmpty)
    }

    func testCountedProofRejectsMalformedMappingsAndBooleanCoercions() throws {
        let good = #"{"version":1,"count":2,"results":[{"index":0,"available":true,"matches":false},{"index":1,"available":true,"matches":true}]}"#
        XCTAssertNoThrow(try SpecialMailboxPathProof.parse(good, candidateCount: 2))
        for bad in [good.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
                    good.replacingOccurrences(of: "\"count\":2", with: "\"count\":1"),
                    good.replacingOccurrences(of: "\"index\":1", with: "\"index\":0"),
                    good.replacingOccurrences(of: "\"index\":1", with: "\"index\":2"),
                    good.replacingOccurrences(of: "\"available\":true", with: "\"available\":false"),
                    good.replacingOccurrences(of: "\"matches\":true", with: "\"matches\":\"true\"")]
        { XCTAssertThrowsError(try SpecialMailboxPathProof.parse(bad, candidateCount: 2)) }
        XCTAssertThrowsError(try SpecialMailboxPathProof.parse(good, candidateCount: 1))
    }

    func testMissingProofCannotReturnCandidates() {
        let input = candidates([("drafts", "Drafts")], ["Drafts"])
        XCTAssertEqual(confirmedSpecialMailboxPaths(candidates: input, proof: proof([])), [:])
    }

    func testLegacyTupleCannotBypassNativeConfirmation() {
        guard case .resolved(let result) = resolveSpecialMailboxesResult(
            ["UUID", "Fixture", "1", "Drafts", "Sent", "Trash", "Junk", "INBOX",
             "Projects/Drafts", "Projects/Sent", "Projects/Trash", "Projects/Junk", "INBOX"]) else {
            return XCTFail("leaf metadata should still resolve")
        }
        XCTAssertEqual(result["drafts"], "Drafts")
        XCTAssertFalse(result.keys.contains { $0.hasSuffix("_path") })
    }

    func testControllerUsesNativeProofAndSkipsEmptyRequests() async throws {
        var calls = 0
        await MailController.shared.setTestSeams(scriptRunner: { source in
            calls += 1
            XCTAssertTrue(source.contains("candidateBox is roleProxy"))
            XCTAssertFalse(source.contains("messages of"))
            return #"{"version":1,"count":1,"results":[{"index":0,"available":true,"matches":true}]}"#
        }, refusal: { nil })
        do {
            _ = try await MailController.shared.confirmSpecialMailboxPaths(accountId: "UUID", candidates: [])
            XCTAssertEqual(calls, 0)
            let input = candidates([("drafts", "Drafts")], ["[Gmail]/Drafts"])
            let result = try await MailController.shared.confirmSpecialMailboxPaths(accountId: "UUID", candidates: input)
            XCTAssertEqual(confirmedSpecialMailboxPaths(candidates: input, proof: result), ["drafts": "[Gmail]/Drafts"])
            XCTAssertEqual(calls, 1)
        } catch {
            await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
    }

    func testBuilderEscapesExactComponentsAndUsesObjectComparison() throws {
        let input = candidates([("drafts", "Drafts")], ["Team \"quoted\"/Drafts"])
        let script = try buildSpecialMailboxPathProofScript(accountId: "UUID", candidates: input)
        XCTAssertTrue(script.contains(#"mailbox "Team \"quoted\"""#))
        XCTAssertTrue(script.contains("roleCount is 1"))
        XCTAssertTrue(script.contains("candidateBox is roleProxy"))
        XCTAssertTrue(script.contains("set actualBox to (get container of actualBox)"))
        XCTAssertTrue(script.contains("if actualBox is not (account id"))
        XCTAssertTrue(script.contains("set actualBox to roleProxy"))
        XCTAssertEqual(script.components(separatedBy: "set actualBox to (get container of actualBox)").count - 1,
                       2 * input[0].components.count)
        XCTAssertFalse(script.contains("repeat while (class of"))
    }
}
