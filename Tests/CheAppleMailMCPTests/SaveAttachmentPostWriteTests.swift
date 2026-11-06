import XCTest
@testable import CheAppleMailMCP

/// #314 — a 0-byte write must not return the same success string as a correct
/// write. Mail.app's `save att in POSIX file` (Tier 2) is a black box that can
/// write an empty file and return without error; before this fix the tool
/// passed "Attachment saved to …" straight through, indistinguishable to every
/// caller and invisible to the count-based archive audit (three 0-byte
/// attachments sat undetected for ~11 weeks).
final class SaveAttachmentPostWriteTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postwrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }
    /// An explicit root: the default policy would need the real home, and a set
    /// CHE_MAIL_EXPORT_ALLOWED_ROOTS would reject it (#402 verify).
    private func destination(_ p: String) throws -> AttachmentDestination {
        try AttachmentDestination(savePath: p, allowedRoots: [dir.path])
    }
    private func path(_ n: String) -> String { dir.appendingPathComponent(n).path }

    /// Runs the publication step #402 made the only one: `run` stands in for
    /// Mail, writing to the private stage path it is handed.
    private func save(_ p: String, stage: (String) throws -> String) throws -> String {
        try destination(p).saveUsingScript({ try stage($0) }, allowEmpty: false)
    }

    // MARK: - saveUsingScript

    func testZeroByteFile_throwsActionableError() throws {
        let p = path("empty.pdf")
        XCTAssertThrowsError(try save(p) { stage in
            FileManager.default.createFile(atPath: stage, contents: Data())
            return "Attachment saved to \(stage)"
        }) { error in
            let msg = error.localizedDescription
            XCTAssertTrue(msg.contains("0-byte"), "must name the failure shape: \(msg)")
            XCTAssertTrue(msg.contains("synchronize_account") || msg.contains("download_if_missing"),
                          "must be actionable: \(msg)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: p), "nothing reaches save_path")
    }

    func testMissingFile_throws() {
        let p = path("never-written.pdf")
        XCTAssertThrowsError(try save(p) { "Attachment saved to \($0)" },
            "success string + nothing staged = Mail's save silently failed")
    }

    func testRealBytes_appendsSizeSuffix() throws {
        let p = path("real.pdf")
        let out = try save(p) { stage in
            FileManager.default.createFile(atPath: stage, contents: Data(repeating: 7, count: 1234))
            return "Attachment saved to \(stage)"
        }
        XCTAssertEqual(out, "Attachment saved to \(p) (1234 bytes)",
                       "a verified success must carry the size — list_attachments has no "
                       + "size field, so this is the only size signal callers/audits get")
    }

    func testNonSuccessStrings_passThroughUntouched() throws {
        let p = path("whatever.pdf")
        XCTAssertEqual(try save(p) { _ in "Attachment not found" }, "Attachment not found",
                       "only success claims are verified; negatives are not rewritten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: p))
    }

    // MARK: - through the real Tier-2 overload (script runner stubbed)

    /// The full path: the AppleScript layer reports success, the disk holds a
    /// 0-byte file — the tool call must throw, not return success. RED before
    /// the fix: the overload returned the runner's string unchecked.
    func testSaveAttachment_zeroByteAfterScriptSuccess_throws() async throws {
        let p = path("from-mail.pdf")
        FileManager.default.createFile(atPath: p, contents: Data())   // Mail "saved" an empty file

        await MailController.shared.setTestSeams(
            scriptRunner: { source in try stageAttachmentFixture(source, data: Data()) }, refusal: { nil })

        do {
            _ = try await MailController.shared.saveAttachment(
                id: "1", mailbox: "INBOX", accountId: nil, accountName: "A",
                attachmentName: "from-mail.pdf", destination: try destination(p))
            XCTFail("a 0-byte result behind a success string must throw (#314)")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("0-byte"),
                          "unexpected error: \(error.localizedDescription)")
        }
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
    }

    func testSaveAttachment_realBytes_succeedsWithSize() async throws {
        let p = path("ok.pdf")
        FileManager.default.createFile(atPath: p, contents: Data(repeating: 1, count: 99))

        await MailController.shared.setTestSeams(
            scriptRunner: { source in try stageAttachmentFixture(source, data: Data(repeating: 1, count: 99)) }, refusal: { nil })

        do {
        let out = try await MailController.shared.saveAttachment(
            id: "1", mailbox: "INBOX", accountId: nil, accountName: "A",
            attachmentName: "ok.pdf", destination: try destination(p))
        XCTAssertTrue(out.hasSuffix("(99 bytes)"), "got: \(out)")
        } catch {
            await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
    }
}
