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
    private func path(_ n: String) -> String { dir.appendingPathComponent(n).path }

    // MARK: - the verifier itself

    func testZeroByteFile_throwsActionableError() throws {
        let p = path("empty.pdf")
        FileManager.default.createFile(atPath: p, contents: Data())
        XCTAssertThrowsError(
            try MailController.verifySavedAttachmentOnDisk("Attachment saved to \(p)", savePath: p)
        ) { error in
            let msg = error.localizedDescription
            XCTAssertTrue(msg.contains("0-byte"), "must name the failure shape: \(msg)")
            XCTAssertTrue(msg.contains("synchronize_account") || msg.contains("download_if_missing"),
                          "must be actionable: \(msg)")
        }
    }

    func testMissingFile_throws() {
        let p = path("never-written.pdf")
        XCTAssertThrowsError(
            try MailController.verifySavedAttachmentOnDisk("Attachment saved to \(p)", savePath: p),
            "success string + no file on disk = Mail's save silently failed")
    }

    func testRealBytes_appendsSizeSuffix() throws {
        let p = path("real.pdf")
        FileManager.default.createFile(atPath: p, contents: Data(repeating: 7, count: 1234))
        let out = try MailController.verifySavedAttachmentOnDisk("Attachment saved to \(p)", savePath: p)
        XCTAssertEqual(out, "Attachment saved to \(p) (1234 bytes)",
                       "a verified success must carry the size — list_attachments has no "
                       + "size field, so this is the only size signal callers/audits get")
    }

    func testNonSuccessStrings_passThroughUntouched() throws {
        let p = path("whatever.pdf")
        XCTAssertEqual(
            try MailController.verifySavedAttachmentOnDisk("Attachment not found", savePath: p),
            "Attachment not found",
            "only success claims are verified; negatives are not rewritten")
    }

    // MARK: - through the real Tier-2 overload (script runner stubbed)

    /// The full path: the AppleScript layer reports success, the disk holds a
    /// 0-byte file — the tool call must throw, not return success. RED before
    /// the fix: the overload returned the runner's string unchecked.
    func testSaveAttachment_zeroByteAfterScriptSuccess_throws() async throws {
        let p = path("from-mail.pdf")
        FileManager.default.createFile(atPath: p, contents: Data())   // Mail "saved" an empty file

        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Attachment saved to \(p)" }, refusal: { nil })
        defer { Task { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) } }

        do {
            _ = try await MailController.shared.saveAttachment(
                id: "1", mailbox: "INBOX", accountName: "A",
                attachmentName: "from-mail.pdf", savePath: p)
            XCTFail("a 0-byte result behind a success string must throw (#314)")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("0-byte"),
                          "unexpected error: \(error.localizedDescription)")
        }
    }

    func testSaveAttachment_realBytes_succeedsWithSize() async throws {
        let p = path("ok.pdf")
        FileManager.default.createFile(atPath: p, contents: Data(repeating: 1, count: 99))

        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Attachment saved to \(p)" }, refusal: { nil })
        defer { Task { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) } }

        let out = try await MailController.shared.saveAttachment(
            id: "1", mailbox: "INBOX", accountName: "A",
            attachmentName: "ok.pdf", savePath: p)
        XCTAssertTrue(out.hasSuffix("(99 bytes)"), "got: \(out)")
    }
}
