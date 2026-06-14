import XCTest
@testable import CheAppleMailMCP

/// Tests for `buildCheckForNewMailScript` / `buildSynchronizeAccountScript` (#191) —
/// the account_id-overload escape hatch for the mail-check / sync action tools, via
/// the shared `resolveAccountRef` selector (UUID when account_id present, else the
/// account-description name). Pure free functions, testable without the actor.
final class SyncCheckScriptBuilderTests: XCTestCase {

    // MARK: - check_for_new_mail: UUID mode (the #191 fix)

    func testCheckForNewMail_uuidMode_usesAccountIdSelector() {
        let script = buildCheckForNewMailScript(accountId: "UUID-A", accountName: "Google")
        XCTAssertTrue(script.contains("check for new mail for (account id \"UUID-A\")"),
                      "account_id must select via the collision-free UUID selector; got:\n\(script)")
        XCTAssertFalse(script.contains("account \"Google\""),
                       "UUID mode must NOT emit the bare description selector; got:\n\(script)")
    }

    /// account_id takes precedence even when account_name is also supplied
    /// (the `{account_id: UUID, account_name: email}` round-trip from list_accounts).
    func testCheckForNewMail_uuidMode_winsOverAccountName() {
        let script = buildCheckForNewMailScript(accountId: "UUID-A", accountName: "me@example.com")
        XCTAssertTrue(script.contains("(account id \"UUID-A\")"))
        XCTAssertFalse(script.contains("account \"me@example.com\""),
                       "an email-form account_name must not reach the selector when account_id is present")
    }

    // MARK: - check_for_new_mail: name mode + check-all (backward-compat byte-identity)

    func testCheckForNewMail_nameMode_byteIdenticalToPre191() {
        let script = buildCheckForNewMailScript(accountId: nil, accountName: "Google")
        XCTAssertEqual(script, """
        tell application "Mail"
            check for new mail for account "Google"
            return "Checking for new mail in Google"
        end tell
        """, "name-mode output must be byte-identical to the pre-#191 inline script")
    }

    func testCheckForNewMail_emptyAccountId_treatedAsNameMode() {
        let script = buildCheckForNewMailScript(accountId: "", accountName: "Google")
        XCTAssertTrue(script.contains("check for new mail for account \"Google\""),
                      "empty accountId must behave like nil (name mode)")
        XCTAssertFalse(script.contains("account id"))
    }

    func testCheckForNewMail_checkAll_byteIdenticalToPre191() {
        // No selector at all → the check-all form, unchanged from pre-#191.
        for script in [
            buildCheckForNewMailScript(accountId: nil, accountName: nil),
            buildCheckForNewMailScript(accountId: "", accountName: ""),
        ] {
            XCTAssertEqual(script, """
            tell application "Mail"
                check for new mail
                return "Checking for new mail in all accounts"
            end tell
            """, "check-all output must be byte-identical to the pre-#191 inline script")
        }
    }

    // MARK: - synchronize_account

    func testSynchronize_uuidMode_usesAccountIdSelector() {
        let script = buildSynchronizeAccountScript(accountId: "UUID-B", accountName: "Work")
        XCTAssertTrue(script.contains("synchronize (account id \"UUID-B\")"),
                      "account_id must select via the UUID selector; got:\n\(script)")
        XCTAssertFalse(script.contains("synchronize account \"Work\""),
                       "UUID mode must NOT emit the bare description selector")
    }

    /// #191 verify R1: UUID-only sync (no account_name) is fully supported — the builder
    /// emits the UUID selector and the return-message label falls back to the UUID. This
    /// is what makes account_id a genuine standalone escape hatch (schema dropped the
    /// account_name requirement; the handler enforces "at least one selector").
    func testSynchronize_uuidOnly_noAccountName_works() {
        let script = buildSynchronizeAccountScript(accountId: "UUID-B", accountName: "")
        XCTAssertTrue(script.contains("synchronize (account id \"UUID-B\")"),
                      "UUID-only sync must emit the UUID selector; got:\n\(script)")
        XCTAssertTrue(script.contains("Synchronizing account: UUID-B"),
                      "label must fall back to the UUID when no account_name is given")
    }

    func testSynchronize_nameMode_byteIdenticalToPre191() {
        let script = buildSynchronizeAccountScript(accountId: nil, accountName: "Google")
        XCTAssertEqual(script, """
        tell application "Mail"
            synchronize account "Google"
            return "Synchronizing account: Google"
        end tell
        """, "name-mode output must be byte-identical to the pre-#191 inline script")
    }

    // MARK: - Escaping (audit — injection via account selector)

    func testEscapesQuotes_inBothBuildersAndModes() {
        XCTAssertTrue(buildCheckForNewMailScript(accountId: "u\"x", accountName: "a").contains("u\\\"x"),
                      "quote in accountId must be escaped")
        XCTAssertTrue(buildCheckForNewMailScript(accountId: nil, accountName: "a\"b").contains("a\\\"b"),
                      "quote in accountName must be escaped (selector + label)")
        XCTAssertTrue(buildSynchronizeAccountScript(accountId: nil, accountName: "s\"q").contains("s\\\"q"),
                      "quote in synchronize accountName must be escaped")
    }

    // MARK: - Label helper (return-message account label)

    func testAccountLabel_prefersNameThenIdThenGeneric() {
        XCTAssertEqual(syncCheckAccountLabel(accountId: "U", accountName: "Google"), "Google",
                       "label prefers the account_name the caller supplied")
        XCTAssertEqual(syncCheckAccountLabel(accountId: "U", accountName: ""), "U",
                       "with no account_name, fall back to the UUID")
        XCTAssertEqual(syncCheckAccountLabel(accountId: nil, accountName: ""), "account",
                       "with neither, a generic label")
    }

    // MARK: - hasAccountSelector (the shared "is an account targeted?" decision, #191 verify R2)

    /// The pure helper behind both the builder's check-all gate and the handlers'
    /// selector guards — locks that `synchronize_account`'s "at least one selector"
    /// requirement (R2 finding 9: previously inline + untested) treats empty strings
    /// as absent and any non-empty selector as present.
    func testHasAccountSelector_emptyAndNilAreAbsent_anyNonEmptyIsPresent() {
        // Absent (→ synchronize_account guard throws; check_for_new_mail → check-all)
        XCTAssertFalse(hasAccountSelector(accountId: nil, accountName: nil))
        XCTAssertFalse(hasAccountSelector(accountId: "", accountName: ""))
        XCTAssertFalse(hasAccountSelector(accountId: "", accountName: nil))
        XCTAssertFalse(hasAccountSelector(accountId: nil, accountName: ""))
        // Present (either selector alone, or both)
        XCTAssertTrue(hasAccountSelector(accountId: "UUID", accountName: nil))
        XCTAssertTrue(hasAccountSelector(accountId: nil, accountName: "Google"))
        XCTAssertTrue(hasAccountSelector(accountId: "UUID", accountName: "Google"))
        XCTAssertTrue(hasAccountSelector(accountId: "UUID", accountName: ""),
                      "account_id alone is a valid selector (synchronize_account UUID-only escape hatch)")
    }
}
