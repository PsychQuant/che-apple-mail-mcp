import XCTest
import Foundation
@testable import CheAppleMailMCP

/// Tests for `buildListDraftsScript` (#174) — per-account drafts resolution
/// via the unified `drafts mailbox`'s per-account child mailboxes.
///
/// Why this shape (empirically verified 2026-06-11, issue #174 plan):
/// - `drafts mailbox of (account id "...")` does NOT exist (-1728), so the
///   per-account special property is not an option.
/// - `every mailbox of drafts mailbox` returns one child per account, and
///   each child's `account` property resolves — `id of account of mb` is a
///   localization- and provider-independent match key (iCloud "Drafts" and
///   Gmail "草稿" both resolve through the same loop).
///
/// The pre-#174 implementation hardcoded `whose name is "Drafts"`, which can
/// never match a Gmail account's localized drafts mailbox (-1719).
final class ListDraftsScriptBuilderTests: XCTestCase {

    // MARK: - UUID mode

    func testUuidMode_matchesByAccountId() {
        let script = buildListDraftsScript(accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("every mailbox of drafts mailbox"),
                      "Must enumerate the unified drafts mailbox's per-account children")
        XCTAssertTrue(script.contains("(id of account of mb) is \"UUID-A\""),
                      "UUID mode must match children by account id; got:\n\(script)")
        XCTAssertFalse(script.contains("name of account of mb"),
                       "UUID mode must not fall back to account-name matching")
        XCTAssertFalse(script.contains("Google"),
                       "account_name must not leak into the UUID-mode script")
    }

    // MARK: - Name mode (legacy fallback)

    func testNameMode_matchesByAccountName() {
        let script = buildListDraftsScript(accountId: nil, accountName: "Google")
        XCTAssertTrue(script.contains("(name of account of mb) is \"Google\""),
                      "Name mode must match children by Mail's AppleScript account name; got:\n\(script)")
        XCTAssertFalse(script.contains("id of account of mb"),
                       "Name mode must not emit the UUID selector")
    }

    func testEmptyAccountId_treatedAsNameMode() {
        let script = buildListDraftsScript(accountId: "", accountName: "Google")
        XCTAssertTrue(script.contains("(name of account of mb) is \"Google\""),
                      "Empty accountId must behave like nil (name mode)")
    }

    // MARK: - No hardcoded special-mailbox name (#174 core regression lock)

    func testNoHardcodedDraftsLiteral() {
        for script in [
            buildListDraftsScript(accountId: "UUID-A", accountName: "Google"),
            buildListDraftsScript(accountId: nil, accountName: "Google"),
        ] {
            XCTAssertFalse(script.contains("whose name is \"Drafts\""),
                           "The hardcoded Drafts-by-name lookup must be gone; got:\n\(script)")
        }
    }

    // MARK: - Returns subjects + no-match error contract

    func testReturnsSubjectsOfMatchedMailbox() {
        let script = buildListDraftsScript(accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("return subject of messages of mb"),
                      "Matched child must return its messages' subjects; got:\n\(script)")
    }

    func testNoMatchRaisesRecognizableErrorNumber() {
        let script = buildListDraftsScript(accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("number 9174"),
                      "No-match must raise the recognizable custom error number 9174 "
                      + "so MailController can translate it into an actionable message; got:\n\(script)")
    }

    // MARK: - Per-child try guard (verify PR #181 finding 3)

    func testPerChildTryGuard_skipsAccountlessChildren() {
        // A unified-drafts child without a resolvable `account` property
        // (On My Mac / POP local storage) must not abort the whole loop —
        // the per-child access has to sit inside try ... end try.
        let script = buildListDraftsScript(accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("try"),
                      "Per-child account access must be try-guarded; got:\n\(script)")
        XCTAssertTrue(script.contains("end try"),
                      "try guard must be closed inside the repeat loop")
        let repeatIdx = script.range(of: "repeat with mb")!.lowerBound
        let tryIdx = script.range(of: "try")!.lowerBound
        XCTAssertTrue(tryIdx > repeatIdx,
                      "try guard must be inside the repeat loop, not around it")
    }

    // MARK: - Escaping

    func testEscapesQuotes_inBothModes() {
        let uuidMode = buildListDraftsScript(accountId: "uuid\"x", accountName: "a")
        XCTAssertTrue(uuidMode.contains("uuid\\\"x"),
                      "Quote in accountId must be escaped")
        let nameMode = buildListDraftsScript(accountId: nil, accountName: "has\"quote")
        XCTAssertTrue(nameMode.contains("has\\\"quote"),
                      "Quote in accountName must be escaped")
    }

    // MARK: - #185: listDraftsNoMatchHint (9174 → actionable operationFailed contract)

    /// The translation contract this issue exists to lock: a UUID-mode no-match
    /// hint must reference the offending account_id + point at `list_accounts`,
    /// and must NOT drift into the account_name-namespace advice (which would
    /// mislead a caller whose UUID is simply stale — verify PR #181 finding 18).
    func testListDraftsNoMatchHint_uuidMode_referencesAccountIdAndListAccounts() {
        let hint = listDraftsNoMatchHint(accountId: "ABCD-UUID", accountName: "Google")
        XCTAssertTrue(hint.contains("account_id \"ABCD-UUID\""),
                      "UUID-mode hint must name the offending account_id; got:\n\(hint)")
        XCTAssertTrue(hint.contains("list_accounts"),
                      "UUID-mode hint must point at list_accounts; got:\n\(hint)")
        XCTAssertFalse(hint.contains("account description"),
                      "UUID-mode hint must NOT emit the account_name-namespace advice; got:\n\(hint)")
    }

    /// Display-name mode (no account_id): the hint must name the account_name,
    /// explain the description-vs-email namespace mismatch, and advise passing
    /// account_id for reliable matching.
    func testListDraftsNoMatchHint_displayNameMode_explainsNamespaceAndAdvisesAccountId() {
        let hint = listDraftsNoMatchHint(accountId: nil, accountName: "me@example.com")
        XCTAssertTrue(hint.contains("account_name \"me@example.com\""),
                      "display-name hint must name the account_name; got:\n\(hint)")
        XCTAssertTrue(hint.contains("description"),
                      "display-name hint must explain the description-vs-email namespace; got:\n\(hint)")
        XCTAssertTrue(hint.contains("account_id"),
                      "display-name hint must advise passing account_id; got:\n\(hint)")
    }

    /// Edge: an explicit empty-string accountId is treated as "no account_id"
    /// (the `!aid.isEmpty` guard) → display-name mode, NOT a degenerate
    /// `account_id ""` hint.
    func testListDraftsNoMatchHint_emptyAccountId_fallsToDisplayName() {
        let hint = listDraftsNoMatchHint(accountId: "", accountName: "Work")
        XCTAssertTrue(hint.contains("account_name \"Work\""),
                      "empty accountId must fall to display-name mode; got:\n\(hint)")
        XCTAssertFalse(hint.contains("account_id \"\""),
                      "empty accountId must not produce an `account_id \"\"` hint; got:\n\(hint)")
    }

    // MARK: - #185: translateListDraftsScriptError (the 9174→operationFailed CODE-PATH contract)
    //
    // The hint-string tests above lock the *message*; these lock the *mapping* the issue
    // is titled after — the `code == 9174` guard, the `operationFailed` wrapping, and
    // non-9174 propagation — behaviorally, via the pure translation function (no actor
    // runner seam needed). Addresses verify-#195 devils-advocate: "the named contract is
    // NOT under test, only the hint STRING is."

    /// A `scriptFailed(_, 9174)` must translate to `operationFailed` carrying exactly the
    /// `listDraftsNoMatchHint` text — the actionable no-match contract.
    func testTranslateListDraftsScriptError_9174_becomesOperationFailedWithHint() {
        let translated = translateListDraftsScriptError(
            MailError.scriptFailed(message: "No drafts mailbox matched the requested account", code: listDraftsNoMatchErrorNumber),
            accountId: "ABCD-UUID", accountName: "Google")
        guard case let MailError.operationFailed(msg) = translated else {
            XCTFail("9174 must map to MailError.operationFailed; got \(translated)"); return
        }
        XCTAssertEqual(msg, listDraftsNoMatchHint(accountId: "ABCD-UUID", accountName: "Google"),
                       "operationFailed must carry exactly the listDraftsNoMatchHint text")
    }

    /// A `scriptFailed` with any OTHER code must propagate unchanged (the guard is
    /// selective — only 9174 is the recognized no-match contract).
    func testTranslateListDraftsScriptError_non9174ScriptFailed_propagatesUnchanged() {
        let original = MailError.scriptFailed(message: "boom", code: -1728)
        let translated = translateListDraftsScriptError(original, accountId: nil, accountName: "Work")
        guard case let MailError.scriptFailed(message, code) = translated else {
            XCTFail("non-9174 scriptFailed must propagate as scriptFailed; got \(translated)"); return
        }
        XCTAssertEqual(message, "boom")
        XCTAssertEqual(code, -1728, "non-9174 code must NOT be rewritten to operationFailed")
    }

    /// A non-`scriptFailed` error must propagate unchanged (translation only acts on the
    /// 9174 no-match case; everything else is the caller's to rethrow).
    func testTranslateListDraftsScriptError_nonScriptFailedError_propagatesUnchanged() {
        let original = MailError.operationFailed("unrelated")
        let translated = translateListDraftsScriptError(original, accountId: nil, accountName: "Work")
        guard case let MailError.operationFailed(msg) = translated else {
            XCTFail("non-scriptFailed must propagate unchanged; got \(translated)"); return
        }
        XCTAssertEqual(msg, "unrelated", "an unrelated operationFailed must pass through verbatim")
    }

    /// A `scriptCreationFailed` (NSAppleScript init nil — the other error
    /// `runScriptAsList` can throw) must also propagate unchanged through the
    /// translation (verify-#195 round-2 logic LOW: cover this distinct case
    /// explicitly, not just representatively).
    func testTranslateListDraftsScriptError_scriptCreationFailed_propagatesUnchanged() {
        let original = MailError.scriptCreationFailed
        let translated = translateListDraftsScriptError(original, accountId: "X", accountName: "Y")
        guard case MailError.scriptCreationFailed = translated else {
            XCTFail("scriptCreationFailed must propagate unchanged; got \(translated)"); return
        }
    }

    /// Structural wiring pin (mirrors the #139/#180 discipline), scoped to the
    /// `listDrafts` method body (verify-#195 round-2 devils-advocate LOW: a
    /// whole-file grep could stay green via a vestigial call elsewhere). The
    /// catch within `listDrafts` must route through `translateListDraftsScriptError`,
    /// and the `"No drafts mailbox found` literal must not appear anywhere in
    /// `MailController.swift` (the message lives only in `listDraftsNoMatchHint`).
    func testListDrafts_catchRoutesThroughTranslateFunction() throws {
        let mcSource = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CheAppleMailMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift"),
            encoding: .utf8)
        // Scope the positive assertion to the listDrafts method body: from its
        // `func listDrafts(` to the next top-level `\n    func ` (next method).
        guard let start = mcSource.range(of: "func listDrafts(") else {
            XCTFail("func listDrafts( not found in MailController.swift"); return
        }
        let afterStart = mcSource[start.upperBound...]
        let body = afterStart.range(of: "\n    func ").map { String(afterStart[..<$0.lowerBound]) }
            ?? String(afterStart)
        XCTAssertTrue(body.contains("translateListDraftsScriptError("),
                      "the listDrafts catch (not just somewhere in the file) must route "
                      + "through translateListDraftsScriptError(...) (#185)")
        XCTAssertFalse(mcSource.contains("\"No drafts mailbox found"),
                      "the no-match hint string must live only in listDraftsNoMatchHint, "
                      + "not inline in MailController.swift (#185)")
    }
}
