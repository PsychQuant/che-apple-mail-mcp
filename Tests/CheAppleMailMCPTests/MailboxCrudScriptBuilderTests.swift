import XCTest
@testable import CheAppleMailMCP

/// Tests for the 2 mailbox-CRUD script builders (#104 PR-D — final sweep increment).
///
/// `create_mailbox` and `delete_mailbox` use DIFFERENT ref shapes:
/// - `buildCreateMailboxScript` addresses an account directly (`make new
///   mailbox ... at <accountRef>`) — uses the new `resolveAccountRef`.
/// - `buildDeleteMailboxScript` references an existing mailbox (`delete
///   <mailboxRef>`) — uses the existing `resolveMailboxRef` chokepoint.
final class MailboxCrudScriptBuilderTests: XCTestCase {

    private let uuid = "C38E0583-47F8-4468-BE70-43155C15549D"

    // MARK: - create_mailbox (account-only ref)

    func testBuildCreateMailboxScript_uuidPath_usesAccountIdSelector() {
        let s = buildCreateMailboxScript(
            name: "Archive", accountId: uuid, accountName: "alice@example.com"
        )
        XCTAssertTrue(s.contains("(account id \"\(uuid)\")"),
                      "UUID path must address the account via (account id \"...\"); got:\n\(s)")
        XCTAssertFalse(s.contains("account \"alice@example.com\""),
                       "display_name must not leak in UUID path")
        XCTAssertTrue(s.contains("make new mailbox"), "must contain the create verb")
        XCTAssertTrue(s.contains("name:\"Archive\""), "new mailbox name must appear")
    }

    func testBuildCreateMailboxScript_displayNameFallback() {
        let s = buildCreateMailboxScript(
            name: "Archive", accountId: nil, accountName: "alice@example.com"
        )
        XCTAssertTrue(s.contains("at account \"alice@example.com\""),
                      "nil accountId must fall back to the legacy account \"<display_name>\" selector")
        XCTAssertFalse(s.contains("(account id"), "UUID form must not appear in fallback path")
        XCTAssertTrue(s.contains("make new mailbox"))
    }

    func testBuildCreateMailboxScript_emptyStringAccountId_fallsBackLikeNil() {
        let s = buildCreateMailboxScript(
            name: "Archive", accountId: "", accountName: "bob@example.com"
        )
        XCTAssertTrue(s.contains("at account \"bob@example.com\""))
        XCTAssertFalse(s.contains("(account id"))
    }

    func testBuildCreateMailboxScript_escapesMailboxNameQuotes() {
        let s = buildCreateMailboxScript(
            name: "My\"Box", accountId: nil, accountName: "bob@example.com"
        )
        XCTAssertTrue(s.contains("My\\\"Box"), "quote in mailbox name must be backslash-escaped")
    }

    // MARK: - delete_mailbox (existing-mailbox ref via resolveMailboxRef)

    func testBuildDeleteMailboxScript_uuidPath_usesAccountIdSelector() {
        let s = buildDeleteMailboxScript(
            name: "Old Folder", accountId: uuid, accountName: "alice@example.com"
        )
        XCTAssertTrue(s.contains("(account id \"\(uuid)\")"),
                      "UUID path must emit the (account id \"...\") selector; got:\n\(s)")
        XCTAssertFalse(s.contains("account \"alice@example.com\""),
                       "display_name must not leak in UUID path")
        XCTAssertTrue(s.contains("whose name is \"Old Folder\""),
                      "mailboxRef must reference the target mailbox by name")
        // Strong verb assertion: anchor on `delete (first mailbox` — NOT a bare
        // "delete" substring, since the return string "Deleted mailbox:" also
        // contains "delete" (the #128/DA-5 trap).
        XCTAssertTrue(s.contains("delete (first mailbox"), "must contain the delete verb")
    }

    func testBuildDeleteMailboxScript_displayNameFallback() {
        let s = buildDeleteMailboxScript(
            name: "Old Folder", accountId: nil, accountName: "alice@example.com"
        )
        XCTAssertTrue(s.contains("account \"alice@example.com\""),
                      "nil accountId must fall back to the display_name selector")
        XCTAssertFalse(s.contains("(account id"), "UUID form must not appear in fallback path")
        XCTAssertTrue(s.contains("delete (first mailbox"))
    }

    func testBuildDeleteMailboxScript_emptyStringAccountId_fallsBackLikeNil() {
        let s = buildDeleteMailboxScript(
            name: "Old Folder", accountId: "", accountName: "bob@example.com"
        )
        XCTAssertTrue(s.contains("account \"bob@example.com\""))
        XCTAssertFalse(s.contains("(account id"))
    }

    // MARK: - #139: actor-method wiring regression lock

    /// #139 — same pattern as #134 (resolveMsgRef wiring lock for reply/forward).
    ///
    /// `MailController.createMailbox` / `deleteMailbox` are 2-line actor wrappers
    /// around `buildCreateMailboxScript` / `buildDeleteMailboxScript`. The
    /// builders ARE the testable seam — they take `(name:accountId:accountName:)`
    /// directly and the 11 PR-D tests cover both their UUID and display_name paths.
    /// BUT the actor method's call site itself ("does createMailbox actually
    /// call buildCreateMailboxScript with the right params?") has no
    /// integration-free unit-test coverage.
    ///
    /// The realistic regression scenario this guards against: a future edit
    /// inlines the AppleScript back into the actor (e.g. `let script = "tell
    /// application \"Mail\" ..."`) and drops the builder call. Build still
    /// succeeds, `swift test` stays green (the builder tests test the
    /// FUNCTION, not the actor's USE of it), but the #104 account_id
    /// disambiguation is silently dead.
    ///
    /// This structural test reads `MailController.swift` and asserts the
    /// canonical call form is present. Brittle to renaming/restructuring —
    /// when the wiring intentionally changes shape, this test should be
    /// updated to reflect the new contract.
    func testMailControllerCreateMailbox_callsBuilderNotInline() throws {
        let source = try readMailControllerSource()
        let createBody = try extractFunctionBody(source: source, signature: "func createMailbox(name: String,")
        XCTAssertTrue(createBody.contains("buildCreateMailboxScript(name:"),
                      "MailController.createMailbox MUST delegate to buildCreateMailboxScript — reverting to an inline AppleScript would silently lose #104 account_id disambiguation. Body:\n\(createBody)")
        XCTAssertFalse(createBody.contains("tell application \"Mail\""),
                       "MailController.createMailbox MUST NOT contain inline `tell application` — script construction belongs in buildCreateMailboxScript. Body:\n\(createBody)")
    }

    func testMailControllerDeleteMailbox_callsBuilderNotInline() throws {
        let source = try readMailControllerSource()
        let deleteBody = try extractFunctionBody(source: source, signature: "func deleteMailbox(name: String,")
        XCTAssertTrue(deleteBody.contains("buildDeleteMailboxScript(name:"),
                      "MailController.deleteMailbox MUST delegate to buildDeleteMailboxScript. Body:\n\(deleteBody)")
        XCTAssertFalse(deleteBody.contains("tell application \"Mail\""),
                       "MailController.deleteMailbox MUST NOT contain inline `tell application`. Body:\n\(deleteBody)")
    }

    // MARK: - Test helpers (structural source-code introspection)

    /// Read the live `MailController.swift` source so the wiring tests above
    /// reflect the current commit. Uses `#filePath` of this test file to
    /// derive the source path (test runs under SPM build dir, source lives
    /// adjacent).
    private func readMailControllerSource(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let testFile = URL(fileURLWithPath: "\(file)")
        // Tests/CheAppleMailMCPTests/MailboxCrudScriptBuilderTests.swift
        // → Sources/CheAppleMailMCP/AppleScript/MailController.swift
        let pkgRoot = testFile
            .deletingLastPathComponent()  // CheAppleMailMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let sourcePath = pkgRoot
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift")
        return try String(contentsOf: sourcePath, encoding: .utf8)
    }

    /// Extract a function body — the text between the opening `{` after
    /// `signature` and its matching closing `}`. Brace-balanced; tolerates
    /// nested blocks.
    private func extractFunctionBody(source: String, signature: String) throws -> String {
        guard let sigStart = source.range(of: signature) else {
            throw NSError(domain: "MailboxCrudWiringTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "signature not found: \(signature)"])
        }
        guard let openBrace = source.range(of: "{", range: sigStart.upperBound..<source.endIndex) else {
            throw NSError(domain: "MailboxCrudWiringTest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "open brace not found after \(signature)"])
        }
        var depth = 1
        var idx = openBrace.upperBound
        while idx < source.endIndex && depth > 0 {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1 }
            idx = source.index(after: idx)
        }
        return String(source[openBrace.upperBound..<idx])
    }
}
