import XCTest
import Foundation
import MCP
@testable import CheAppleMailMCP

final class ServerSchemaTests: XCTestCase {

    private func tool(named name: String) -> Tool? {
        CheAppleMailMCPServer.defineTools().first { $0.name == name }
    }

    private func propertiesObject(of tool: Tool) -> [String: Value]? {
        guard case .object(let schema) = tool.inputSchema,
              let propsValue = schema["properties"],
              case .object(let props) = propsValue else { return nil }
        return props
    }

    private func requiredArray(of tool: Tool) -> [String]? {
        guard case .object(let schema) = tool.inputSchema,
              let requiredValue = schema["required"],
              case .array(let arr) = requiredValue else { return nil }
        return arr.compactMap { value in
            if case .string(let s) = value { return s }
            return nil
        }
    }

    private func enumValues(on property: Value) -> [String]? {
        guard case .object(let propObj) = property,
              let enumValue = propObj["enum"],
              case .array(let arr) = enumValue else { return nil }
        return arr.compactMap { value in
            if case .string(let s) = value { return s }
            return nil
        }
    }

    private func assertFormatParameter(toolName: String) {
        guard let t = tool(named: toolName) else {
            XCTFail("Tool \(toolName) not found")
            return
        }

        guard let props = propertiesObject(of: t) else {
            XCTFail("Tool \(toolName) missing properties object")
            return
        }
        guard let formatProp = props["format"] else {
            XCTFail("Tool \(toolName) missing 'format' property")
            return
        }

        XCTAssertEqual(
            enumValues(on: formatProp),
            ["plain", "markdown", "html"],
            "Tool \(toolName) format enum must be exactly [plain, markdown, html]"
        )

        let required = requiredArray(of: t) ?? []
        XCTAssertFalse(
            required.contains("format"),
            "Tool \(toolName) must NOT mark format as required"
        )
    }

    func testComposeEmail_advertisesFormatEnum() {
        assertFormatParameter(toolName: "compose_email")
    }

    func testCreateDraft_advertisesFormatEnum() {
        assertFormatParameter(toolName: "create_draft")
    }

    func testCreateDraft_advertisesCcBccParameters() {
        // #107: create_draft gained optional cc / bcc — both must appear in
        // the schema's properties, and neither may be in `required`.
        guard let t = tool(named: "create_draft"),
              let props = propertiesObject(of: t) else {
            XCTFail("create_draft schema missing")
            return
        }
        XCTAssertNotNil(props["cc"], "create_draft must advertise a cc property")
        XCTAssertNotNil(props["bcc"], "create_draft must advertise a bcc property")
        let required = requiredArray(of: t) ?? []
        XCTAssertFalse(required.contains("cc"), "cc must stay optional")
        XCTAssertFalse(required.contains("bcc"), "bcc must stay optional")
    }

    func testReplyEmail_advertisesFormatEnum() {
        assertFormatParameter(toolName: "reply_email")
    }

    func testForwardEmail_advertisesFormatEnum() {
        assertFormatParameter(toolName: "forward_email")
    }

    // MARK: - reply_email new optional params (issue #33)

    func testReplyEmail_advertisesCcAdditionalAttachmentsAndSaveAsDraft() throws {
        guard let tool = tool(named: "reply_email"),
              let props = propertiesObject(of: tool),
              let required = requiredArray(of: tool) else {
            XCTFail("reply_email schema missing or malformed")
            return
        }

        XCTAssertNotNil(props["cc_additional"], "reply_email schema MUST advertise `cc_additional`")
        XCTAssertNotNil(props["attachments"], "reply_email schema MUST advertise `attachments`")
        XCTAssertNotNil(props["save_as_draft"], "reply_email schema MUST advertise `save_as_draft`")

        // Required list must NOT change (backward compat).
        XCTAssertEqual(
            Set(required),
            Set(["id", "mailbox", "account_name", "body"]),
            "reply_email required params MUST stay {id, mailbox, account_name, body}; new params are optional"
        )
    }

    // MARK: - parseBodyFormat (handler dispatch behavior)

    func testParseBodyFormat_nilReturnsPlain() throws {
        XCTAssertEqual(try parseBodyFormat(nil), .plain)
    }

    func testParseBodyFormat_emptyReturnsPlain() throws {
        XCTAssertEqual(try parseBodyFormat(""), .plain)
    }

    func testParseBodyFormat_validValues() throws {
        XCTAssertEqual(try parseBodyFormat("plain"), .plain)
        XCTAssertEqual(try parseBodyFormat("markdown"), .markdown)
        XCTAssertEqual(try parseBodyFormat("html"), .html)
    }

    func testParseBodyFormat_invalidValueThrows() {
        XCTAssertThrowsError(try parseBodyFormat("rtf")) { error in
            guard let mailErr = error as? MailError,
                  case .invalidParameter(let msg) = mailErr else {
                XCTFail("Expected MailError.invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("plain"), "error message must list valid values")
            XCTAssertTrue(msg.contains("markdown"))
            XCTAssertTrue(msg.contains("html"))
            XCTAssertTrue(msg.contains("rtf"), "error message must include the offending value")
        }
    }

    // MARK: - requireMessageId (#50 — id injection hardening)

    private func assertInvalidMessageId(_ arguments: [String: Value],
                                        expectedFragment: String,
                                        file: StaticString = #file, line: UInt = #line) {
        XCTAssertThrowsError(try requireMessageId(arguments), file: file, line: line) { error in
            guard let mailErr = error as? MailError,
                  case .invalidParameter(let msg) = mailErr else {
                XCTFail("Expected MailError.invalidParameter, got \(error)", file: file, line: line)
                return
            }
            XCTAssertTrue(msg.contains(expectedFragment),
                          "error '\(msg)' must contain '\(expectedFragment)'",
                          file: file, line: line)
        }
    }

    func testRequireMessageId_acceptsValidNumericString() throws {
        XCTAssertEqual(try requireMessageId(["id": .string("123")]), "123")
        XCTAssertEqual(try requireMessageId(["id": .string("0")]), "0")
        // Mail.app message IDs are Int64-range; verify large values pass.
        XCTAssertEqual(try requireMessageId(["id": .string("9223372036854775807")]),
                       "9223372036854775807")  // Int64.max
    }

    func testRequireMessageId_missingKeyThrows() {
        assertInvalidMessageId([:], expectedFragment: "required")
    }

    func testRequireMessageId_emptyStringThrows() {
        assertInvalidMessageId(["id": .string("")], expectedFragment: "non-empty")
    }

    func testRequireMessageId_nonNumericStringThrows() {
        assertInvalidMessageId(["id": .string("abc")], expectedFragment: "abc")
        assertInvalidMessageId(["id": .string("12abc")], expectedFragment: "12abc")
        assertInvalidMessageId(["id": .string("12.5")], expectedFragment: "12.5")
    }

    func testRequireMessageId_injectionAttemptThrows() {
        // Issue #50 attack vector: AppleScript predicate-injection via crafted id.
        // Without validation, this would interpolate as
        //   `whose id is 123 whose subject is "x" or true or whose name is`
        // and `or true` short-circuits returning the wrong message.
        assertInvalidMessageId(
            ["id": .string("123 whose subject is \"x\" or true")],
            expectedFragment: "whose subject"
        )
    }

    func testRequireMessageId_whitespaceTrimmedRejected() {
        // Strict: leading/trailing whitespace not accepted (Int("123 ") returns nil
        // because Swift's Int initializer doesn't trim).
        assertInvalidMessageId(["id": .string("123 ")], expectedFragment: "123 ")
        assertInvalidMessageId(["id": .string(" 123")], expectedFragment: " 123")
    }

    func testRequireMessageId_nonStringTypeThrows() {
        // arguments["id"] returns nil for missing key; non-string Value types
        // also return nil from .stringValue accessor → same path as missing.
        assertInvalidMessageId(["id": .int(123)], expectedFragment: "required")
        assertInvalidMessageId(["id": .bool(true)], expectedFragment: "required")
        assertInvalidMessageId(["id": .null], expectedFragment: "required")
    }

    // MARK: - decodeAccountId (#111 — non-string account_id silent-degrade)

    func testDecodeAccountId_stringValueReturned() {
        XCTAssertEqual(
            decodeAccountId(["account_id": .string("UUID-A")], tool: "save_attachment"),
            "UUID-A")
    }

    func testDecodeAccountId_absentKeyReturnsNil() {
        // No account_id supplied — legitimate "use the legacy path", no warning.
        XCTAssertNil(decodeAccountId([:], tool: "save_attachment"))
    }

    func testDecodeAccountId_explicitNullReturnsNil() {
        // JSON null is an explicit "no account_id" — nil, no warning.
        XCTAssertNil(decodeAccountId(["account_id": .null], tool: "save_attachment"))
    }

    func testDecodeAccountId_nonStringTypesReturnNil() {
        // Present-but-non-string: the #111 silent-degrade trap. decodeAccountId
        // returns nil (falls back to account_name) AND emits a stderr warning —
        // the return contract is pinned here; the warning is a stderr side effect.
        XCTAssertNil(decodeAccountId(["account_id": .int(12345)], tool: "save_attachment"))
        XCTAssertNil(decodeAccountId(["account_id": .bool(true)], tool: "mark_read"))
        XCTAssertNil(decodeAccountId(["account_id": .double(3.14)], tool: "move_email"))
        XCTAssertNil(decodeAccountId(["account_id": .array([.string("x")])], tool: "delete_email"))
    }

    func testDecodeAccountId_emptyStringReturnedVerbatim() {
        // Empty string is still a string — returned as-is; resolveMsgRef /
        // resolveMailboxRef treat "" the same as nil downstream (the !isEmpty guard).
        XCTAssertEqual(decodeAccountId(["account_id": .string("")], tool: "save_attachment"), "")
    }

    /// Capture everything written to stderr (fd 2) while `body` runs. The #111
    /// fix's whole purpose is a *side effect* (the `WARN:` line) — a
    /// return-value-only assertion cannot tell the fix from its absence, so the
    /// two tests below redirect fd 2 through a pipe to pin the warning itself.
    private func captureStderr(_ body: () -> Void) -> String {
        let pipe = Pipe()
        let savedFD = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        body()
        dup2(savedFD, STDERR_FILENO)
        close(savedFD)
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    func testDecodeAccountId_nonStringEmitsStderrWarning() {
        // A present-but-non-string account_id MUST produce an actionable stderr
        // warning — not degrade silently (the #111 defect). Pins the write
        // against a future edit that drops it or blanks the message.
        let captured = captureStderr {
            _ = decodeAccountId(["account_id": .int(12345)], tool: "save_attachment")
        }
        XCTAssertTrue(captured.contains("WARN:"), "expected a WARN line, got: \(captured)")
        XCTAssertTrue(captured.contains("save_attachment"), "warning must name the offending tool")
        XCTAssertTrue(captured.contains("integer"), "warning must name the received type")
    }

    func testDecodeAccountId_nullAndAbsentEmitNoWarning() {
        // Explicit JSON null and an absent key both legitimately mean "no
        // account_id supplied" — they must stay silent. Pins the `isNull`
        // guard against removal, which would spuriously warn on every null.
        XCTAssertEqual(
            captureStderr { _ = decodeAccountId(["account_id": .null], tool: "save_attachment") },
            "", "explicit JSON null must not warn")
        XCTAssertEqual(
            captureStderr { _ = decodeAccountId([:], tool: "save_attachment") },
            "", "absent account_id must not warn")
    }

    // MARK: - fastPathFallthroughLog (#100 — observability for the nil-return branch)

    func testFastPathFallthroughLog_rowIdNotIndexedIsNeutralMiss() {
        // The nil-return branch fires legitimately for every EWS/Exchange
        // account — the message must read as a neutral "miss", never "failed".
        let line = fastPathFallthroughLog(tool: "get_email", rowId: 273214, reason: .rowIdNotIndexed)
        XCTAssertTrue(line.contains("fast path miss"), "got: \(line)")
        XCTAssertTrue(line.contains("get_email"))
        XCTAssertTrue(line.contains("rowId=273214"))
        XCTAssertTrue(line.contains("Envelope Index"))
        XCTAssertTrue(line.contains("EWS/Exchange"), "must flag the legitimate #9 case")
        XCTAssertFalse(line.contains("failed"), "nil-return is a miss, not a failure — must not cry wolf")
        XCTAssertTrue(line.hasSuffix("\n"))
    }

    func testFastPathFallthroughLog_errorReportsDetail() {
        let line = fastPathFallthroughLog(tool: "get_email", rowId: 99,
                                          reason: .error("emlx file not found"))
        XCTAssertTrue(line.contains("fast path failed"), "got: \(line)")
        XCTAssertTrue(line.contains("emlx file not found"))
        XCTAssertTrue(line.contains("rowId=99"))
    }

    func testFastPathFallthroughLog_perItemSuffix() {
        let single = fastPathFallthroughLog(tool: "get_email", rowId: 1, reason: .rowIdNotIndexed)
        XCTAssertTrue(single.hasSuffix("AppleScript\n"), "single-item form has no 'for this item'")
        let batch = fastPathFallthroughLog(tool: "get_emails_batch", rowId: 1,
                                           reason: .rowIdNotIndexed, perItem: true)
        XCTAssertTrue(batch.hasSuffix("AppleScript for this item\n"))
    }

    func testFastPathFallthroughLog_errorByteEquivalentToLegacyInline() {
        // The `.error` case must reproduce the pre-#100 inline catch-branch
        // strings byte-for-byte, so routing the throw path through the helper
        // is a pure refactor.
        let rowId = 42
        let detail = "boom"
        XCTAssertEqual(
            fastPathFallthroughLog(tool: "get_email", rowId: rowId, reason: .error(detail)),
            "SQLite get_email fast path failed for rowId=\(rowId): "
                + "\(detail); falling through to AppleScript\n")
        XCTAssertEqual(
            fastPathFallthroughLog(tool: "get_emails_batch", rowId: rowId,
                                   reason: .error(detail), perItem: true),
            "SQLite get_emails_batch fast path failed for rowId=\(rowId): "
                + "\(detail); falling through to AppleScript for this item\n")
    }

    func testLogFastPathFallthrough_writesToStderr() {
        // The whole point of #100 is that the nil-return fall-through is no
        // longer silent — pin the actual stderr write.
        let captured = captureStderr {
            logFastPathFallthrough(tool: "get_email", rowId: 555, reason: .rowIdNotIndexed)
        }
        XCTAssertTrue(captured.contains("fast path miss"), "got: \(captured)")
        XCTAssertTrue(captured.contains("rowId=555"))
    }

    // MARK: - saveAttachmentAppleEventHint (#103 — actionable -10000 error)

    func testSaveAttachmentAppleEventHint_minus10000_probabilistic() {
        // localCopyConfirmedMissing=false → Tier 1 did not independently prove
        // the cause, so the message is hedged ("usually").
        let msg = saveAttachmentAppleEventHint(
            code: -10000, accountName: "d06227105@ntu.edu.tw",
            rawMessage: "Mail got an error: AppleEvent handler failed.",
            localCopyConfirmedMissing: false) ?? ""
        XCTAssertTrue(msg.contains("save_attachment failed"), "got: \(msg)")
        XCTAssertTrue(msg.contains("-10000"))
        XCTAssertTrue(msg.contains("Mail got an error: AppleEvent handler failed."),
                      "must echo the raw AppleScript message")
        XCTAssertTrue(msg.contains("d06227105@ntu.edu.tw"), "recovery step must name the account")
        XCTAssertTrue(msg.contains("synchronize_account"), "must cross-reference the MCP tool")
        XCTAssertTrue(msg.contains("Rebuild"))
        XCTAssertTrue(msg.contains("usually"), "unconfirmed cause must stay hedged")
    }

    func testSaveAttachmentAppleEventHint_minus10000_definitiveWhenConfirmedMissing() {
        // localCopyConfirmedMissing=true → Tier 1 already threw attachmentNotFound,
        // so the MCP states the cause definitively, not "usually".
        let msg = saveAttachmentAppleEventHint(
            code: -10000, accountName: "d06227105@ntu.edu.tw",
            rawMessage: "AppleEvent handler failed.",
            localCopyConfirmedMissing: true) ?? ""
        XCTAssertTrue(msg.contains("already confirmed"), "got: \(msg)")
        XCTAssertTrue(msg.contains("absent from the local Mail store"))
        XCTAssertFalse(msg.contains("usually"), "a confirmed cause must not be hedged")
    }

    func testSaveAttachmentAppleEventHint_unknownCodesReturnNil() {
        // #173 widened the hint to -10000 / -1719 / -1728. Any OTHER code
        // still rethrows unchanged so unanticipated diagnostics are not masked.
        XCTAssertNil(saveAttachmentAppleEventHint(
            code: 0, accountName: "a@b.com", rawMessage: "", localCopyConfirmedMissing: false))
        XCTAssertNil(saveAttachmentAppleEventHint(
            code: -1700, accountName: "a@b.com", rawMessage: "coercion failed",
            localCopyConfirmedMissing: false))
    }

    // MARK: - saveAttachmentAppleEventHint #173 expansion (-1719 / -1728)

    func testSaveAttachmentAppleEventHint_minus1719_actionable() {
        let msg = saveAttachmentAppleEventHint(
            code: -1719, accountName: "Google",
            rawMessage: "Can't get mailbox 1 of account id \"E51B96AC\" whose name = \"[Gmail]/全部郵件\". Invalid index.",
            localCopyConfirmedMissing: false) ?? ""
        XCTAssertTrue(msg.contains("-1719"), "got: \(msg)")
        XCTAssertTrue(msg.contains("Invalid index"),
                      "must echo the raw AppleScript message so diagnostics are not masked")
        XCTAssertTrue(msg.contains("account_id"),
                      "recovery must point at the UUID disambiguation parameter")
        XCTAssertTrue(msg.contains("search_emails"),
                      "recovery must anchor the mailbox string to search_emails output")
    }

    func testSaveAttachmentAppleEventHint_minus1728_explainsNamespaceMismatch() {
        let msg = saveAttachmentAppleEventHint(
            code: -1728, accountName: "kiki@example.com",
            rawMessage: "Can't get account \"kiki@example.com\".",
            localCopyConfirmedMissing: false) ?? ""
        XCTAssertTrue(msg.contains("-1728"), "got: \(msg)")
        XCTAssertTrue(msg.contains("Can't get account"),
                      "must echo the raw AppleScript message")
        XCTAssertTrue(msg.contains("account_id"),
                      "recovery must point at the UUID parameter")
        XCTAssertTrue(msg.contains("list_accounts"),
                      "recovery must say where to discover the UUID")
        XCTAssertTrue(msg.lowercased().contains("description"),
                      "must explain account_name matches Mail's account description, not the email")
    }

    // MARK: - Hint discrimination on the failing object class (verify PR #187)
    //
    // -1719 fires for any zero-match `first … whose` filter and -1728 for any
    // failed named access — a single asserted cause per code misdirects
    // recovery. The hint must route on the object class the raw AppleScript
    // message names, with precedence message → mailbox → account.

    func testHint_minus1719_staleMessageId_routesToSearchEmailsRefresh() {
        let msg = saveAttachmentAppleEventHint(
            code: -1719, accountName: "Google",
            rawMessage: "Can't get message 1 of mailbox \"全部郵件\" of mailbox \"[Gmail]\" of account id \"E51B96AC\". Invalid index.",
            localCopyConfirmedMissing: false) ?? ""
        XCTAssertTrue(msg.contains("MESSAGE"),
                      "a message-lookup failure must be attributed to the message, not the mailbox; got:\n\(msg)")
        XCTAssertTrue(msg.contains("stale"),
                      "must explain the id may be stale")
        XCTAssertTrue(msg.contains("Re-run search_emails"),
                      "recovery must be a fresh search, not mailbox debugging")
    }

    func testHint_minus1728_missingChainSegment_routesToMailboxNotAccount() {
        // Post-#174, a missing nested segment fails as NAMED access → -1728
        // ("Can't get mailbox \"X\" of …") — the old code-keyed hint lectured
        // about the account namespace, which cannot help here.
        let msg = saveAttachmentAppleEventHint(
            code: -1728, accountName: "Google",
            rawMessage: "Can't get mailbox \"草稿\" of mailbox \"[Gmail]\" of account id \"E51B96AC\".",
            localCopyConfirmedMissing: false) ?? ""
        XCTAssertTrue(msg.contains("MAILBOX"),
                      "-1728 naming a mailbox must route to mailbox guidance; got:\n\(msg)")
        XCTAssertTrue(msg.contains("list_mailboxes"))
        XCTAssertFalse(msg.contains("ACCOUNT selector"),
                       "must not lecture about the account namespace when the mailbox failed")
    }

    func testHint_unrecognizedRawMessage_fallsBackToHedgedCombined() {
        let msg = saveAttachmentAppleEventHint(
            code: -1719, accountName: "Google",
            rawMessage: "Some opaque AppleScript failure.",
            localCopyConfirmedMissing: false) ?? ""
        XCTAssertTrue(msg.contains("could not be resolved"),
                      "unrecognized raw text must get the hedged combined hint; got:\n\(msg)")
        XCTAssertTrue(msg.contains("Some opaque AppleScript failure."),
                      "raw message must still be echoed")
    }

    func testSaveAttachmentAppleEventHint_minus10000_textUnchangedBy173() {
        // The #103 contract for -10000 must stay BYTE-identical through the
        // #173 guard widening — full golden-string compare for both variants
        // (verify PR #187 finding 6: keyword locks let wording drift).
        let hedged = saveAttachmentAppleEventHint(
            code: -10000, accountName: "a@b", rawMessage: "x",
            localCopyConfirmedMissing: false)
        XCTAssertEqual(hedged, """
        save_attachment failed: Mail.app's save-attachment handler raised an error \
        (-10000, AppleEvent handler failed — "x"). For save_attachment this usually \
        means the attachment's binary is not in the local Mail cache and Mail.app \
        could not re-fetch it from the IMAP server. Recovery options:
        (1) Re-fetch the message: call the synchronize_account MCP tool for \
        "a@b" (or in Mail.app: Mailbox menu → Take All Accounts Online, then \
        Synchronize "a@b"), then retry save_attachment.
        (2) In Mail.app: select the affected mailbox, then Mailbox menu → Rebuild.
        (3) Manual fallback: open the message in Mail.app and use the attachment's \
        "Save Attachment…" / drag-out, which forces Mail.app to fetch the binary.
        If the local copy IS present, instead check that the save_path directory is \
        writable and has free space.
        """)
        let confirmed = saveAttachmentAppleEventHint(
            code: -10000, accountName: "a@b", rawMessage: "x",
            localCopyConfirmedMissing: true)
        XCTAssertEqual(confirmed, """
        save_attachment failed: Mail.app's save-attachment handler raised an error \
        (-10000, AppleEvent handler failed — "x"). The SQLite + .emlx fast path \
        already confirmed the attachment's binary is absent from the local Mail \
        store (no inline copy in the .emlx, no externalised copy in the Attachments \
        cache), so Mail.app had to re-fetch it from the IMAP server — and that \
        fetch failed. Recovery options:
        (1) Re-fetch the message: call the synchronize_account MCP tool for \
        "a@b" (or in Mail.app: Mailbox menu → Take All Accounts Online, then \
        Synchronize "a@b"), then retry save_attachment.
        (2) In Mail.app: select the affected mailbox, then Mailbox menu → Rebuild.
        (3) Manual fallback: open the message in Mail.app and use the attachment's \
        "Save Attachment…" / drag-out, which forces Mail.app to fetch the binary.
        If the local copy IS present, instead check that the save_path directory is \
        writable and has free space.
        """)
    }

    // MARK: - save_attachment handler wiring (verify PR #187 finding 7)
    //
    // resolveSaveAttachmentAccountId is unit-tested in isolation; this
    // structural pin (same discipline as #139's MailboxCrudScriptBuilderTests)
    // catches the "handler stopped threading the resolver's result" regression
    // that the isolated unit tests cannot see.

    func testSaveAttachmentHandler_threadsResolvedAccountId() throws {
        let serverSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CheAppleMailMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/CheAppleMailMCP/Server.swift")
        let source = try String(contentsOf: serverSource, encoding: .utf8)
        guard let caseStart = source.range(of: "case \"save_attachment\":") else {
            XCTFail("save_attachment case not found in Server.swift")
            return
        }
        let tail = source[caseStart.upperBound...]
        let caseBody = tail.range(of: "\n        case \"").map { String(tail[..<$0.lowerBound]) }
            ?? String(tail)
        XCTAssertTrue(caseBody.contains("resolveSaveAttachmentAccountId("),
                      "handler must call the resolver before Tier 2")
        XCTAssertTrue(caseBody.contains("accountId: resolvedAccountId"),
                      "handler must thread the resolver's result into saveAttachment")
    }

    // MARK: - ensureSaveDestinationDirectory (#178 — mkdir -p before both tiers)

    func testEnsureSaveDestinationDirectory_createsMissingParent() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ensuredir-\(UUID().uuidString)")
        addTeardownBlock { try? fm.removeItem(at: base) }
        // Nested parent that does not exist yet.
        let savePath = base.appendingPathComponent("a/b/c/report.pdf").path
        let parent = URL(fileURLWithPath: savePath).deletingLastPathComponent().path
        XCTAssertFalse(fm.fileExists(atPath: parent), "precondition: parent absent")

        try ensureSaveDestinationDirectory(savePath)

        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: parent, isDirectory: &isDir) && isDir.boolValue,
                      "parent directory must exist after ensure")
    }

    func testEnsureSaveDestinationDirectory_idempotentOnExisting() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ensuredir-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: base) }
        let savePath = base.appendingPathComponent("report.pdf").path
        // Parent (base) already exists — must not throw, must not disturb it.
        XCTAssertNoThrow(try ensureSaveDestinationDirectory(savePath))
        XCTAssertNoThrow(try ensureSaveDestinationDirectory(savePath))  // twice = idempotent
    }

    func testEnsureSaveDestinationDirectory_rejectsMalformedPaths() throws {
        // verify PR #189 / DA finding: empty / relative / trailing-slash save_path
        // makes deletingLastPathComponent resolve to cwd or strip the leaf, so the
        // claimed "mkdir -p makes a later -10000 trustworthy" invariant would be
        // false. These must be rejected at the boundary as invalidParameter.
        for bad in ["", "report.pdf", "relative/sub/report.pdf", "/tmp/wantdir/"] {
            XCTAssertThrowsError(try ensureSaveDestinationDirectory(bad),
                                 "must reject malformed save_path \"\(bad)\"") { error in
                guard let mailErr = error as? MailError,
                      case .invalidParameter(let msg) = mailErr else {
                    XCTFail("expected MailError.invalidParameter for \"\(bad)\", got \(error)")
                    return
                }
                XCTAssertTrue(msg.contains("save_path") && msg.contains("absolute"),
                              "error must explain the absolute-file-path requirement; got: \(msg)")
            }
        }
    }

    func testEnsureSaveDestinationDirectory_throwsActionableWhenParentUnwritable() throws {
        // verify PR #189 codex MEDIUM: an existing-but-unwritable parent makes
        // createDirectory a no-op success yet the write still fails → Tier 2's
        // misleading -10000. Must surface as actionable operationFailed instead.
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ensuredir-\(UUID().uuidString)")
        let ro = base.appendingPathComponent("ro")
        try fm.createDirectory(at: ro, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ro.path)  // r-x, no write
        addTeardownBlock {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ro.path)
            try? fm.removeItem(at: base)
        }
        let savePath = ro.appendingPathComponent("report.pdf").path

        XCTAssertThrowsError(try ensureSaveDestinationDirectory(savePath)) { error in
            guard let mailErr = error as? MailError,
                  case .operationFailed(let msg) = mailErr else {
                XCTFail("expected MailError.operationFailed, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("writable"),
                          "error must name the writability problem; got: \(msg)")
        }
    }

    func testEnsureSaveDestinationDirectory_throwsActionableWhenParentUncreatable() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ensuredir-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: base) }
        // Make a FILE, then try to use a path *under* that file as a directory —
        // createDirectory(withIntermediateDirectories:) cannot turn a file into a dir.
        let blocker = base.appendingPathComponent("iam-a-file")
        try Data("x".utf8).write(to: blocker)
        let savePath = blocker.appendingPathComponent("sub/report.pdf").path

        XCTAssertThrowsError(try ensureSaveDestinationDirectory(savePath)) { error in
            guard let mailErr = error as? MailError,
                  case .operationFailed(let msg) = mailErr else {
                XCTFail("expected MailError.operationFailed, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("save_path"),
                          "error must name the save_path parent problem; got: \(msg)")
            XCTAssertTrue(msg.lowercased().contains("permission") || msg.contains("directory"),
                          "error must be actionable about the directory; got: \(msg)")
        }
    }

    func testSaveAttachmentHandler_ensuresDestinationDirectoryBeforeTier1() throws {
        // Structural pin (#178, same discipline as the resolver wiring test):
        // the handler must mkdir -p the save_path parent BEFORE the Tier 1
        // fast-path, so a missing dir never reaches Tier 2's misleading -10000.
        let serverSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/Server.swift")
        let source = try String(contentsOf: serverSource, encoding: .utf8)
        guard let caseStart = source.range(of: "case \"save_attachment\":") else {
            XCTFail("save_attachment case not found"); return
        }
        let tail = source[caseStart.upperBound...]
        let caseBody = tail.range(of: "\n        case \"").map { String(tail[..<$0.lowerBound]) } ?? String(tail)
        guard let ensureIdx = caseBody.range(of: "ensureSaveDestinationDirectory(")?.lowerBound else {
            XCTFail("handler must call ensureSaveDestinationDirectory"); return
        }
        // Must come before the Tier 1 fast-path call.
        if let tier1Idx = caseBody.range(of: "EmlxParser.saveAttachment(")?.lowerBound {
            XCTAssertTrue(ensureIdx < tier1Idx,
                          "ensureSaveDestinationDirectory must run BEFORE Tier 1 EmlxParser.saveAttachment")
        }
    }

    // MARK: - resolveSaveAttachmentAccountId (#173 — email→UUID normalization)

    func testResolveAccountId_passthroughWhenAccountIdProvided() throws {
        let result = try resolveSaveAttachmentAccountId(
            accountId: "UUID-X", accountName: "anything@example.com",
            uuidsForEmail: { _ in XCTFail("lookup must not run when accountId is given"); return [] })
        XCTAssertEqual(result, "UUID-X")
    }

    func testResolveAccountId_nonEmailName_skipsLookup() throws {
        let result = try resolveSaveAttachmentAccountId(
            accountId: nil, accountName: "Google",
            uuidsForEmail: { _ in XCTFail("lookup must not run for non-email names"); return [] })
        XCTAssertNil(result, "Non-email account_name keeps the legacy display_name path")
    }

    func testResolveAccountId_singleMatch_upgradesToUuid() throws {
        let result = try resolveSaveAttachmentAccountId(
            accountId: nil, accountName: "alice@example.com",
            uuidsForEmail: { email in
                XCTAssertEqual(email, "alice@example.com")
                return ["UUID-A"]
            })
        XCTAssertEqual(result, "UUID-A",
                       "Exactly one match must upgrade to the account id selector")
    }

    func testResolveAccountId_emptyAccountId_treatedAsNil() throws {
        let result = try resolveSaveAttachmentAccountId(
            accountId: "", accountName: "alice@example.com",
            uuidsForEmail: { _ in ["UUID-A"] })
        XCTAssertEqual(result, "UUID-A")
    }

    func testResolveAccountId_noMatch_fallsBackToLegacy() throws {
        let result = try resolveSaveAttachmentAccountId(
            accountId: nil, accountName: "nobody@example.com",
            uuidsForEmail: { _ in [] })
        XCTAssertNil(result)
    }

    func testResolveAccountId_multipleMatches_throwsListingCandidates() {
        // The #173 scenario: iCloud catch-all + Google both present the same
        // address — auto-picking would silently target the wrong account.
        XCTAssertThrowsError(try resolveSaveAttachmentAccountId(
            accountId: nil, accountName: "dup@example.com",
            uuidsForEmail: { _ in ["UUID-A", "UUID-Z"] })) { error in
            let msg = String(describing: error)
            XCTAssertTrue(msg.contains("UUID-A") && msg.contains("UUID-Z"),
                          "error must list every candidate UUID; got: \(msg)")
            XCTAssertTrue(msg.contains("account_id"),
                          "error must tell the caller which parameter resolves the ambiguity")
            XCTAssertTrue(msg.contains("list_accounts"),
                          "error must say where to inspect the candidates")
        }
    }

    func testMailErrorOperationFailed_describesVerbatim() {
        // operationFailed must surface its message verbatim — no "AppleScript
        // error (N):" prefix — so the actionable #103 hint reaches the caller intact.
        let err = MailError.operationFailed("recovery: do X then Y")
        XCTAssertEqual(err.errorDescription, "recovery: do X then Y")
    }

    // MARK: - crossValidateAttachments savable stamping (#105)

    func testCrossValidateAttachments_stampsSavableAndOmitsUnknown() {
        let rows: [[String: Any]] = [
            ["name": "present.pdf", "attachment_id": "1"],
            ["name": "missing.pdf", "attachment_id": "2"],
            ["name": "unknown.pdf", "attachment_id": "3"],
            ["name": "stale.pdf", "attachment_id": "4"],   // not in realNames → dropped
        ]
        let realNames: Set<String> = ["present.pdf", "missing.pdf", "unknown.pdf"]
        // unknown.pdf is intentionally absent from the savability map.
        let savability = ["present.pdf": true, "missing.pdf": false]
        let out = crossValidateAttachments(
            sqliteAttachments: rows, realNames: realNames, savability: savability)

        XCTAssertEqual(out.count, 3, "stale.pdf not in realNames must be dropped")
        func entry(_ name: String) -> [String: Any]? {
            out.first { $0["name"] as? String == name }
        }
        XCTAssertEqual(entry("present.pdf")?["savable"] as? Bool, true)
        XCTAssertEqual(entry("missing.pdf")?["savable"] as? Bool, false)
        XCTAssertNil(entry("unknown.pdf")?["savable"],
                     "absent from savability → savable omitted (unknown), never guessed")
    }

    func testCrossValidateAttachments_emptySavabilityOmitsField() {
        // The .emlx-parse-failure fallback passes no savability — every entry
        // must pass through with no `savable` key (old-caller behavior).
        let rows: [[String: Any]] = [["name": "a.pdf", "attachment_id": "1"]]
        let out = crossValidateAttachments(sqliteAttachments: rows, realNames: ["a.pdf"])
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0]["savable"], "empty savability → field omitted")
    }

    // MARK: - parseBodyFormatArgument (handles MCP Value type)

    func testParseBodyFormatArgument_nilReturnsPlain() throws {
        XCTAssertEqual(try parseBodyFormatArgument(nil), .plain)
    }

    func testParseBodyFormatArgument_stringValid() throws {
        XCTAssertEqual(try parseBodyFormatArgument(.string("markdown")), .markdown)
    }

    func testParseBodyFormatArgument_integerRejected() {
        XCTAssertThrowsError(try parseBodyFormatArgument(.int(42))) { error in
            guard let mailErr = error as? MailError,
                  case .invalidParameter(let msg) = mailErr else {
                XCTFail("Expected MailError.invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("must be a string"), "error message must call out type mismatch")
        }
    }

    func testParseBodyFormatArgument_booleanRejected() {
        XCTAssertThrowsError(try parseBodyFormatArgument(.bool(true)))
    }

    // MARK: - requireBool / optionalStringArray (#35 — type-strict handler validation)

    func testRequireBool_validBoolReturnsValue() throws {
        XCTAssertEqual(try requireBool(["k": .bool(true)], key: "k", default: false), true)
        XCTAssertEqual(try requireBool(["k": .bool(false)], key: "k", default: true), false)
    }

    func testRequireBool_missingKeyReturnsDefault() throws {
        XCTAssertEqual(try requireBool([:], key: "k", default: true), true)
        XCTAssertEqual(try requireBool([:], key: "k", default: false), false)
    }

    func testRequireBool_nullValueReturnsDefault() throws {
        // Caller emitted explicit `null` — treat as missing.
        XCTAssertEqual(try requireBool(["k": .null], key: "k", default: true), true)
        XCTAssertEqual(try requireBool(["k": .null], key: "k", default: false), false)
    }

    func testRequireBool_stringTrueIsRejected() {
        // Issue #35 anti-pattern: previously `arguments["save_as_draft"]?.boolValue ?? false`
        // silently coerced string "true" to false → user wanted draft, got send.
        XCTAssertThrowsError(try requireBool(["k": .string("true")], key: "k", default: false)) { err in
            guard case MailError.invalidParameter(let msg) = err else {
                XCTFail("expected MailError.invalidParameter, got \(err)")
                return
            }
            XCTAssertTrue(msg.contains("'k'"), "error must name the key: \(msg)")
            XCTAssertTrue(msg.contains("boolean"), "error must mention expected type: \(msg)")
            XCTAssertTrue(msg.contains("string"), "error must mention actual type: \(msg)")
        }
    }

    func testRequireBool_intRejected() {
        XCTAssertThrowsError(try requireBool(["k": .int(1)], key: "k", default: false))
    }

    func testOptionalStringArray_validReturnsArray() throws {
        let result = try optionalStringArray(["k": .array([.string("a"), .string("b")])], key: "k")
        XCTAssertEqual(result, ["a", "b"])
    }

    func testOptionalStringArray_missingKeyReturnsNil() throws {
        XCTAssertNil(try optionalStringArray([:], key: "k"))
    }

    func testOptionalStringArray_nullReturnsNil() throws {
        XCTAssertNil(try optionalStringArray(["k": .null], key: "k"))
    }

    func testOptionalStringArray_emptyArrayReturnsEmpty() throws {
        XCTAssertEqual(try optionalStringArray(["k": .array([])], key: "k"), [])
    }

    func testOptionalStringArray_stringInsteadOfArrayRejected() {
        // Anti-pattern: caller sent a single string instead of array.
        // Previously `?.arrayValue?.compactMap` returned nil silently → entry dropped.
        XCTAssertThrowsError(try optionalStringArray(["k": .string("a@b.com")], key: "k")) { err in
            guard case MailError.invalidParameter(let msg) = err else {
                XCTFail("expected MailError.invalidParameter, got \(err)")
                return
            }
            XCTAssertTrue(msg.contains("'k'"))
            XCTAssertTrue(msg.contains("array of strings"))
        }
    }

    func testOptionalStringArray_nonStringElementRejected() {
        // Mixed types in the array — reject (don't silently drop).
        XCTAssertThrowsError(try optionalStringArray(["k": .array([.string("a"), .int(42)])], key: "k")) { err in
            guard case MailError.invalidParameter(let msg) = err else {
                XCTFail("expected MailError.invalidParameter, got \(err)")
                return
            }
            XCTAssertTrue(msg.contains("'k[1]'"), "error must point to the offending index: \(msg)")
            XCTAssertTrue(msg.contains("integer"), "error must mention actual type")
        }
    }

    // MARK: - Schema property type-annotation assertions (#42)

    /// Helper for #42: assert a schema property exists AND has the expected type
    /// annotation. For arrays, optionally assert items.type. Catches accidental
    /// drop of `type` or `items.type` during schema refactors.
    private func assertSchemaProperty(_ properties: [String: Value],
                                      key: String,
                                      hasType: String,
                                      itemsType: String? = nil,
                                      file: StaticString = #file, line: UInt = #line) {
        guard let prop = properties[key] else {
            XCTFail("schema missing key '\(key)'", file: file, line: line)
            return
        }
        guard case .object(let propObj) = prop else {
            XCTFail("'\(key)' must be a schema object", file: file, line: line)
            return
        }
        guard case .string(let typeStr) = propObj["type"] ?? .null else {
            XCTFail("'\(key)' missing or wrong-typed 'type' annotation", file: file, line: line)
            return
        }
        XCTAssertEqual(typeStr, hasType, "'\(key)'.type must be '\(hasType)'", file: file, line: line)

        if let expectedItemsType = itemsType {
            guard case .object(let itemsObj) = propObj["items"] ?? .null,
                  case .string(let actualItemsType) = itemsObj["type"] ?? .null else {
                XCTFail("'\(key)'.items.type missing or wrong-typed", file: file, line: line)
                return
            }
            XCTAssertEqual(actualItemsType, expectedItemsType,
                           "'\(key)'.items.type must be '\(expectedItemsType)'",
                           file: file, line: line)
        }
    }

    func testReplyEmail_typeAnnotationsAreCorrect() throws {
        // Issue #42: schema tests must assert type annotations not just key presence.
        // Catches accidental drop of type or items.type during refactors.
        guard let tool = tool(named: "reply_email"),
              let props = propertiesObject(of: tool) else {
            XCTFail("reply_email schema missing")
            return
        }
        assertSchemaProperty(props, key: "id", hasType: "string")
        assertSchemaProperty(props, key: "mailbox", hasType: "string")
        assertSchemaProperty(props, key: "account_name", hasType: "string")
        assertSchemaProperty(props, key: "body", hasType: "string")
        assertSchemaProperty(props, key: "reply_all", hasType: "boolean")
        assertSchemaProperty(props, key: "save_as_draft", hasType: "boolean")
        assertSchemaProperty(props, key: "cc_additional", hasType: "array", itemsType: "string")
        assertSchemaProperty(props, key: "attachments", hasType: "array", itemsType: "string")
        assertSchemaProperty(props, key: "format", hasType: "string")
    }

    func testComposeEmail_typeAnnotationsAreCorrect() throws {
        guard let tool = tool(named: "compose_email"),
              let props = propertiesObject(of: tool) else {
            XCTFail("compose_email schema missing")
            return
        }
        assertSchemaProperty(props, key: "to", hasType: "array", itemsType: "string")
        assertSchemaProperty(props, key: "subject", hasType: "string")
        assertSchemaProperty(props, key: "body", hasType: "string")
        assertSchemaProperty(props, key: "cc", hasType: "array", itemsType: "string")
        assertSchemaProperty(props, key: "bcc", hasType: "array", itemsType: "string")
        assertSchemaProperty(props, key: "attachments", hasType: "array", itemsType: "string")
        assertSchemaProperty(props, key: "format", hasType: "string")
    }

    // MARK: - Scenario (#28): cross-validation filter (issue #24 follow-up)
    //
    // `crossValidateAttachments` is the helper extracted from the inline
    // filter closures at Server.swift list_attachments (single-message)
    // and list_attachments_batch (per-message). Both handlers must apply
    // identical filtering: keep only SQLite entries whose `name` field
    // appears in the .emlx-parsed `realNames` set; drop entries with no
    // name field. These tests pin the filter behavior directly — a bug
    // in the filter logic (inverted condition, missing as? String cast,
    // omitted call) would not be caught by per-helper tests on
    // `attachmentNames` / `listAttachments` alone.

    func testCrossValidateAttachments_keepsOnlyEntriesWithMatchingName() {
        let sqlite: [[String: Any]] = [
            ["name": "real.pdf", "size": 12345],
            ["name": "stale.pdf", "size": 67890]  // SQLite has this but .emlx doesn't
        ]
        let realNames: Set<String> = ["real.pdf"]
        let result = crossValidateAttachments(sqliteAttachments: sqlite, realNames: realNames)
        XCTAssertEqual(result.count, 1, "filter must drop stale.pdf which is absent from .emlx")
        XCTAssertEqual(result.first?["name"] as? String, "real.pdf")
    }

    func testCrossValidateAttachments_emptyRealNames_dropsEverything() {
        // Edge: .emlx had no attachments but SQLite has stale rows
        // (Mail.app stripped the binary on Sent / IMAP lazy-load).
        let sqlite: [[String: Any]] = [
            ["name": "ghost1.pdf"],
            ["name": "ghost2.pdf"]
        ]
        let result = crossValidateAttachments(sqliteAttachments: sqlite, realNames: [])
        XCTAssertTrue(result.isEmpty, "empty realNames must filter out all SQLite entries (#24 stale-cache scenario)")
    }

    func testCrossValidateAttachments_emptySQLite_returnsEmpty() {
        // Edge: SQLite has no rows but .emlx parser found names (impossible
        // in practice — would mean Mail.app missed indexing — but filter
        // must handle it gracefully).
        let result = crossValidateAttachments(sqliteAttachments: [], realNames: ["something.pdf"])
        XCTAssertTrue(result.isEmpty, "empty SQLite input must yield empty result regardless of realNames")
    }

    func testCrossValidateAttachments_dropsEntriesWithoutNameField() {
        // Defensive: SQLite rows missing the `name` field must be dropped
        // (otherwise they pass through unvalidated).
        let sqlite: [[String: Any]] = [
            ["size": 100],  // no name field
            ["name": "real.pdf"]
        ]
        let result = crossValidateAttachments(sqliteAttachments: sqlite, realNames: ["real.pdf"])
        XCTAssertEqual(result.count, 1, "entries missing the 'name' field MUST be dropped")
        XCTAssertEqual(result.first?["name"] as? String, "real.pdf")
    }

    func testCrossValidateAttachments_dropsEntriesWithNonStringName() {
        // Defensive: if `name` is non-String (e.g. NSNull, Int), the
        // `as? String` cast fails — entry must be dropped, not crashed.
        let sqlite: [[String: Any]] = [
            ["name": 42],  // numeric, not String
            ["name": NSNull()],
            ["name": "real.pdf"]
        ]
        let result = crossValidateAttachments(sqliteAttachments: sqlite, realNames: ["real.pdf"])
        XCTAssertEqual(result.count, 1, "non-String 'name' values MUST be dropped, not coerced")
        XCTAssertEqual(result.first?["name"] as? String, "real.pdf")
    }

    func testCrossValidateAttachments_preservesAllFieldsOfMatchedEntries() {
        // The filter must not mutate the matched entries — full row
        // (name, size, mimeType, etc.) is passed through unchanged.
        let sqlite: [[String: Any]] = [
            ["name": "real.pdf", "size": 12345, "mimeType": "application/pdf", "rowId": 999]
        ]
        let result = crossValidateAttachments(sqliteAttachments: sqlite, realNames: ["real.pdf"])
        XCTAssertEqual(result.count, 1)
        let entry = result[0]
        XCTAssertEqual(entry["name"] as? String, "real.pdf")
        XCTAssertEqual(entry["size"] as? Int, 12345)
        XCTAssertEqual(entry["mimeType"] as? String, "application/pdf")
        XCTAssertEqual(entry["rowId"] as? Int, 999)
    }
}
