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
    /// An explicit root: the default policy would need the real home, and a set
    /// CHE_MAIL_EXPORT_ALLOWED_ROOTS would reject it (#402 verify).
    private func destination(_ p: String) throws -> AttachmentDestination {
        try AttachmentDestination(savePath: p, allowedRoots: [dir.path])
    }
    private func path(_ n: String) -> String { dir.appendingPathComponent(n).path }

    /// Install the script-runner seam and reset it **synchronously** on both
    /// exits. Verify round 1: a deferred `Task { }` reset can run after the NEXT
    /// test has installed its own seam and clobber it — that test then reaches
    /// real NSAppleScript, touching TCC/Mail or hanging for 45s. Copied from
    /// `AttachmentDownloadScriptBuilderTests`, which already documented this.
    private func withSeam(_ runner: @escaping (String) throws -> String,
                          _ body: () async throws -> Void) async throws {
        await MailController.shared.setTestSeams(scriptRunner: runner, refusal: nil)
        do {
            try await body()
        } catch {
            await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
    }

    /// The publication step #402 made the only one: `stage` stands in for Mail
    /// and puts whatever it likes at the private stage path. `verifySavedAttachmentOnDisk`
    /// is gone (#575), so these are the #347 contracts where they now hold.
    private func save(_ p: String, allowEmpty: Bool = false,
                      stage: (String) throws -> Void = { _ in }) throws -> String {
        try destination(p).saveUsingScript({ stagePath in
            try stage(stagePath)
            return "Attachment saved to \(stagePath)"
        }, allowEmpty: allowEmpty)
    }

    private func stageBytes(_ data: Data) -> (String) throws -> Void {
        { stagePath in try data.write(to: URL(fileURLWithPath: stagePath)) }
    }

    // MARK: - (A) what Mail left at the stage must be a regular file

    /// The headline defect, in the form it takes since #402: what Mail leaves at
    /// the stage is opened without following links, so a link is never published.
    func testStagedSymlinkToEmptyFile_isRejected() throws {
        let target = path("target-empty.pdf")
        FileManager.default.createFile(atPath: target, contents: Data())
        XCTAssertThrowsError(try save(path("out.pdf")) { stage in
            try FileManager.default.createSymbolicLink(atPath: stage, withDestinationPath: target)
        }) { error in
            guard case AttachmentDestinationError.stage = error else { return XCTFail("\(error)") }
        }
    }

    func testStagedSymlinkToRealFile_isRejectedNotCopied() throws {
        let target = path("target-real.pdf")
        FileManager.default.createFile(atPath: target, contents: Data(repeating: 3, count: 4096))
        let p = path("out.pdf")
        XCTAssertThrowsError(try save(p) { stage in
            try FileManager.default.createSymbolicLink(atPath: stage, withDestinationPath: target)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: p), "bytes behind a link are not the stage's")
    }

    /// Polling cannot turn a directory into a file, so this is terminal.
    func testStagedDirectory_isRejected() throws {
        XCTAssertThrowsError(try save(path("out.pdf")) { stage in
            try FileManager.default.createDirectory(atPath: stage, withIntermediateDirectories: true)
        }) { error in
            guard case MailError.attachmentWriteUnverified(_, .notRegular) = error else {
                return XCTFail("a directory is a non-regular file, got \(error)")
            }
        }
    }

    /// Opening a FIFO without `O_NONBLOCK` blocks until a writer arrives, and
    /// this runs on the shared actor.
    func testStagedFifo_isRejectedPromptly() throws {
        let start = Date()
        XCTAssertThrowsError(try save(path("out.pdf")) { stage in
            XCTAssertEqual(mkfifo(stage, 0o600), 0, "could not create the fixture FIFO")
        }) { error in
            guard case MailError.attachmentWriteUnverified(_, .notRegular) = error else {
                return XCTFail("expected .notRegular, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0,
            "must reject, not block waiting for a writer to open the FIFO")
    }

    /// A link loop is not "missing": that would make the call eligible for a
    /// download retry that cannot unpick it.
    func testStagedSymlinkLoop_isAStageFailureNotMissing() throws {
        XCTAssertThrowsError(try save(path("out.pdf")) { stage in
            try FileManager.default.createSymbolicLink(atPath: stage, withDestinationPath: stage)
        }) { error in
            guard case AttachmentDestinationError.stage = error else {
                return XCTFail("expected a stage failure, got \(error)")
            }
        }
    }

    // MARK: - (B) the error must be typed so the retry contract can match it

    func testZeroByte_throwsTypedCaseNotTheGenericContainer() throws {
        let p = path("empty.pdf")
        XCTAssertThrowsError(try save(p, stage: stageBytes(Data()))) { error in
            guard case MailError.attachmentWriteUnverified(let path, let problem) = error else {
                return XCTFail("#314 threw operationFailed, which no retry site matches — "
                               + "got \(error)")
            }
            XCTAssertEqual(path, p)
            guard case .empty = problem else { return XCTFail("expected .empty, got \(problem)") }
        }
    }

    func testMissingFile_throwsTypedCase() {
        XCTAssertThrowsError(try save(path("never-written.pdf"))) { error in
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
        try await withSeam({ source in
            let count = calls.bump()
            if source.contains("source of") { return "" }
            return try stageAttachmentFixture(source, data: count >= 3 ? Data(repeating: 9, count: 512) : Data())
        }) {
            let out = try await MailController.shared.saveAttachmentRetryingForDownload(
                id: "1", mailbox: "INBOX", accountId: nil, accountName: "A",
                attachmentName: "late.pdf", destination: try destination(p),
                enteredAfterUnverifiedWrite: .empty,
                policy: DownloadRetryPolicy(timeout: 2.0, pollInterval: 0.05))
            XCTAssertTrue(out.hasSuffix("(512 bytes)"),
                          "the loop must keep polling past an empty write; got: \(out)")
            XCTAssertGreaterThanOrEqual(calls.value(), 3,
                "trigger + at least two saves — fewer means the loop exited early "
                + "rather than polling through the empty write")
        }
    }

    /// …and must still fail honestly when the bytes never arrive. A retry that
    /// converts "never landed" into a success would be worse than the bug.
    /// Strengthened after verify round 1: the first version asserted only that
    /// the error text lacked "Attachment saved", which the *pre-fix* immediate
    /// abort also satisfies — it could not tell "polled to exhaustion" from
    /// "gave up on attempt one". It now pins both the attempt count and the
    /// error's TYPE, and that type is the second fix: the loop used to report
    /// `not downloaded` no matter why it ran, fabricating a diagnosis for an
    /// attachment that may be local and genuinely empty.
    func testRetryLoop_stillFailsHonestlyWhenBytesNeverArrive() async throws {
        let p = path("never.pdf")
        FileManager.default.createFile(atPath: p, contents: Data())

        let calls = Counter()
        try await withSeam({ source in
            _ = calls.bump()
            if source.contains("source of") { return "" }
            return try stageAttachmentFixture(source, data: Data())
        }) {
            do {
                _ = try await MailController.shared.saveAttachmentRetryingForDownload(
                    id: "1", mailbox: "INBOX", accountId: nil, accountName: "A",
                    attachmentName: "never.pdf", destination: try destination(p),
                    enteredAfterUnverifiedWrite: .empty,
                    policy: DownloadRetryPolicy(timeout: 0.3, pollInterval: 0.05))
                XCTFail("budget exhausted with an empty file must throw, never return success")
            } catch MailError.attachmentWriteUnverified(_, .empty) {
                XCTAssertGreaterThanOrEqual(calls.value(), 3,
                    "must have polled to exhaustion (trigger + ≥2 saves), not aborted on the "
                    + "first empty write — the distinction the old assertion could not make")
            } catch {
                XCTFail("must surface the real reason, typed. The loop used to claim "
                        + "'not downloaded' regardless of why it ran. Got: \(error)")
            }
        }
    }

    // MARK: - (C) allow_empty: an override that must leave a trace

    func testAllowEmpty_acceptsZeroBytesAndSaysSoInTheSuccessString() throws {
        let out = try save(path("legitimately-empty.txt"), allowEmpty: true, stage: stageBytes(Data()))
        XCTAssertTrue(out.contains("0 bytes"), "got: \(out)")
        XCTAssertTrue(out.contains("allow_empty"),
            "the disclosure is the point, not decoration — an archive manifest must be able "
            + "to tell an accepted-empty write from a real one after the fact (#316's "
            + "direction_inferred shape: fail open, but leave a trace)")
    }

    /// `allow_empty` relaxes emptiness ONLY. It must not become a way to accept
    /// a missing file or a directory.
    func testAllowEmpty_doesNotExcuseMissingOrNonRegular() throws {
        XCTAssertThrowsError(try save(path("absent.txt"), allowEmpty: true)) { error in
            guard case MailError.attachmentWriteUnverified(_, .missing) = error else {
                return XCTFail("expected .missing, got \(error)")
            }
        }
        XCTAssertThrowsError(try save(path("dir.txt"), allowEmpty: true) { stage in
            try FileManager.default.createDirectory(atPath: stage, withIntermediateDirectories: true)
        }) { error in
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
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return n }
}
