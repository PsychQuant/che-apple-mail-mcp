import XCTest
@testable import CheAppleMailMCP

final class DraftScanRunnerTests: XCTestCase {
    // These scripts never access Mail or System Events. The production
    // Automation preflight still requires Mail to be running.
    private func requireMail() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "Mail"]
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw XCTSkip("Mail must be running for Automation preflight") }
    }

    func testSubprocessPreservesDraftPayload() async throws {
        try requireMail()
        let value = try await MailController.shared.runDraftScanScript(
            "return \"123\" & (ASCII character 29) & \"中文,草稿\" & (ASCII character 30) & (ASCII character 13)")
        XCTAssertEqual(value, "123\u{001D}中文,草稿\u{001E}\r")
    }

    func testSubprocessPreservesNoMatchErrorCode() async throws {
        try requireMail()
        do {
            _ = try await MailController.shared.runDraftScanScript("error \"no match\" number 9174")
            XCTFail("expected script error")
        } catch MailError.scriptFailed(let message, let code) {
            XCTAssertEqual(code, listDraftsNoMatchErrorNumber)
            XCTAssertTrue(message.contains("no match"))
        }
    }

    func testTimeoutStopsChildAndReportsReadScan() async throws {
        try requireMail()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let command = "/usr/bin/touch '" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let start = Date()
        do {
            _ = try await MailController.shared.runDraftScanScript(
                "delay 2\ndo shell script \"\(appleScriptEscape(command))\"", timeout: 0.1)
            XCTFail("expected timeout")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("drafts scan"), message)
            XCTAssertTrue(message.contains("termination"), message)
            XCTAssertFalse(message.contains("GUI"), message)
            XCTAssertFalse(message.contains("cannot be cancelled"), message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        try await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "timed-out interpreter must not continue")
    }

    func testAllDraftReadSitesUseScanRunnerAndEscapeIsGUIOnly() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift"))
        XCTAssertTrue(source.contains("if guiFlow { Self.dismissLingeringGuiMenu() }"))
        XCTAssertTrue(source.contains("runSubprocessScript(source, timeout: timeout ?? Self.defaultScriptTimeout, guiFlow: false)"))
        XCTAssertFalse(source.contains("runScript(receiptScript)"), "both receipt families must avoid background NSAppleScript")
        XCTAssertFalse(source.contains("runScript(listScript)"), "locate must use scan runner")
        let list = source.components(separatedBy: "func listDrafts(")[1].components(separatedBy: "func updateDraft(")[0]
        XCTAssertTrue(list.contains("runDraftScanScript(script)"))
        XCTAssertTrue(source.contains("runDraftDeleteScript(deleteScript)"))
        XCTAssertFalse(source.contains("runScript(deleteScript)"))
    }

    func testDeleteTimeoutReportsUnknownOutcome() async throws {
        try requireMail()
        do {
            _ = try await MailController.shared.runDraftDeleteScript("delay 2", timeout: 0.1)
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("deletion outcome is unknown"))
            XCTAssertFalse(error.localizedDescription.contains("read-only"))
            XCTAssertFalse(error.localizedDescription.contains("GUI"))
        }
    }

    func testLocateTimeoutRefusesBeforeCreatingReplacement() async throws {
        let scripts = ScanScriptLog()
        addTeardownBlock {
            await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        }
        await MailController.shared.setTestSeams(scriptRunner: { source in
            scripts.append(source)
            Thread.sleep(forTimeInterval: 0.2)
            return "123\u{001D}old"
        }, refusal: { nil }, scriptTimeout: 0.01)
        do {
            _ = try await MailController.shared.updateDraft(
                draftId: "123", subjectMatch: nil, accountName: "iCloud", accountId: nil,
                to: ["test@example.invalid"], subject: "new", body: "body")
            XCTFail("locate timeout must refuse")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("drafts scan"))
        }
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        try await Task.sleep(nanoseconds: 250_000_000) // let the fake runner finish
        XCTAssertEqual(scripts.count, 1, "no create, receipt, or delete after failed locate")
    }
}

private final class ScanScriptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ script: String) { lock.lock(); defer { lock.unlock() }; entries.append(script) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}
