import XCTest
@testable import CheAppleMailMCP

/// #347 — three defects in #314's post-write verification.
///
/// **(A)** `FileManager.attributesOfItem(atPath:)` does not follow symlinks.
/// For a link it reports `.type = .symbolicLink` and a `.size` equal to the
/// **length of the link's target path**. Measured:
///
/// ```
/// empty.txt: type=NSFileTypeRegular      size=0
/// link.txt:  type=NSFileTypeSymbolicLink size=55   ← path length, not content
/// ```
///
/// So a `save_path` that is a symlink onto an empty file sails past the
/// `size > 0` guard reporting `(55 bytes)` — the exact silent-loss state #314
/// exists to catch, passing verification with a plausible-looking number.
///
/// **(B)** The verifier throws `MailError.operationFailed`, a general-purpose
/// container, while both retry sites match `MailError.scriptFailed`. A 0-byte
/// write therefore flies past the `download_if_missing` recovery its own error
/// message recommends. The fix is a **typed** case, so the retry contract can
/// match on structure rather than on prose.
///
/// **(C)** A legitimately empty attachment was unarchivable with no override.
final class SaveAttachmentVerificationTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verify347-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }
    private func path(_ n: String) -> String { dir.appendingPathComponent(n).path }

    private func verify(_ p: String, allowEmpty: Bool = false) throws -> String {
        try MailController.verifySavedAttachmentOnDisk(
            "Attachment saved to \(p)", savePath: p, allowEmpty: allowEmpty)
    }

    // MARK: - (A) the stat must follow the link and land on a regular file

    /// The headline defect: the guard passes on the one state it exists to catch.
    func testSymlinkToEmptyFile_isRejected() throws {
        let target = path("target-empty.pdf")
        let link = path("link.pdf")
        FileManager.default.createFile(atPath: target, contents: Data())
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        XCTAssertThrowsError(try verify(link),
            "a symlink onto a 0-byte file must NOT verify — attributesOfItem reports the "
            + "link path's length as the size, which is non-zero and looks like a real file") { error in
            XCTAssertTrue(error.localizedDescription.contains("0-byte"),
                          "must name the real shape: \(error.localizedDescription)")
        }
    }

    /// Even a correct write through a symlink reported the wrong number.
    func testSymlinkToRealFile_reportsTargetSizeNotLinkLength() throws {
        let target = path("target-real.pdf")
        let link = path("link-real.pdf")
        FileManager.default.createFile(atPath: target, contents: Data(repeating: 3, count: 4096))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        XCTAssertTrue(try verify(link).hasSuffix("(4096 bytes)"),
            "the size must come from the link's TARGET; the link path's own length is "
            + "meaningless and varies with where the temp dir happens to be")
    }

    /// Polling cannot turn a directory into a file, so this is terminal — and
    /// under the old code a directory's non-zero `.size` passed verification.
    func testDirectoryAtSavePath_isRejected() throws {
        let p = path("a-directory.pdf")
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        XCTAssertThrowsError(try verify(p)) { error in
            guard case MailError.attachmentWriteUnverified(_, let problem) = error else {
                return XCTFail("expected attachmentWriteUnverified, got \(error)")
            }
            guard case .notRegular = problem else {
                return XCTFail("a directory is a non-regular file, got \(problem)")
            }
        }
    }

    /// A FIFO is the case that argues for `stat` over `open` + `fstat`: opening
    /// one blocks until a writer arrives, and this runs on the shared actor.
    func testFifoAtSavePath_isRejectedPromptly() throws {
        let p = path("a-fifo.pdf")
        XCTAssertEqual(mkfifo(p, 0o600), 0, "could not create the fixture FIFO")

        let start = Date()
        XCTAssertThrowsError(try verify(p)) { error in
            guard case MailError.attachmentWriteUnverified(_, .notRegular) = error else {
                return XCTFail("expected .notRegular, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0,
            "must reject at the stat, not block waiting for a writer to open the FIFO")
    }

    // MARK: - (B) the error must be typed so the retry contract can match it

    func testZeroByte_throwsTypedCaseNotTheGenericContainer() throws {
        let p = path("empty.pdf")
        FileManager.default.createFile(atPath: p, contents: Data())
        XCTAssertThrowsError(try verify(p)) { error in
            guard case MailError.attachmentWriteUnverified(let path, let problem) = error else {
                return XCTFail("#314 threw operationFailed, which no retry site matches — "
                               + "got \(error)")
            }
            XCTAssertEqual(path, p)
            guard case .empty = problem else { return XCTFail("expected .empty, got \(problem)") }
        }
    }

    func testMissingFile_throwsTypedCase() {
        let p = path("never-written.pdf")
        XCTAssertThrowsError(try verify(p)) { error in
            guard case MailError.attachmentWriteUnverified(_, .missing) = error else {
                return XCTFail("expected .missing, got \(error)")
            }
        }
    }

    /// A 0-byte write is itself evidence the bytes are not local, so it is
    /// eligible for the download retry **without** the separate `not_downloaded`
    /// proof that a `-10000` needs.
    func testRetryEligibility_zeroByteQualifiesOnOptInAlone() {
        XCTAssertTrue(shouldAttemptDownloadRetry(afterUnverifiedWrite: .empty, downloadIfMissing: true))
        XCTAssertTrue(shouldAttemptDownloadRetry(afterUnverifiedWrite: .missing, downloadIfMissing: true))
        XCTAssertFalse(shouldAttemptDownloadRetry(afterUnverifiedWrite: .empty, downloadIfMissing: false),
                       "opt-in is still required — this must not change default behavior")
        XCTAssertFalse(
            shouldAttemptDownloadRetry(afterUnverifiedWrite: .notRegular("directory"),
                                       downloadIfMissing: true),
            "polling cannot turn a directory into a regular file — terminal, not retryable")
    }

    // MARK: - (B) the loop must consume an attempt, not abort on the first 0-byte

    /// The test the issue names as missing: drive the retry loop through a
    /// 0-byte first attempt. Under #314 the loop's `catch MailError.scriptFailed`
    /// did not match the verifier's throw, so one empty "success" exited the
    /// whole loop and burned the caller's opt-in.
    func testRetryLoop_survivesAZeroByteFirstAttempt() async throws {
        let p = path("late.pdf")
        FileManager.default.createFile(atPath: p, contents: Data())   // starts empty

        let calls = Counter()
        await MailController.shared.setTestSeams(scriptRunner: { _ in
            // Call 1 is the fetch-trigger; the saves follow. Let the first save
            // find an empty file, then have the bytes "arrive".
            if calls.bump() >= 3 {
                FileManager.default.createFile(atPath: p, contents: Data(repeating: 9, count: 512))
            }
            return "Attachment saved to \(p)"
        }, ineligibility: nil)
        defer { Task { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) } }

        let out = try await MailController.shared.saveAttachmentRetryingForDownload(
            id: "1", mailbox: "INBOX", accountId: nil, accountName: "A",
            attachmentName: "late.pdf", savePath: p,
            policy: DownloadRetryPolicy(timeout: 2.0, pollInterval: 0.05))
        XCTAssertTrue(out.hasSuffix("(512 bytes)"),
                      "the loop must keep polling past an empty write; got: \(out)")
    }

    /// …and must still fail honestly when the bytes never arrive. A retry that
    /// converts "never landed" into a success would be worse than the bug.
    func testRetryLoop_stillFailsHonestlyWhenBytesNeverArrive() async throws {
        let p = path("never.pdf")
        FileManager.default.createFile(atPath: p, contents: Data())

        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Attachment saved to \(p)" }, ineligibility: nil)
        defer { Task { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) } }

        do {
            _ = try await MailController.shared.saveAttachmentRetryingForDownload(
                id: "1", mailbox: "INBOX", accountId: nil, accountName: "A",
                attachmentName: "never.pdf", savePath: p,
                policy: DownloadRetryPolicy(timeout: 0.3, pollInterval: 0.05))
            XCTFail("budget exhausted with an empty file must throw, never return success")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("Attachment saved"),
                           "got a success string in the error: \(error.localizedDescription)")
        }
    }

    // MARK: - (C) allow_empty: an override that must leave a trace

    func testAllowEmpty_acceptsZeroBytesAndSaysSoInTheSuccessString() throws {
        let p = path("legitimately-empty.txt")
        FileManager.default.createFile(atPath: p, contents: Data())

        let out = try verify(p, allowEmpty: true)
        XCTAssertTrue(out.contains("0 bytes"), "got: \(out)")
        XCTAssertTrue(out.contains("allow_empty"),
            "the disclosure is the point, not decoration — an archive manifest must be able "
            + "to tell an accepted-empty write from a real one after the fact (#316's "
            + "direction_inferred shape: fail open, but leave a trace)")
    }

    /// `allow_empty` relaxes emptiness ONLY. It must not become a way to accept
    /// a missing file or a directory.
    func testAllowEmpty_doesNotExcuseMissingOrNonRegular() throws {
        XCTAssertThrowsError(try verify(path("absent.txt"), allowEmpty: true)) { error in
            guard case MailError.attachmentWriteUnverified(_, .missing) = error else {
                return XCTFail("expected .missing, got \(error)")
            }
        }
        let d = path("dir.txt")
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        XCTAssertThrowsError(try verify(d, allowEmpty: true)) { error in
            guard case MailError.attachmentWriteUnverified(_, .notRegular) = error else {
                return XCTFail("expected .notRegular, got \(error)")
            }
        }
    }
}

/// Minimal thread-safe call counter for the retry-loop fixture. Not an actor:
/// the script-runner seam is a SYNCHRONOUS closure, so it cannot await.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
