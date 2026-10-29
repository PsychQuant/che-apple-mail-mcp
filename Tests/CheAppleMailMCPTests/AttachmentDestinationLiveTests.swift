import XCTest
@testable import CheAppleMailMCP

/// Opt-in native Mail save into the production private stage. The fixture is
/// synthetic and local; this test never sends mail or reads unrelated messages.
/// Account/mailbox resolution is covered separately: the fixture is imported
/// On My Mac and selected by its unique, validated fixture name and Message-ID.
final class AttachmentDestinationLiveTests: XCTestCase {
    func testNativeMailStagePublicationAndCleanup() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MAIL_APP_INTEGRATION_TESTS"] == "1",
                          "native Mail fixture test requires explicit opt-in")
        let token = try XCTUnwrap(environment["CHE_MAIL_ATTACHMENT_FIXTURE_TOKEN"])
        let prefix = "IDD402Native-"
        guard token.hasPrefix(prefix), UUID(uuidString: String(token.dropFirst(prefix.count))) != nil else {
            throw MailError.operationFailed("invalid synthetic fixture token")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idd402-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try await MailController.shared.checkNativeAttachmentStage(token: token, root: root)
    }
}

private extension MailController {
    func checkNativeAttachmentStage(token: String, root: URL) throws {
        let expected = Data("IDD402 native attachment staging fixture".utf8) + Data([0, 1, 2, 255, 10])
        let target = root.appendingPathComponent("saved.bin")
        let destination = try AttachmentDestination(savePath: target.path, allowedRoots: [root.path])
        try Data("old destination".utf8).write(to: target)
        var stages: [String] = []
        let save: (String) throws -> String = { stage in
            stages.append(stage)
            let parent = URL(fileURLWithPath: stage).deletingLastPathComponent()
            let attrs = try FileManager.default.attributesOfItem(atPath: parent.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage))
            XCTAssertNotEqual(stage, target.path)
            let script = """
            tell application "Mail"
                set boxes to (every mailbox whose name is "\(token)")
                if (count boxes) is not 1 then error "fixture mailbox is not unique"
                set box to item 1 of boxes
                if (count messages of box) is not 1 then error "fixture message count differs"
                set msg to message 1 of box
                if subject of msg is not "\(token)" then error "fixture subject differs"
                if message id of msg is not "\(token)@example.invalid" then error "fixture Message-ID differs"
                if (count mail attachments of msg) is not 1 then error "fixture attachment count differs"
                set att to mail attachment 1 of msg
                if name of att is not "idd402.bin" then error "fixture attachment name differs"
                save att in POSIX file "\(appleScriptEscape(stage))"
                return "Attachment saved"
            end tell
            """
            XCTAssertFalse(script.contains(target.path))
            let result = try self.runScript(script, timeout: 15)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stage)), expected)
            return result
        }
        let receipt = try destination.saveUsingScript(save, allowEmpty: false)
        XCTAssertTrue(receipt.hasSuffix("(\(expected.count) bytes)"))
        XCTAssertEqual(try Data(contentsOf: target), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: stages[0]).deletingLastPathComponent().path))

        // Mail really writes a second stage, then an upstream error interrupts
        // publication. The existing destination must survive and the stage go.
        XCTAssertThrowsError(try destination.saveUsingScript({ stage in
            _ = try save(stage)
            throw MailError.operationFailed("synthetic failure after native stage write")
        }, allowEmpty: false)) { error in
            guard case MailError.operationFailed(let reason) = error else {
                return XCTFail("unexpected native save failure: \(error)")
            }
            XCTAssertEqual(reason, "synthetic failure after native stage write")
        }
        XCTAssertEqual(try Data(contentsOf: target), expected)
        XCTAssertEqual(Set(stages).count, 2)
        for stage in stages {
            XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: stage).deletingLastPathComponent().path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["saved.bin"])
    }
}
