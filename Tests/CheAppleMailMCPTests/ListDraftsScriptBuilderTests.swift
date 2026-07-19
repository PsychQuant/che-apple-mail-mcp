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

    // MARK: - #276 id+subject rows (draft-update spec: list_drafts returns draft ids)

    func testScript_returnsIdAndSubjectGroups() {
        // The script must emit BOTH id and subject lists from the same
        // invocation, RS-joined within each group (comma-safe — a subject
        // containing ", " must not shift the zip) and GS between groups.
        let script = buildListDraftsScript(accountId: "UUID-A", accountName: "Google")
        // #276 verify R2 (Codex blocking): ids and subjects must be read from
        // the SAME message reference per row — two dynamic collection queries
        // (`id of messages of mb` + `subject of messages of mb`) can mis-pair
        // when the mailbox mutates between them with UNCHANGED length (the
        // only shape that escapes the parser's mismatch guard) — and a
        // mis-paired row lets subject_match delete the wrong id.
        XCTAssertTrue(script.contains("repeat with dm in (every message of mb)"),
                      "rows must come from one reference snapshot, read per message; got:\n\(script)")
        XCTAssertTrue(script.contains("(id of dm) as string"),
                      "id must be read from the same reference as its subject; got:\n\(script)")
        XCTAssertTrue(script.contains("(subject of dm) as string"),
                      "subject must be read from the same reference as its id; got:\n\(script)")
        XCTAssertFalse(script.contains("id of messages of mb"),
                       "bulk parallel-list reads are the mis-pair vector — must be gone; got:\n\(script)")
        XCTAssertTrue(script.contains("ASCII character 30"),
                      "rows must be RS-joined (comma-safe); got:\n\(script)")
        XCTAssertTrue(script.contains("ASCII character 29"),
                      "id group and subject group must be GS-separated; got:\n\(script)")
        XCTAssertTrue(script.contains("number \(listDraftsNoMatchErrorNumber)"),
                      "the 9174 no-match contract must be preserved")
    }

    func testAllAccountsVariant_noConditionNoNoMatchError() {
        // update_draft's account-omitted path scans every drafts child.
        let script = buildListAllDraftsScript()
        XCTAssertTrue(script.contains("every mailbox of drafts mailbox"))
        XCTAssertFalse(script.contains("id of account of mb"))
        XCTAssertFalse(script.contains("name of account of mb"))
        XCTAssertFalse(script.contains("number \(listDraftsNoMatchErrorNumber)"),
                       "unified scan has no per-account no-match case")
        XCTAssertTrue(script.contains("repeat with dm in (every message of mb)"),
                      "all-accounts variant must use the same per-reference paired read")
        XCTAssertFalse(script.contains("id of messages of mb"))
        XCTAssertTrue(script.contains("ASCII character 29"))
    }

    func testAllAccountsVariant_failClosed_noTrySwallowing() {
        // #276 verify R1 (Codex blocking 1): in all-accounts mode EVERY child
        // participates in the uniqueness verdict — a swallowed row-build
        // error could hide a real cross-account ambiguity and let
        // update_draft delete the wrong "unique" match. Errors must
        // propagate (fail closed): the aggregate script contains NO try.
        let script = buildListAllDraftsScript()
        XCTAssertFalse(script.contains("try"),
                       "all-accounts scan must fail closed — no try swallowing; got:\n\(script)")
    }

    func testDeleteDraftScript_byIdInDraftsChildren() {
        // Deletion stays inside the unified-drafts children (no per-account
        // mailbox-name resolution needed); the predicate is id AND exact
        // subject (#276 verify R3, DA-1: an unscoped bare-id sweep bets on
        // GLOBAL id uniqueness — with the subject conjunct, a cross-account
        // id collision with a different subject is protected, and a
        // same-id-same-subject collision would already have refused as
        // ambiguous at locate time). #221-safe: id + subject equality, never
        // content.
        let script = buildDeleteDraftByIdScript(
            draftId: "12345", subject: "Re: a, b", accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("every mailbox of drafts mailbox"))
        XCTAssertTrue(script.contains("whose id is 12345 and subject is \"Re: a, b\""),
                      "delete predicate must conjoin id AND exact subject; got:\n\(script)")
        XCTAssertTrue(script.contains("(id of account of mb) is \"UUID-A\""))
        XCTAssertFalse(script.contains("whose content"), "#221: never a content predicate")
        // Unscoped variant: no account condition at all — the subject
        // conjunct is what carries the cross-account protection.
        let all = buildDeleteDraftByIdScript(
            draftId: "12345", subject: "S", accountId: nil, accountName: nil)
        XCTAssertFalse(all.contains("account of mb"))
        XCTAssertTrue(all.contains("and subject is \"S\""))
    }

    func testDeleteDraftScript_lookupSeparatedFromDelete() {
        // #276 verify R1 (Codex blocking 4): the lookup try must NOT wrap the
        // `delete` verb — a real delete failure (permissions, Mail command
        // error) must propagate to the controller (→ deleted_old:false with
        // the real cause), not be swallowed into the 9276 "not found" error.
        let script = buildDeleteDraftByIdScript(draftId: "12345", subject: "S", accountId: nil, accountName: nil)
        XCTAssertTrue(script.contains("set target to"),
                      "lookup must bind a target inside its own try; got:\n\(script)")
        XCTAssertTrue(script.contains("if target is not missing value then"),
                      "delete must run OUTSIDE the lookup try, gated on the bound target; got:\n\(script)")
        XCTAssertTrue(script.contains("delete target"),
                      "the delete verb must act on the bound target; got:\n\(script)")
        XCTAssertTrue(script.contains("number \(updateDraftDeleteNotFoundErrorNumber)"),
                      "exhausted lookup must still raise the recognizable 9276")
    }

    // MARK: - #276 parseDraftRows

    func testParseDraftRows_zipAndEdges() throws {
        let RS = "\u{001E}", GS = "\u{001D}"
        // Normal two rows — including a comma-containing subject.
        let rows = try parseDraftRows("101\(RS)102\(GS)Hello\(RS)Re: a, b, c")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, "101")
        XCTAssertEqual(rows[1].subject, "Re: a, b, c")
        // Zero drafts: both groups empty.
        XCTAssertEqual(try parseDraftRows("\(GS)").count, 0)
        // One draft with an EMPTY subject still pairs (regression: a naive
        // per-group emptiness shortcut would mis-count this as 1 vs 0).
        let one = try parseDraftRows("101\(GS)")
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].subject, "")
        // Length mismatch → throw (never silently truncate).
        XCTAssertThrowsError(try parseDraftRows("101\(RS)102\(GS)onlyone"))
        // Unexpected shape (no GS) → throw.
        XCTAssertThrowsError(try parseDraftRows("garbage-without-separator"))
        // #276 verify R1 (Codex blocking 3): a row whose id is empty or
        // non-ASCII-numeric violates the numeric-id contract and could flow
        // into the delete script — throw, never emit.
        XCTAssertThrowsError(try parseDraftRows("\(GS)Subject"),
                             "empty id with non-empty subject must throw, not yield id=\"\"")
        XCTAssertThrowsError(try parseDraftRows("12a\(GS)Subject"))
        XCTAssertThrowsError(try parseDraftRows("١٢٣\(GS)Subject"),
                             "non-ASCII Unicode digits are not a valid Mail rowid")
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
        // #276: the matched child now returns the GS-joined id+subject
        // payload (see testScript_returnsIdAndSubjectGroups) — subjects are
        // still fetched, just alongside ids instead of as the bare return.
        let script = buildListDraftsScript(accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("(subject of dm) as string"),
                      "Matched child must fetch its messages' subjects (per-reference, R2); got:\n\(script)")
        XCTAssertTrue(script.contains("return idStr & (ASCII character 29) & subjStr"),
                      "Matched child must return the delimited id+subject payload; got:\n\(script)")
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
