import XCTest
@testable import CheAppleMailMCP

final class AttachmentContainmentIntegrationTests: XCTestCase {
    private func withRunner(_ runner: @escaping (String) throws -> String,
                            body: () async throws -> Void) async throws {
        await MailController.shared.setTestSeams(scriptRunner: runner, refusal: { nil })
        do { try await body() }
        catch {
            await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
    }

    func testBothStringOverloadsAndRetryRejectBeforeAnyScript() async throws {
        let invalid = NSHomeDirectory() + "/.ssh/idd402-do-not-create"
        var scripts = 0
        try await withRunner({ _ in scripts += 1; return "Attachment saved" }) {
            for entry in 0..<3 {
                do {
                    if entry == 0 {
                        _ = try await MailController.shared.saveAttachment(
                            id: "1", mailbox: "INBOX", accountName: "Fixture",
                            attachmentName: "x", savePath: invalid)
                    } else if entry == 1 {
                        _ = try await MailController.shared.saveAttachment(
                            id: "1", mailbox: "INBOX", accountId: "UUID-FIXTURE", accountName: "Fixture",
                            attachmentName: "x", savePath: invalid)
                    } else {
                        _ = try await MailController.shared.saveAttachmentRetryingForDownload(
                            id: "1", mailbox: "INBOX", accountId: nil, accountName: "Fixture",
                            attachmentName: "x", savePath: invalid,
                            policy: DownloadRetryPolicy(timeout: 0.1, pollInterval: 0.001))
                    }
                    XCTFail("unsafe destination accepted")
                } catch is AttachmentDestinationError { }
            }
            XCTAssertEqual(scripts, 0, "neither save nor fetch-trigger can run for a denied destination")
        }
    }

    func testRetryPublicationFailureIsTerminalAndNeverUsesCallerPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idd402-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("result")
        let destination = try AttachmentDestination(savePath: target.path, allowedRoots: [root.path])
        var saves = 0, triggers = 0
        var stages: [String] = []
        try await withRunner({ source in
            if source.contains("source of") { triggers += 1; return "" }
            saves += 1
            XCTAssertFalse(source.contains(target.path))
            XCTAssertTrue(source.contains("account id \"UUID-FIXTURE\""))
            stages.append(try attachmentStagePath(source))
            // Simulate an incompatible destination appearing after preparation.
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            return try stageAttachmentFixture(source, data: Data([1, 2]))
        }) {
            do {
                _ = try await MailController.shared.saveAttachmentRetryingForDownload(
                    id: "1", mailbox: "INBOX", accountId: "UUID-FIXTURE", accountName: "Fixture",
                    attachmentName: "x", destination: destination,
                    policy: DownloadRetryPolicy(timeout: 0.2, pollInterval: 0.001))
                XCTFail("publication error must propagate")
            } catch AttachmentDestinationError.io { }
            XCTAssertEqual(triggers, 1)
            XCTAssertEqual(saves, 1, "destination errors must not consume the retry loop")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["result"])
            for path in stages {
                XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
            }
        }
    }

    func testRetryUsesFreshStagesAndCannotAcceptPreviousAttemptBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idd402-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try AttachmentDestination(savePath: root.path + "/result", allowedRoots: [root.path])
        var stages: [String] = []
        try await withRunner({ source in
            if source.contains("source of") { return "" }
            let path = try attachmentStagePath(source)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            stages.append(path)
            if stages.count == 1 {
                _ = try stageAttachmentFixture(source, data: Data([9]))
                throw MailError.scriptFailed(message: "fixture error after write", code: -10000)
            }
            if stages.count == 2 { return "Attachment saved to \(path)" } // no bytes
            return try stageAttachmentFixture(source, data: Data([3]))
        }) {
            let result = try await MailController.shared.saveAttachmentRetryingForDownload(
                id: "1", mailbox: "INBOX", accountId: nil, accountName: "Fixture",
                attachmentName: "x", destination: destination,
                policy: DownloadRetryPolicy(timeout: 1, pollInterval: 0.001))
            XCTAssertEqual(stages.count, 3)
            XCTAssertEqual(Set(stages).count, 3)
            XCTAssertTrue(result.hasSuffix("(1 bytes)"))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("result")), Data([3]))
            for path in stages { XCTAssertFalse(FileManager.default.fileExists(atPath: path)) }
        }
    }
}
