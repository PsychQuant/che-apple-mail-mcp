import XCTest
import Foundation
@testable import CheAppleMailMCP

/// Tests for `buildSpecialMailboxNamesScript` + `resolveSpecialMailboxesResult` (#179)
/// — per-account special-mailbox real-name resolution via the #174 unified-children
/// reverse-lookup, generalized across drafts/sent/trash/junk (inbox deferred,
/// outbox excluded).
final class SpecialMailboxesScriptBuilderTests: XCTestCase {

    // inbox deferred (#179 verify): only the four `<X> mailbox` special mailboxes ship.
    private let perAccountContainers = ["drafts mailbox", "sent mailbox", "trash mailbox", "junk mailbox"]

    // MARK: - Builder: UUID mode

    func testUuidMode_findsAccountAndChildrenByAccountId() {
        let script = buildSpecialMailboxNamesScript(accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("repeat with acc in accounts"),
                      "must locate the account directly (for canonical metadata + existence)")
        XCTAssertTrue(script.contains("(id of acc) is \"UUID-A\""),
                      "UUID mode must find the account by id; got:\n\(script)")
        for container in perAccountContainers {
            XCTAssertTrue(script.contains("every mailbox of \(container)"),
                          "must enumerate per-account children of `\(container)`; got:\n\(script)")
        }
        XCTAssertTrue(script.contains("(id of account of mb) is \"UUID-A\""),
                      "UUID mode must match children by account id")
        XCTAssertFalse(script.contains("(name of acc) is") || script.contains("name of account of mb"),
                       "UUID mode must not use name matching")
        XCTAssertFalse(script.contains("Google"),
                       "account_name must not leak into the UUID-mode script")
    }

    /// D4: outbox excluded (transient send queue); inbox deferred (unverified
    /// per-account semantics, #179 verify) — neither container is enumerated.
    func testOutboxAndInboxExcludedFromPerAccountResolution() {
        let script = buildSpecialMailboxNamesScript(accountId: "UUID-A", accountName: "Google")
        XCTAssertFalse(script.contains("outbox"),
                       "outbox must NOT be resolved per-account (#179 D4); got:\n\(script)")
        XCTAssertFalse(script.contains("every mailbox of inbox"),
                       "inbox per-account resolution is deferred pending the live D4 check; got:\n\(script)")
    }

    // MARK: - Builder: name mode (legacy fallback)

    func testNameMode_findsAccountAndChildrenByAccountName() {
        let script = buildSpecialMailboxNamesScript(accountId: nil, accountName: "Google")
        XCTAssertTrue(script.contains("(name of acc) is \"Google\""),
                      "name mode must find the account by name; got:\n\(script)")
        XCTAssertTrue(script.contains("(name of account of mb) is \"Google\""),
                      "name mode must match children by account name")
        // The *match conditions* must not use id; but `id of acc` still appears in
        // the metadata capture (`set matchedId to (id of acc as string)`) so name
        // mode still returns the canonical UUID — that's intended, not a leak.
        XCTAssertFalse(script.contains("(id of acc) is"),
                       "name mode must not MATCH the account by id")
        XCTAssertFalse(script.contains("(id of account of mb) is"),
                       "name mode must not MATCH children by id")
        XCTAssertTrue(script.contains("set matchedId to (id of acc as string)"),
                      "name mode must still capture the canonical account id for metadata")
    }

    func testEmptyAccountId_treatedAsNameMode() {
        let script = buildSpecialMailboxNamesScript(accountId: "", accountName: "Google")
        XCTAssertTrue(script.contains("(name of acc) is \"Google\""),
                      "empty accountId must behave like nil (name mode)")
    }

    // MARK: - Builder: returns canonical metadata + match count + names

    func testReturnsMatchedMetadataCountAndNames() {
        let script = buildSpecialMailboxNamesScript(accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("return {matchedId, matchedName, (matchCount as string)"),
                      "must return canonical matched id/name + match count first; got:\n\(script)")
        XCTAssertTrue(script.contains("set matchCount to matchCount + 1"),
                      "must count selector matches (for ambiguity detection)")
        XCTAssertTrue(script.contains("name of mb"),
                      "must read the matched child's name")
    }

    /// #179 verify R4/R5 (findings 11 + 9): the child name must be guarded against
    /// `missing value` AND coerced to text. A bare `set nX to name of mb` could store
    /// an AppleScript `missing value` (a transiently nameless mailbox) which
    /// runScriptAsList drops (nil stringValue) → positional shift → silent name
    /// misattribution in the fixed tuple. But a naive `(name of mb as string)` instead
    /// leaks the LITERAL text "missing value" as the mailbox name (R5 finding 9). The
    /// guard `is not missing value` before the coercion gives the only correct outcome:
    /// real name → coerced text; nameless → slot stays "" → omitted key (D3).
    func testChildNameGuardedAgainstMissingValueAndCoerced_protectsFixedTuple() {
        let script = buildSpecialMailboxNamesScript(accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("is not missing value"),
                      "child name must be guarded against `missing value` before use; got:\n\(script)")
        XCTAssertTrue(script.contains("(mbName as string)"),
                      "a present child name must be coerced to text so the slot is never dropped; got:\n\(script)")
        XCTAssertFalse(script.contains("(name of mb as string)"),
                       "the R4-only unguarded coercion (leaks literal \"missing value\") must be gone; got:\n\(script)")
    }

    // MARK: - Builder: try guards (per-container AND per-child)

    func testContainerAndPerChildTryGuards() {
        let script = buildSpecialMailboxNamesScript(accountId: "UUID-A", accountName: "Google")
        // An absent unified container or an account-less child must be non-fatal (D3):
        // each container's repeat is itself try-wrapped, plus the per-child try.
        XCTAssertGreaterThanOrEqual(script.components(separatedBy: "try").count - 1, perAccountContainers.count * 2,
                      "each container needs a container-level try AND a per-child try; got:\n\(script)")
    }

    // MARK: - Builder: escaping (audit — injection via account selector)

    func testEscapesQuotes_inBothModes() {
        let uuidMode = buildSpecialMailboxNamesScript(accountId: "uuid\"x", accountName: "a")
        XCTAssertTrue(uuidMode.contains("uuid\\\"x"), "quote in accountId must be escaped")
        let nameMode = buildSpecialMailboxNamesScript(accountId: nil, accountName: "has\"quote")
        XCTAssertTrue(nameMode.contains("has\\\"quote"), "quote in accountName must be escaped")
    }

    /// #179 verify R5 (finding 6): a backslash in the selector must also be escaped, or
    /// a crafted `...\"` could still break out of the AppleScript string literal even
    /// though the quote is escaped. Locks that the shared appleScriptEscape (which the
    /// builder relies on) doubles backslashes for this injection-sensitive call site.
    func testEscapesBackslash_inBothModes() {
        let uuidMode = buildSpecialMailboxNamesScript(accountId: "back\\slash", accountName: "a")
        XCTAssertTrue(uuidMode.contains("back\\\\slash"), "backslash in accountId must be doubled")
        let nameMode = buildSpecialMailboxNamesScript(accountId: nil, accountName: "back\\slash")
        XCTAssertTrue(nameMode.contains("back\\\\slash"), "backslash in accountName must be doubled")
    }

    // MARK: - Parser: resolveSpecialMailboxesResult (the runtime contract)
    // raw = [matchedId, matchedName, matchCount, drafts, sent, trash, junk]  (inbox deferred)

    /// Canonical metadata + all four names present.
    func testParse_resolved_canonicalMetadataAndAllNames() {
        let raw = ["UUID-G", "Google", "1", "草稿", "已寄出", "垃圾桶", "垃圾郵件"]
        XCTAssertEqual(resolveSpecialMailboxesResult(raw), .resolved([
            "account_id": "UUID-G", "account_name": "Google",
            "drafts": "草稿", "sent": "已寄出", "trash": "垃圾桶", "junk": "垃圾郵件",
        ]))
    }

    /// account_id / account_name come from the matched account (raw[0]/raw[1]),
    /// NOT echoed caller input — even when matched via an email-form selector
    /// (the script returns the account's description, not the email). (HIGH-1)
    func testParse_metadataIsCanonical_notRawSelector() {
        let raw = ["UUID-G", "Google", "1", "草稿", "", "", ""]
        guard case let .resolved(obj) = resolveSpecialMailboxesResult(raw) else {
            XCTFail("expected resolved"); return
        }
        XCTAssertEqual(obj["account_id"], "UUID-G")
        XCTAssertEqual(obj["account_name"], "Google")  // canonical description, not an email
    }

    /// A special type absent for the account is omitted (not null, not error). (D3)
    func testParse_resolved_omitsAbsentType() {
        let raw = ["UUID-P", "Work", "1", "Drafts", "Sent", "Trash", ""]
        guard case let .resolved(obj) = resolveSpecialMailboxesResult(raw) else {
            XCTFail("expected resolved"); return
        }
        XCTAssertNil(obj["junk"], "absent junk must be omitted")
        XCTAssertEqual(obj["trash"], "Trash")
    }

    /// Account EXISTS but has no special children at all → still resolved (metadata
    /// only), NOT no-match. This is the HIGH-2 boundary the old anyFound test failed.
    func testParse_accountExistsButNoSpecialChildren_isResolvedNotNoMatch() {
        let raw = ["UUID-X", "Bare", "1", "", "", "", ""]
        XCTAssertEqual(resolveSpecialMailboxesResult(raw),
                       .resolved(["account_id": "UUID-X", "account_name": "Bare"]),
                       "an existing account with no special children must resolve to metadata-only, not no-match")
    }

    /// Selector matched no account at all → noMatch (→ caller throws actionable hint).
    func testParse_noAccountMatched_isNoMatch() {
        XCTAssertEqual(resolveSpecialMailboxesResult(["", "", "0", "", "", "", ""]), .noMatch)
    }

    /// A colliding description name matching multiple accounts → ambiguous. (MEDIUM-5)
    func testParse_multipleAccountsMatched_isAmbiguous() {
        XCTAssertEqual(resolveSpecialMailboxesResult(["UUID-1", "Work", "2", "", "", "", ""]),
                       .ambiguous(2))
    }

    /// Malformed / short result is treated as no-match, not a crash.
    func testParse_shortResult_isNoMatch() {
        XCTAssertEqual(resolveSpecialMailboxesResult([]), .noMatch)
        XCTAssertEqual(resolveSpecialMailboxesResult(["", ""]), .noMatch)
    }

    // MARK: - Throw translation (#179 verify R2: the code-path mapping, #185 discipline)

    /// `.resolved` returns the dict unchanged.
    func testResultOrThrow_resolved_returnsDict() throws {
        let obj = try specialMailboxesResultOrThrow(
            .resolved(["account_id": "U", "account_name": "Work", "drafts": "Drafts"]),
            accountId: "U", accountName: "Work")
        XCTAssertEqual(obj["account_id"], "U")
        XCTAssertEqual(obj["drafts"], "Drafts")
    }

    /// `.noMatch` throws `operationFailed` carrying exactly the no-match hint.
    func testResultOrThrow_noMatch_throwsOperationFailedWithHint() {
        XCTAssertThrowsError(try specialMailboxesResultOrThrow(.noMatch, accountId: "U-X", accountName: "Work")) { error in
            guard case let MailError.operationFailed(msg) = error else {
                XCTFail("expected operationFailed; got \(error)"); return
            }
            XCTAssertEqual(msg, specialMailboxesNoMatchHint(accountId: "U-X", accountName: "Work"))
        }
    }

    /// `.ambiguous` throws `invalidParameter` naming the count + advising account_id.
    func testResultOrThrow_ambiguous_throwsInvalidParameterWithCount() {
        XCTAssertThrowsError(try specialMailboxesResultOrThrow(.ambiguous(3), accountId: nil, accountName: "Work")) { error in
            guard case let MailError.invalidParameter(msg) = error else {
                XCTFail("expected invalidParameter; got \(error)"); return
            }
            XCTAssertTrue(msg.contains("3") && msg.contains("account_id"),
                          "ambiguity error must name the count + advise account_id; got: \(msg)")
        }
    }

    // MARK: - No-match hint content (#179 verify R2: same lock #185 applies to list_drafts)

    /// Pure UUID case = caller supplied account_id and NO account_name (else
    /// account_name takes precedence, since the handler may have laundered an email
    /// into the UUID — verify R3 DA fix).
    func testNoMatchHint_uuidMode_referencesAccountIdAndListAccounts() {
        let hint = specialMailboxesNoMatchHint(accountId: "ABCD-UUID", accountName: "")
        XCTAssertTrue(hint.contains("account_id \"ABCD-UUID\"") && hint.contains("list_accounts"))
        XCTAssertFalse(hint.contains("account description"), "UUID-mode hint must not emit the namespace advice")
    }

    /// The laundered-email case (verify R3 DA): even though the handler resolved the
    /// email to a UUID (passed as accountId), a non-empty account_name means the hint
    /// references the EMAIL the user typed + the namespace advice — never the UUID.
    func testNoMatchHint_emailResolvedToUuid_referencesEmailNotUuid() {
        let hint = specialMailboxesNoMatchHint(accountId: "UUID-STALE", accountName: "me@example.com")
        XCTAssertTrue(hint.contains("account_name \"me@example.com\""),
                      "must reference the email the caller supplied; got: \(hint)")
        XCTAssertFalse(hint.contains("UUID-STALE"),
                       "must NOT reference a UUID the caller never typed; got: \(hint)")
    }

    func testNoMatchHint_displayNameMode_explainsNamespaceAndAdvisesAccountId() {
        let hint = specialMailboxesNoMatchHint(accountId: nil, accountName: "me@example.com")
        XCTAssertTrue(hint.contains("account_name \"me@example.com\""))
        XCTAssertTrue(hint.contains("description") && hint.contains("account_id"))
    }

    func testNoMatchHint_emptyAccountId_fallsToDisplayName() {
        let hint = specialMailboxesNoMatchHint(accountId: "", accountName: "Work")
        XCTAssertTrue(hint.contains("account_name \"Work\""))
        XCTAssertFalse(hint.contains("account_id \"\""))
    }

    // MARK: - Hint selector (#179 verify R4, findings 2/5: name the selector matched on)

    /// Explicit account_id supplied → the builder matched the UUID, so the hint must
    /// reference the account_id, NOT a co-supplied account_name (which may well exist).
    /// `specialMailboxesHintAccountName` returns "" so the downstream hint takes the
    /// account_id branch. This is the `{account_id: BAD, account_name: Google}` trap.
    func testHintAccountName_explicitAccountId_suppressesAccountName() {
        XCTAssertEqual(specialMailboxesHintAccountName(explicitAccountId: true, accountName: "Google"), "")
        // …so the no-match hint blames the account_id, not the (possibly valid) name:
        let hint = specialMailboxesNoMatchHint(
            accountId: "BAD-UUID",
            accountName: specialMailboxesHintAccountName(explicitAccountId: true, accountName: "Google"))
        XCTAssertTrue(hint.contains("account_id \"BAD-UUID\""),
                      "explicit-account_id no-match must blame the UUID; got: \(hint)")
        XCTAssertFalse(hint.contains("Google"),
                       "must NOT blame a co-supplied account_name that was never matched; got: \(hint)")
    }

    /// No explicit account_id (email-form account_name laundered to a UUID, or a plain
    /// description) → reference the account_name the user actually typed. Preserves the
    /// verify-R3 email→UUID non-laundering fix.
    func testHintAccountName_noExplicitAccountId_keepsAccountName() {
        XCTAssertEqual(specialMailboxesHintAccountName(explicitAccountId: false, accountName: "me@example.com"),
                       "me@example.com")
        XCTAssertEqual(specialMailboxesHintAccountName(explicitAccountId: false, accountName: nil), "")
    }

    // MARK: - runScriptAsList wire-format guard (#179 verify R5/R6, finding 2 → R6 HIGH)

    /// The per-account result is a FIXED positional tuple
    /// `[matchedId, matchedName, matchCount, drafts, sent, trash, junk]`;
    /// `resolveSpecialMailboxesResult` maps slots → keys BY POSITION. That is only safe
    /// if `runScriptAsList` PRESERVES empty-string slots — if an empty "" were dropped,
    /// every later name would shift left and be silently misattributed (an empty `drafts`
    /// slot would make `sent`'s name parse as drafts). This locks that load-bearing
    /// wire-format assumption against a future `runScriptAsList` refactor.
    ///
    /// It executes a PURE AppleScript list literal (no Mail.app / account / FDA) so it
    /// lives in the DEFAULT (non-gated) suite — a regression that drops empty slots must
    /// fail `swift test --skip MailAppIntegrationTests`, not hide in a gated test (R6
    /// HIGH: a guard that never runs is not a guard). If a future *runtime* refactor of
    /// runScriptAsList makes the empty-list script itself throw (vs. returning the wrong
    /// shape), this surfaces as a failure here too — which is still the signal we want.
    func test_runScriptAsList_preservesEmptyStringPositions() async throws {
        let result = try await MailController.shared.runScriptAsList(#"{"a", "", "b", ""}"#)
        XCTAssertEqual(result, ["a", "", "b", ""],
                       "runScriptAsList must preserve empty-string slots so the #179 fixed tuple never shifts left")
    }
}
