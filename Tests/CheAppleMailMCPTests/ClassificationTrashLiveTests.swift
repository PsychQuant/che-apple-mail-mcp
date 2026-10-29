import Darwin
import XCTest
@testable import CheAppleMailMCP

/// Opt-in verification of the real controller/osascript/Trash-role boundary.
/// The coordinator imports one synthetic message into its own UUID mailbox;
/// no normal policy, real mail, sending, or permanent deletion is involved.
final class ClassificationTrashLiveTests: XCTestCase {
    private struct Fixture: Decodable {
        let token: String
        let accountID: String
        let id: String
        let sourceDigest: String
    }

    func testNativeSourceMismatchRefusesAndExactFixtureMovesToTrash() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MAIL_APP_INTEGRATION_TESTS"] == "1",
                          "native classification fixture requires explicit opt-in")
        let path = try XCTUnwrap(environment["CHE_MAIL_CLASSIFICATION_FIXTURE_JSON"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let prefix = "IDD356Native-"
        guard fixture.token.hasPrefix(prefix),
              UUID(uuidString: String(fixture.token.dropFirst(prefix.count))) != nil,
              !fixture.accountID.isEmpty,
              fixture.id.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil else {
            throw MailError.operationFailed("invalid synthetic classification fixture")
        }
        let source = try await MailController.shared.classificationSource(
            id: fixture.id, accountID: fixture.accountID, components: [fixture.token])
        let normalized = normalizedClassificationSource(source)
        guard classificationDigest(Data(normalized.utf8)) == fixture.sourceDigest,
              normalized.contains("IDD356_BODY_" + fixture.token),
              normalized.contains("fixture@example.invalid") else {
            throw MailError.operationFailed("synthetic fixture changed before native verification")
        }
        let metadata = try await MailController.shared.classificationFixtureMetadata(
            token: fixture.token, accountID: fixture.accountID, inTrash: false)
        guard metadata.count == 5, metadata[0] == fixture.id,
              metadata[1] == fixture.token + "@example.invalid",
              metadata[2] == fixture.token,
              metadata[3] == "IDD356 Fixture <sender@example.invalid>" else {
            throw MailError.operationFailed("native fixture metadata differs")
        }
        let message = ClassificationMessage(
            id: fixture.id, accountID: fixture.accountID, mailboxComponents: [fixture.token],
            mailboxURL: "imap://" + fixture.accountID + "/" + fixture.token,
            messageID: "<" + fixture.token + "@example.invalid>", sender: metadata[3],
            subject: fixture.token, listID: nil, isDraft: false, isFlagged: false,
            contentDigest: fixture.sourceDigest, nativeSource: source)
        // An isolated empty store exercises only the native primitive. Policy
        // approval/plan/audit authorization has separate integration tests.
        let physicalTemporaryPath = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physicalTemporaryPath) }
        let storeRoot = URL(fileURLWithPath: String(cString: physicalTemporaryPath))
            .appendingPathComponent("idd356-policy-" + UUID().uuidString)
        defer {
            if FileManager.default.fileExists(atPath: storeRoot.path) {
                try? FileManager.default.removeItem(at: storeRoot)
            }
        }
        let store = ClassificationPolicyStore(directory: storeRoot)
        let policy = try store.configure(.empty)
        let policyDigest = try policy.fingerprint()

        var stale = message
        stale.nativeSource = source + "\nDIFFERENT_EXPECTED_SOURCE\n"
        stale.contentDigest = classificationDigest(Data(normalizedClassificationSource(stale.nativeSource!).utf8))
        let refusal = try await MailController.shared.moveClassifiedMessage(
            stale, policyDigest: policyDigest, deadline: Date().addingTimeInterval(30), store: store)
        guard refusal == .refused else {
            return XCTFail("source mismatch did not refuse; stopping without another mutation")
        }
        let unchanged = try await MailController.shared.classificationSource(
            id: fixture.id, accountID: fixture.accountID, components: [fixture.token])
        guard normalizedClassificationSource(unchanged) == normalized else {
            return XCTFail("fixture source changed after refusal; stopping without another mutation")
        }

        let receipt = try await MailController.shared.moveClassifiedMessage(
            message, policyDigest: policyDigest, deadline: Date().addingTimeInterval(30), store: store)
        guard receipt == .moved else { return XCTFail("exact fixture was not moved; no retry") }
        let moved = try await MailController.shared.classificationFixtureMetadata(
            token: fixture.token, accountID: fixture.accountID, inTrash: true)
        guard moved.count == 5 else { return XCTFail("native Trash metadata is incomplete") }
        XCTAssertEqual(Array(moved[1...3]), Array(metadata[1...3]))
        XCTAssertEqual(classificationDigest(Data(normalizedClassificationSource(moved[4]).utf8)),
                       fixture.sourceDigest, "native Trash source bytes changed")
        // Do not retry, restore, or delete after an uncertain result. The
        // coordinator inspects the exact fixture and removes the empty mailbox.
    }
}

private extension MailController {
    func classificationFixtureMetadata(token: String, accountID: String, inTrash: Bool) throws -> [String] {
        let account = appleScriptEscape(accountID)
        let boxSelection = inTrash ? """
            set boxes to {}
            repeat with roleBox in every mailbox of trash mailbox
                if (id of account of roleBox as string) is "\(account)" then set end of boxes to contents of roleBox
            end repeat
            """ : "set boxes to every mailbox of account id \"\(account)\" whose name is \"\(token)\""
        let sourceAbsence = inTrash ? """
            set sourceBoxes to every mailbox of account id "\(account)" whose name is "\(token)"
            if (count sourceBoxes) is not 1 then error "fixture source mailbox is not unique"
            if (count messages of item 1 of sourceBoxes) is not 0 then error "fixture source is not empty after move"
            """ : "if (count messages of box) is not 1 then error \"fixture mailbox contains unexpected messages\""
        let script = """
        use framework "Foundation"
        tell application "Mail"
            \(boxSelection)
            if (count boxes) is not 1 then error "fixture mailbox role is not unique"
            set box to item 1 of boxes
            \(sourceAbsence)
            set matches to every message of box whose subject is "\(token)" and message id is "\(token)@example.invalid"
            if (count matches) is not 1 then error "fixture message is not unique"
            set msg to item 1 of matches
            if flagged status of msg then error "fixture flag differs"
            \(inTrash ? "" : "if deleted status of msg then error \"fixture is already deleted\"")
            if (count to recipients of msg) is not 1 then error "fixture recipients differ"
            if address of to recipient 1 of msg is not "fixture@example.invalid" then error "fixture recipient differs"
            set recordValues to {id of msg as string, message id of msg as string, subject of msg as string, sender of msg as string, source of msg as string}
        end tell
        set encoded to current application's NSJSONSerialization's dataWithJSONObject:recordValues options:0 |error|:(missing value)
        return (current application's NSString's alloc()'s initWithData:encoded encoding:(current application's NSUTF8StringEncoding)) as string
        """
        let result = try runScript(script, timeout: 10)
        return try JSONDecoder().decode([String].self, from: Data(result.utf8))
    }
}
