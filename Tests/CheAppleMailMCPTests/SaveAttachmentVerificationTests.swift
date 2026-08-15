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

    /// A path that EXISTS but cannot be examined is not "missing" (verify
    /// round 1). Reporting `ELOOP` as `.missing` told the caller no file was
    /// there, and made the call eligible for a download retry that cannot
    /// possibly unpick a symlink loop.
    func testSymlinkLoop_isStatFailedNotMissing() throws {
        let a = path("loop-a.pdf"), b = path("loop-b.pdf")
        try FileManager.default.createSymbolicLink(atPath: a, withDestinationPath: b)
        try FileManager.default.createSymbolicLink(atPath: b, withDestinationPath: a)

        XCTAssertThrowsError(try verify(a)) { error in
            guard case MailError.attachmentWriteUnverified(_, .statFailed(let e)) = error else {
                return XCTFail("expected .statFailed, got \(error)")
            }
            XCTAssertEqual(e, ELOOP, "the errno must be carried, not flattened away")
            XCTAssertTrue(error.localizedDescription.lowercased().contains("symlink loop"),
                          "the message must point at the real cause: \(error.localizedDescription)")
        }
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
        XCTAssertFalse(
            shouldAttemptDownloadRetry(afterUnverifiedWrite: .statFailed(errno: ELOOP),
                                       downloadIfMissing: true),
            "nor unpick a symlink loop, a permissions problem, or an I/O error")
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
        try await withSeam({ _ in
            // Call 1 is the fetch-trigger; the saves follow. Let the first save
            // find an empty file, then have the bytes "arrive".
            if calls.bump() >= 3 {
                FileManager.default.createFile(atPath: p, contents: Data(repeating: 9, count: 512))
            }
            return "Attachment saved to \(p)"
        }) {
            let out = try await MailController.shared.saveAttachmentRetryingForDownload(
                id: "1", mailbox: "INBOX", accountId: nil, accountName: "A",
                attachmentName: "late.pdf", savePath: p,
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
        try await withSeam({ _ in _ = calls.bump(); return "Attachment saved to \(p)" }) {
            do {
                _ = try await MailController.shared.saveAttachmentRetryingForDownload(
                    id: "1", mailbox: "INBOX", accountId: nil, accountName: "A",
                    attachmentName: "never.pdf", savePath: p,
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
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return n }
}
