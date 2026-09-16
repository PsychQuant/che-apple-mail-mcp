import XCTest
@testable import CheAppleMailMCP

final class DraftIDBaselineTests: XCTestCase {
    private let a = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private func decode(_ json: String, accounts: Set<UUID>? = nil) -> DraftIDBaselineOutcome {
        decodeDraftIDBaseline(Data(json.utf8), expectedAccountIDs: accounts ?? [a, b])
    }

    func testSameNumericIDsRemainSeparatedByAccount() {
        let raw = #"{"version":"1","status":"complete","accounts":[{"account_id":"11111111-1111-4111-8111-111111111111","ids":["101","102"]},{"account_id":"22222222-2222-4222-8222-222222222222","ids":["101"]}]}"#
        XCTAssertEqual(decode(raw), .complete([a: ["101", "102"], b: ["101"]]))
    }

    func testEmptyIDsAreACompleteSnapshotButMissingAccountIsNot() {
        let raw = #"{"version":"1","status":"complete","accounts":[{"account_id":"11111111-1111-4111-8111-111111111111","ids":[]}]}"#
        XCTAssertEqual(decode(raw, accounts: [a]), .complete([a: []]))
        XCTAssertEqual(decode(raw), .unavailable(.wrongScope))
        XCTAssertEqual(decode(raw, accounts: []), .unavailable(.missingScope))
    }

    func testDuplicateAndForeignAccountsCannotOverwriteOrExtendScope() {
        let duplicate = #"{"version":"1","status":"complete","accounts":[{"account_id":"11111111-1111-4111-8111-111111111111","ids":["101"]},{"account_id":"11111111-1111-4111-8111-111111111111","ids":["202"]}]}"#
        XCTAssertEqual(decode(duplicate, accounts: [a]), .unavailable(.invalidPayload))
        let foreign = #"{"version":"1","status":"complete","accounts":[{"account_id":"22222222-2222-4222-8222-222222222222","ids":[]}]}"#
        XCTAssertEqual(decode(foreign, accounts: [a]), .unavailable(.wrongScope))
    }

    func testIDsRemainDecimalStringsWithoutNumericRounding() {
        let raw = #"{"version":"1","status":"complete","accounts":[{"account_id":"11111111-1111-4111-8111-111111111111","ids":["9007199254740993","9223372036854775807"]}]}"#
        XCTAssertEqual(decode(raw, accounts: [a]), .complete([a: ["9007199254740993", "9223372036854775807"]]))
        for ids in ["[101]", "[true]", "[null]", #"[""]"#, #"["１"]"#, #"["1e2"]"#, #"["1\n"]"#] {
            let broken = #"{"version":"1","status":"complete","accounts":[{"account_id":"11111111-1111-4111-8111-111111111111","ids":IDS}]}"#.replacingOccurrences(of: "IDS", with: ids)
            XCTAssertEqual(decode(broken, accounts: [a]), .unavailable(.invalidPayload), ids)
        }
    }

    func testMalformedAndExtraFieldsReturnOnlyAnUnavailableReason() {
        let inputs = ["{", "[]", #"{"version":1,"status":"complete","accounts":[]}"#,
                      #"{"version":"2","status":"complete","accounts":[]}"#,
                      #"{"version":"1","status":"partial","accounts":[]}"#,
                      #"{"version":"1","status":"complete","accounts":[{"account_id":"11111111-1111-4111-8111-111111111111","ids":[],"to":["never-disclose@example.invalid"]}]}"#,
                      #"{"version":"1","status":"complete","accounts":[],"subject":"never-disclose@example.invalid"}"#]
        for raw in inputs {
            let result = decode(raw, accounts: [a])
            XCTAssertEqual(result, .unavailable(.invalidPayload))
            XCTAssertFalse(String(describing: result).contains("never-disclose"))
        }
    }

    func testDuplicateJSONMembersCannotDiscardIDs() {
        let row = #"{"account_id":"11111111-1111-4111-8111-111111111111","ids":["101"]}"#
        let payloads = [
            #"{"version":"1","status":"complete","status":"complete","accounts":[ROW]}"#.replacingOccurrences(of: "ROW", with: row),
            #"{"version":"1","status":"complete","accounts":[ROW],"accounts":[ROW]}"#.replacingOccurrences(of: "ROW", with: row),
            #"{"version":"1","status":"complete","accounts":[{"account_id":"11111111-1111-4111-8111-111111111111","ids":["101"],"ids":[]}]}"#,
            #"{"version":"1","status":"complete","accounts":[{"account_id":"11111111-1111-4111-8111-111111111111","ids":[],"ids":["101"]}]}"#,
            #"{"version":"1","status":"complete","accounts":[{"account_id":"11111111-1111-4111-8111-111111111111","ids":[],"\u0069ds":["101"]}]}"#
        ]
        for raw in payloads { XCTAssertEqual(decode(raw, accounts: [a]), .unavailable(.invalidPayload)) }
    }

    func testNonUTF8EncodingCannotBypassDuplicateMemberValidation() throws {
        let raw = #"{"version":"1","status":"complete","accounts":[{"account_id":"11111111-1111-4111-8111-111111111111","ids":["101"],"ids":[]}]}"#
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            let data = try XCTUnwrap(raw.data(using: encoding))
            XCTAssertEqual(decodeDraftIDBaseline(data, expectedAccountIDs: [a]), .unavailable(.invalidPayload))
        }
    }

    private func fixtureScript(_ production: String, boxes: String, failing: String = "", emptyA: Bool = false) throws -> String {
        let bodies = [
            "baselineMailboxes": "return " + boxes,
            "baselineAccountID": """
                if theBox is "broken-owner" then error "owner read failed" number -9901
                if theBox is "a" or theBox is "also-a" then return "11111111-1111-4111-8111-111111111111"
                return "22222222-2222-4222-8222-222222222222"
                """,
            "baselineMessageIDs": """
                if theBox is "\(failing)" then error "ID read failed" number -9902
                if theBox is "a" then return \(emptyA ? "{}" : "{\"101\", \"9007199254740993\"}")
                if theBox is "also-a" then return {"101", "102"}
                return {"101"}
                """
        ]
        var result = production
        for name in ["baselineMailboxes", "baselineAccountID", "baselineMessageIDs"] {
            let signature = name == "baselineMailboxes" ? "()" : "(theBox)"
            let replacement = "on " + name + signature + "\n" + bodies[name]! + "\nend " + name
            if let start = result.range(of: "on " + name + "("),
               let end = result.range(of: "end " + name, range: start.lowerBound..<result.endIndex) {
                result.replaceSubrange(start.lowerBound..<end.upperBound, with: replacement)
            } else {
                result += "\n" + replacement
            }
        }
        guard !result.contains("tell application \"Mail\"") else {
            throw NSError(domain: "BaselineFixture", code: 1)
        }
        return result
    }

    private func executeFixture(_ source: String) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 {
            XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          "failed enumeration must not return a partial snapshot")
            throw NSError(domain: "BaselineFixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
        }
        return text
    }

    func testCollectorGroupsNativeIDsAndNeverReadsIDsOutsideScope() throws {
        let both = try buildDraftIDBaselineScript(accountIDs: [a, b])
        let raw = try executeFixture(fixtureScript(both, boxes: "{\"a\", \"b\"}"))
        XCTAssertEqual(decode(raw), .complete([a: ["101", "9007199254740993"], b: ["101"]]))
        let scoped = try buildDraftIDBaselineScript(accountIDs: [a])
        let onlyA = try executeFixture(fixtureScript(scoped, boxes: "{\"a\", \"b\"}", failing: "b"))
        XCTAssertEqual(decode(onlyA, accounts: [a]), .complete([a: ["101", "9007199254740993"]]))
    }

    func testCollectorRejectsMissingScopeAndAnyIncompleteEnumeration() throws {
        let script = try buildDraftIDBaselineScript(accountIDs: [a, b])
        for (boxes, failing, reason) in [
            ("{\"a\"}", "", "Draft baseline scope unavailable"),
            ("{\"a\", \"b\"}", "b", "ID read failed"),
            ("{\"a\", \"broken-owner\"}", "", "owner read failed")
        ] {
            XCTAssertThrowsError(try executeFixture(fixtureScript(script, boxes: boxes, failing: failing))) {
                XCTAssertTrue($0.localizedDescription.contains(reason), $0.localizedDescription)
            }
        }
        XCTAssertThrowsError(try buildDraftIDBaselineScript(accountIDs: [])) {
            guard case MailError.invalidParameter = $0 else { return XCTFail("unexpected empty-scope error") }
        }
    }

    func testCollectorIncludesAnObservedEmptyMailbox() throws {
        let script = try buildDraftIDBaselineScript(accountIDs: [a])
        let raw = try executeFixture(fixtureScript(script, boxes: "{\"a\"}", emptyA: true))
        XCTAssertEqual(decode(raw, accounts: [a]), .complete([a: []]))
    }

    func testCollectorUnionsMultipleDraftContainersPerAccount() throws {
        let script = try buildDraftIDBaselineScript(accountIDs: [a, b])
        let raw = try executeFixture(fixtureScript(script, boxes: "{\"a\", \"also-a\", \"b\"}"))
        XCTAssertEqual(decode(raw), .complete([a: ["101", "102", "9007199254740993"], b: ["101"]]))
    }

    func testControllerReturnsUnavailableWithoutRetryOrLeakingErrors() async {
        var calls = 0
        await MailController.shared.setTestSeams(scriptRunner: { _ in
            calls += 1
            throw MailError.operationFailed("never-disclose@example.invalid")
        }, refusal: nil)
        let empty = await MailController.shared.readDraftIDBaseline(accountIDs: [])
        XCTAssertEqual(empty, .unavailable(.missingScope))
        XCTAssertEqual(calls, 0)
        let failed = await MailController.shared.readDraftIDBaseline(accountIDs: [a])
        XCTAssertEqual(failed, .unavailable(.readFailed))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(String(describing: failed).contains("never-disclose"))
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
    }

    func testControllerUsesStrictDecoderOnItsSingleCompleteRead() async throws {
        var calls = 0
        await MailController.shared.setTestSeams(scriptRunner: { source in
            calls += 1
            return try self.executeFixture(self.fixtureScript(source, boxes: "{\"a\", \"b\"}"))
        }, refusal: nil)
        let value = await MailController.shared.readDraftIDBaseline(accountIDs: [a, b])
        XCTAssertEqual(value, .complete([a: ["101", "9007199254740993"], b: ["101"]]))
        XCTAssertEqual(calls, 1)
        await MailController.shared.setTestSeams(scriptRunner: { _ in "{\"accounts\":[]}" }, refusal: nil)
        let malformed = await MailController.shared.readDraftIDBaseline(accountIDs: [a])
        XCTAssertEqual(malformed, .unavailable(.invalidPayload))
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
    }

    func testNativeReadOnlySnapshotMatchesStableCountWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MAIL_APP_INTEGRATION_TESTS"] == "1", "native ID-only baseline requires opt-in")
        let text = try XCTUnwrap(environment["CHE_MAIL_BASELINE_LIVE_ACCOUNT"])
        let account = try XCTUnwrap(UUID(uuidString: text))
        // Independent count query for one known account/role. Counts before
        // and after bound this observation; they do not prove ID stability.
        let countScript = """
        tell application "Mail"
            set matchingBoxes to {}
            repeat with box in every mailbox of drafts mailbox
                if (id of account of box as string) is "\(account.uuidString)" then set end of matchingBoxes to contents of box
            end repeat
            if (count matchingBoxes) is not 1 then error "live count control requires one account Drafts role"
            return (count messages of item 1 of matchingBoxes) as string
        end tell
        """
        let beforeRaw = try await MailController.shared.runDraftScanScript(countScript)
        let before = try XCTUnwrap(Int(beforeRaw.trimmingCharacters(in: .whitespacesAndNewlines)))
        let result = await MailController.shared.readDraftIDBaseline(accountIDs: [account])
        let afterRaw = try await MailController.shared.runDraftScanScript(countScript)
        let after = try XCTUnwrap(Int(afterRaw.trimmingCharacters(in: .whitespacesAndNewlines)))
        try XCTSkipUnless(before == after, "native draft population changed during the read-only observation")
        guard case .complete(let ids) = result else { return XCTFail("native baseline unavailable") }
        XCTAssertEqual(Set(ids.keys), [account])
        XCTAssertEqual(ids[account]?.count, before)
        print("Native ID-only baseline: scopes=1, IDs=\(before), independent count stable")
    }
}
