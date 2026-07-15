import XCTest
import Foundation
@testable import CheAppleMailMCP

/// Tests for the best-effort `download_if_missing` machinery (#272, Option B):
/// `buildTriggerDownloadScript` (the non-GUI fetch nudge), the
/// `shouldAttemptDownloadRetry` gating predicate, and `DownloadRetryPolicy`.
///
/// These are pure / actor-free — the script text, the gate, and the poll
/// schedule are all deterministic. The *live* question the spike could NOT
/// settle (does reading `source of theMessage` actually pull a server-side
/// attachment into the local store?) is a pre-merge live gate, NOT unit-tested
/// here — same discipline as #268/#249's deferred live checks.
final class AttachmentDownloadScriptBuilderTests: XCTestCase {

    // MARK: - Builder: message resolution + fetch trigger

    func testTriggerScript_resolvesMessageByRowIdAndMailbox() {
        let script = buildTriggerDownloadScript(
            id: "42", mailbox: "INBOX", accountId: nil, accountName: "Google")
        // Reuses the shared resolveMsgRef chokepoint (legacy display_name form
        // when accountId is nil) — must address the message by ROWID under its
        // mailbox, not scan the whole store.
        XCTAssertTrue(script.contains("first message of"),
                      "trigger must resolve a single message; got:\n\(script)")
        XCTAssertTrue(script.contains("whose id is 42"),
                      "trigger must match the message by ROWID; got:\n\(script)")
        XCTAssertTrue(script.contains("whose name is \"INBOX\""),
                      "trigger must scope to the given mailbox; got:\n\(script)")
        XCTAssertTrue(script.contains("account \"Google\""),
                      "nil accountId must fall back to the display_name selector; got:\n\(script)")
    }

    func testTriggerScript_prefersAccountIdWhenProvided() {
        let script = buildTriggerDownloadScript(
            id: "42", mailbox: "INBOX", accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("account id \"UUID-A\""),
                      "non-empty accountId must use the globally-unique UUID selector; got:\n\(script)")
        XCTAssertFalse(script.contains("account \"Google\""),
                       "UUID path must not emit the display_name selector; got:\n\(script)")
    }

    /// The whole point of the trigger: force Mail to MATERIALIZE the full
    /// message so a server-side-only attachment is pulled into the local store.
    /// Reading `source` (the raw RFC 822) requires the complete message — the
    /// least-intrusive (non-GUI, no viewer window) nudge available.
    func testTriggerScript_forcesMaterializationViaSourceRead() {
        let script = buildTriggerDownloadScript(
            id: "42", mailbox: "INBOX", accountId: nil, accountName: "Google")
        XCTAssertTrue(script.contains("source of"),
                      "trigger must read `source of` to force a full-message fetch; got:\n\(script)")
    }

    /// #221 guard: the trigger scopes to ONE resolved message, never a
    /// `whose content contains` corpus scan (which OOMs Mail on big mailboxes).
    func testTriggerScript_neverUsesContentContainsScan() {
        let script = buildTriggerDownloadScript(
            id: "42", mailbox: "INBOX", accountId: nil, accountName: "Google")
        XCTAssertFalse(script.contains("whose content contains"),
                       "trigger must never full-scan message bodies (#221); got:\n\(script)")
    }

    // MARK: - Builder: escaping (injection audit)

    func testTriggerScript_escapesInjectionInSelectors() {
        let uuidMode = buildTriggerDownloadScript(
            id: "42", mailbox: "a\"b", accountId: "u\"id", accountName: "x")
        XCTAssertTrue(uuidMode.contains("u\\\"id"), "quote in accountId must be escaped")
        XCTAssertTrue(uuidMode.contains("a\\\"b"), "quote in mailbox must be escaped")
        let nameMode = buildTriggerDownloadScript(
            id: "42", mailbox: "m", accountId: nil, accountName: "has\"quote")
        XCTAssertTrue(nameMode.contains("has\\\"quote"), "quote in accountName must be escaped")
    }

    /// A non-numeric ROWID must never be interpolated raw into `whose id is`
    /// (release-safe guard #118, inherited via resolveMsgRef): it degrades to
    /// the impossible id `-1`, so the script fails cleanly rather than letting
    /// an injected predicate through.
    func testTriggerScript_nonNumericIdIsNeutralized() {
        let script = buildTriggerDownloadScript(
            id: "1 or true", mailbox: "INBOX", accountId: nil, accountName: "Google")
        XCTAssertTrue(script.contains("whose id is -1"),
                      "non-numeric id must be neutralized to -1; got:\n\(script)")
        XCTAssertFalse(script.contains("1 or true"),
                       "raw non-numeric id must never reach the script; got:\n\(script)")
    }

    // MARK: - Gating predicate

    /// The retry path is entered ONLY when all three conditions hold: local
    /// state proved the part is not downloaded, the AppleScript save failed
    /// with the generic -10000 (unfetched-binary class), AND the caller opted
    /// in via download_if_missing. Any missing condition → don't retry (keep
    /// the existing immediate not_downloaded error).
    func testGating_trueOnlyWhenAllThreeConditionsHold() {
        XCTAssertTrue(shouldAttemptDownloadRetry(
            notDownloaded: true, scriptCode: -10000, downloadIfMissing: true),
            "all three true → retry")
        XCTAssertFalse(shouldAttemptDownloadRetry(
            notDownloaded: true, scriptCode: -10000, downloadIfMissing: false),
            "opt-in off → never retry (default behavior preserved)")
        XCTAssertFalse(shouldAttemptDownloadRetry(
            notDownloaded: false, scriptCode: -10000, downloadIfMissing: true),
            "local state did not prove not_downloaded → don't retry")
        XCTAssertFalse(shouldAttemptDownloadRetry(
            notDownloaded: true, scriptCode: -1728, downloadIfMissing: true),
            "a non -10000 code (e.g. bad account) is a real error → don't retry")
    }

    // MARK: - Retry policy

    func testPolicy_defaultsAreBoundedAndSane() {
        let p = DownloadRetryPolicy.default
        XCTAssertGreaterThan(p.timeout, 0, "timeout must be positive")
        XCTAssertGreaterThan(p.pollInterval, 0, "poll interval must be positive")
        XCTAssertLessThanOrEqual(p.pollInterval, p.timeout,
                                 "a single poll must fit within the timeout")
    }

    func testPolicy_maxAttemptsFromTimeoutAndInterval() {
        let p = DownloadRetryPolicy(timeout: 30, pollInterval: 3)
        XCTAssertEqual(p.maxAttempts, 10, "30s / 3s = 10 attempts")
    }

    /// A pathological policy (interval > timeout, or zero) must still yield at
    /// least one attempt — never zero (which would make the loop a silent no-op)
    /// and never a divide-by-zero.
    func testPolicy_maxAttemptsNeverBelowOne() {
        XCTAssertGreaterThanOrEqual(
            DownloadRetryPolicy(timeout: 1, pollInterval: 5).maxAttempts, 1,
            "interval > timeout must still allow one attempt")
        XCTAssertGreaterThanOrEqual(
            DownloadRetryPolicy(timeout: 30, pollInterval: 0).maxAttempts, 1,
            "zero interval must not divide-by-zero; still ≥ 1 attempt")
    }

    // MARK: - Retry loop (deterministic, injected script runner — no live Mail)

    /// A reference box so the fake runner can count save attempts across the
    /// actor boundary without tripping value-capture semantics.
    private final class SaveCounter { var saves = 0; var triggers = 0 }

    /// Tiny budget so the loop's real `Task.sleep`s are negligible.
    private let fastPolicy = DownloadRetryPolicy(timeout: 0.1, pollInterval: 0.005)

    private func withSeam(
        _ runner: @escaping (String) throws -> String,
        _ body: () async throws -> Void
    ) async throws {
        await MailController.shared.setTestSeams(scriptRunner: runner, ineligibility: nil)
        // Reset SYNCHRONOUSLY (await) on both paths — a detached `Task{}` reset
        // could run after the NEXT test installs its own seam and clobber it,
        // making the suite order-dependent / flaky.
        do {
            try await body()
        } catch {
            await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil)
            throw error
        }
        await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil)
    }

    /// The core best-effort promise: if a later save attempt succeeds (the
    /// async fetch landed), the loop returns the saved result — it does NOT
    /// give up after the first -10000.
    func testRetryLoop_succeedsWhenAFetchLandsMidPoll() async throws {
        let counter = SaveCounter()
        try await withSeam({ source in
            if source.contains("source of") { counter.triggers += 1; return "" }
            counter.saves += 1
            // First two saves see the part still server-side (-10000); third lands.
            if counter.saves < 3 { throw MailError.scriptFailed(message: "-10000", code: -10000) }
            return "Attachment saved to /tmp/x.pdf"
        }) {
            let result = try await MailController.shared.saveAttachmentRetryingForDownload(
                id: "42", mailbox: "INBOX", accountId: nil, accountName: "Google",
                attachmentName: "x.pdf", savePath: "/tmp/x.pdf", policy: self.fastPolicy)
            XCTAssertTrue(result.contains("saved"), "a mid-poll success must return the saved result")
            XCTAssertEqual(counter.triggers, 1, "the fetch trigger fires exactly once, before polling")
            XCTAssertGreaterThanOrEqual(counter.saves, 3, "must keep retrying past the early -10000s")
        }
    }

    /// Honest failure: if the attachment never lands within budget, the loop
    /// throws the not_downloaded guidance — never a false "saved".
    func testRetryLoop_throwsNotDownloadedOnTimeout() async throws {
        try await withSeam({ source in
            if source.contains("source of") { return "" }
            throw MailError.scriptFailed(message: "-10000", code: -10000)  // never lands
        }) {
            do {
                _ = try await MailController.shared.saveAttachmentRetryingForDownload(
                    id: "42", mailbox: "INBOX", accountId: nil, accountName: "Google",
                    attachmentName: "x.pdf", savePath: "/tmp/x.pdf", policy: self.fastPolicy)
                XCTFail("a never-landing attachment must throw, not return")
            } catch let MailError.operationFailed(msg) {
                XCTAssertTrue(msg.contains("not downloaded") || msg.lowercased().contains("download"),
                              "timeout error must carry the not_downloaded guidance; got: \(msg)")
            }
        }
    }

    /// A SPECIFIC (non -10000) AppleScript error — bad account, permissions —
    /// is terminal: retrying cannot fix it, so it surfaces immediately instead
    /// of being masked as a download timeout.
    func testRetryLoop_propagatesSpecificErrorImmediately() async throws {
        let counter = SaveCounter()
        try await withSeam({ source in
            if source.contains("source of") { return "" }
            counter.saves += 1
            throw MailError.scriptFailed(message: "no such account", code: -1728)
        }) {
            do {
                _ = try await MailController.shared.saveAttachmentRetryingForDownload(
                    id: "42", mailbox: "INBOX", accountId: nil, accountName: "Google",
                    attachmentName: "x.pdf", savePath: "/tmp/x.pdf", policy: self.fastPolicy)
                XCTFail("a -1728 error must propagate, not be swallowed as a timeout")
            } catch let MailError.scriptFailed(_, code) {
                XCTAssertEqual(code, -1728, "the specific terminal error must surface unchanged")
                XCTAssertEqual(counter.saves, 1, "must NOT keep polling after a terminal error")
            }
        }
    }
}
