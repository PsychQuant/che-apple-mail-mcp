import XCTest
@testable import CheAppleMailMCP

/// Execute the real legacy metadata-selection control flow, substituting only
/// Mail access and the address-read tail. No Mail application is contacted.
final class RecipientReceiptMetadataFailureTests: XCTestCase {
    private func fixture(_ source: String, subjectError: Int = 0, idError: Int = 0,
                         subjectValue: String = "Target") throws -> String {
        let addressTail = try XCTUnwrap(source.range(of: "set ccStr to \"\""))
        var prefix = String(source[..<addressTail.lowerBound])
        prefix = prefix.replacingOccurrences(of: "tell application \"Mail\"", with: "tell me")
            .replacingOccurrences(of: "(every mailbox of drafts mailbox)", with: "{1}")
            .replacingOccurrences(of: "(every message of mb)", with: "{1, 2}")
            .replacingOccurrences(of: "(subject of dm)", with: "(my fixtureSubject(contents of dm))")
            .replacingOccurrences(of: "(id of dm)", with: "(my fixtureID(contents of dm))")
        guard !prefix.contains("application \"Mail\""), !prefix.contains("drafts mailbox") else {
            throw NSError(domain: "ReceiptMetadataFixture", code: 1)
        }
        return """
        on fixtureSubject(row)
            if row is \(subjectError) then error "fixture subject unavailable" number -9901
            return "\(subjectValue)"
        end fixtureSubject
        on fixtureID(row)
            if row is \(idError) then error "fixture id unavailable" number -9902
            return row * 100
        end fixtureID
        \(prefix)
            return "ADDRESSES:" & (_best as string)
        end tell
        """
    }

    private func execute(_ script: String) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 {
            XCTAssertEqual(text, "", "failed metadata must not publish a partial candidate")
            throw MailError.scriptFailed(message: error, code: Int(process.terminationStatus))
        }
        return text
    }

    func testSubjectAndIDFailuresAfterAMatchAbortBeforeAddresses() throws {
        let source = buildDraftRecipientReceiptScript(subject: "Target")
        for (subjectError, idError, code) in [(2, 0, "-9901"), (0, 2, "-9902")] {
            XCTAssertThrowsError(try execute(fixture(source, subjectError: subjectError, idError: idError))) {
                guard case MailError.scriptFailed(let message, _) = $0 else { return XCTFail("unexpected error") }
                XCTAssertTrue(message.contains("RECIPIENT_METADATA_UNAVAILABLE"), message)
                XCTAssertTrue(message.contains(code), message)
                XCTAssertFalse(message.contains("fixture subject unavailable"))
                XCTAssertFalse(message.contains("fixture id unavailable"))
            }
        }
    }

    func testFirstSubjectFailureIsNotACompleteNotFound() throws {
        let source = buildDraftRecipientReceiptScript(subject: "Target")
        XCTAssertThrowsError(try execute(fixture(source, subjectError: 1, subjectValue: "Other"))) {
            guard case MailError.scriptFailed(let message, _) = $0 else { return XCTFail("unexpected error") }
            XCTAssertTrue(message.contains("RECIPIENT_METADATA_UNAVAILABLE"), message)
            XCTAssertTrue(message.contains("-9901"), message)
        }
    }

    func testCompleteMatchAndCompleteNotFoundRetainTheirBehavior() throws {
        let source = buildDraftRecipientReceiptScript(subject: "Target")
        XCTAssertEqual(try execute(fixture(source)), "ADDRESSES:2")
        XCTAssertEqual(try execute(fixture(source, idError: 1, subjectValue: "Other")), "NOTFOUND")
    }

    func testControllerClassifiesActualMetadataErrorAsUnavailableWithoutRetry() async throws {
        final class Calls: @unchecked Sendable { var receipts = 0 }
        let calls = Calls()
        await MailController.shared.setTestSeams(scriptRunner: { source in
            if source.contains("#404 recipient receipt") {
                calls.receipts += 1
                return try self.execute(self.fixture(source, subjectError: 2))
            }
            if source.contains("mailto:") { return "Draft created successfully (mailto path)" }
            throw MailError.operationFailed("unexpected fixture script")
        }, refusal: { nil })
        do {
            let result = try await MailController.shared.createDraft(
                to: ["to@example.invalid"], subject: "Target", body: "Fixture",
                cc: ["Named <cc@example.invalid>"])
            XCTAssertTrue(result.contains("recipients_receipt: unavailable"), result)
            XCTAssertFalse(result.contains("fixture subject unavailable"), result)
            XCTAssertEqual(calls.receipts, 1, "an incomplete read is not a pollable not-found")
            await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        } catch {
            await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
    }
}
