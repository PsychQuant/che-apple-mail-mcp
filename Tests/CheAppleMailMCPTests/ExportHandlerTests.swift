import Darwin
import MCP
import SQLite3
import XCTest
@testable import CheAppleMailMCP
@testable import MailSQLite

/// #581: the export handler's option parsing and draft lookup, driven through
/// `executeToolCall` against a fixture Envelope Index.
///
/// `ExportDraftStatusTests` covers the helpers (`ExportEmailsMarkdown.run` with
/// an injected `draftStatusFor`, `parseSkipDraftsOption`, `exportOptions(from:)`)
/// one at a time. These tests pin the wiring between them in the handler: if
/// the handler went back to `exportOpts["skip_drafts"]?.boolValue ?? false`,
/// stopped calling `exportOptions(from:)`, or dropped `draftStatusFor:` (whose
/// default reports every message as unknown), the helper tests would stay green
/// and these would not.
///
/// Nothing here reaches Mail: the script-runner seam throws, so the identity
/// refresh fails at once and the handler falls back to the SQLite account list.
/// The only files read are the ones each test creates.
final class ExportHandlerTests: XCTestCase {
    private static let toolNames = ["batch_export_emails_markdown", "export_emails_markdown"]

    // MARK: - Harness

    /// A test-owned root under the canonical temp path, so the output_dir
    /// policy compares like with like (`/var` is a link to `/private/var`).
    private func makeRoot() throws -> URL {
        let pointer = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent("export581-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Rows copied from `DraftStatusTests.fixture()`: id 1 is a known draft
    /// (type 5 in Gmail's drafts folder), id 7 a known non-draft (type 0 in All
    /// Mail), id 4 unknown (type 6).
    private func writeIndex(at path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "ExportHandlerFixture", code: 1) }
        defer { sqlite3_close(db) }
        var sql = """
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, total_count INTEGER DEFAULT 0, unread_count INTEGER DEFAULT 0);
        CREATE TABLE recipients (message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, mailbox INTEGER,
          date_received INTEGER, read INTEGER DEFAULT 0, flagged INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0,
          size INTEGER DEFAULT 10, conversation_id INTEGER DEFAULT 1, flags INTEGER DEFAULT 0, global_message_id INTEGER, type);
        INSERT INTO addresses VALUES (1, 'sender@example.test', 'Fixture');
        INSERT INTO mailboxes (ROWID, url) VALUES (1, 'imap://UUID-A/%5BGmail%5D/%E8%8D%89%E7%A8%BF');
        INSERT INTO mailboxes (ROWID, url) VALUES (2, 'imap://UUID-A/%5BGmail%5D/All%20Mail');
        """
        for (id, mailbox, type) in [(1, 1, 5), (4, 2, 6), (7, 2, 0)] {
            sql += "INSERT INTO subjects VALUES (\(id), 'match \(id)');\n"
            sql += "INSERT INTO messages (ROWID,subject,sender,mailbox,date_received,global_message_id,type) "
                + "VALUES (\(id),\(id),1,\(mailbox),\(1000 + id),\(id),\(type));\n"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "ExportHandlerFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    /// The .emlx of the known non-draft, so strict mode has a message to write.
    private func plantNonDraftMessage(under storage: URL) throws {
        let messages = storage.appendingPathComponent("UUID-A/[Gmail].mbox/All Mail.mbox")
            .appendingPathComponent("5FCC6F13-2CE3-48B1-907D-686244C0229A/Data/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let message = Data("""
        From: Fixture <sender@example.test>
        To: owner@example.test
        Subject: match 7
        Date: Tue, 30 Jun 2026 12:00:00 +0000
        Message-ID: <seven@fixture.test>
        Content-Type: text/plain; charset=utf-8

        body seven

        """.utf8)
        try (Data("\(message.count)\n".utf8) + message).write(to: messages.appendingPathComponent("7.emlx"))
    }

    /// A server over the fixture index, with every piece of process-global
    /// state it reads set for this test and restored afterwards.
    private func makeServer() async throws -> (server: CheAppleMailMCPServer, root: URL) {
        let root = try makeRoot()
        let indexPath = root.appendingPathComponent("Envelope Index").path
        try writeIndex(at: indexPath)
        let storage = root.appendingPathComponent("Mail", isDirectory: true)
        try plantNonDraftMessage(under: storage)

        // The fixture's statuses are the premise of every assertion below; if
        // the reader's draft SQL changes, fail here rather than in the handler.
        let reader = try EnvelopeIndexReader(databasePath: indexPath, accountMapping: ["UUID-A": "Fixture"])
        XCTAssertEqual(try reader.messageIsDraft(messageId: 1), true)
        XCTAssertEqual(try reader.messageIsDraft(messageId: 7), false)
        XCTAssertNil(try reader.messageIsDraft(messageId: 4))

        let previousStorage = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = storage.path
        addTeardownBlock { EnvelopeIndexReader.mailStoragePathOverride = previousStorage }

        let previousRoots = getenv("CHE_MAIL_EXPORT_ALLOWED_ROOTS").map { String(cString: $0) }
        setenv("CHE_MAIL_EXPORT_ALLOWED_ROOTS", root.path, 1)
        addTeardownBlock {
            if let previousRoots { setenv("CHE_MAIL_EXPORT_ALLOWED_ROOTS", previousRoots, 1) }
            else { unsetenv("CHE_MAIL_EXPORT_ALLOWED_ROOTS") }
        }

        // The list runner has its own override and no #362 XCTest guard, so it is
        // stubbed too: if an export path ever calls it, it fails here instead of
        // reaching Mail (#581 verify).
        await MailController.shared.setTestSeams(scriptRunner: { _ in
            throw MailError.operationFailed("ExportHandlerTests: no Mail in this test")
        }, refusal: nil, scriptListRunner: { _ in
            throw MailError.operationFailed("ExportHandlerTests: no Mail in this test")
        }, automationGranted: false)
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }

        let server = try await CheAppleMailMCPServer(
            databasePath: indexPath, initialSync: false,
            classificationDirectory: root.appendingPathComponent("classification", isDirectory: true),
            accountMapping: ["UUID-A": "Fixture"])
        return (server, root)
    }

    /// #612: `UUID-A` is in no machine's AccountsMap.plist, so the name can only come from the mapping
    /// the test passed. Without that seam the server would read the developer's accounts.
    func testAHandlerNamesTheAccountFromTheInjectedMapping() async throws {
        let (server, _) = try await makeServer()
        let raw = try await server.executeToolCall(name: "list_mailboxes", arguments: [:])
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]], raw)
        XCTAssertFalse(rows.isEmpty, raw)
        XCTAssertEqual(Set(rows.compactMap { $0["account_name"] as? String }), ["Fixture"], raw)
    }

    private func export(_ server: CheAppleMailMCPServer, tool: String = "batch_export_emails_markdown",
                        ids: [String], outputDir: URL, extra: [String: Value] = [:]) async throws -> [String: Any] {
        var arguments: [String: Value] = ["ids": .array(ids.map { .string($0) }), "output_dir": .string(outputDir.path)]
        arguments.merge(extra) { _, new in new }
        let raw = try await server.executeToolCall(name: tool, arguments: arguments)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], raw)
    }

    private func items(_ manifest: [String: Any]) throws -> [String: [String: Any]] {
        let list = try XCTUnwrap(manifest["items"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: list.map { ($0["id"] as? String ?? "", $0) })
    }

    // MARK: - Draft lookup

    /// Pins `draftStatusFor:`: its default `{ _ in nil }` would make all three null.
    func testDefaultExportReportsTheReadersDraftStatus() async throws {
        let (server, root) = try await makeServer()
        let manifest = try await export(server, ids: ["1", "7", "4"], outputDir: root.appendingPathComponent("out"))
        let byID = try items(manifest)
        XCTAssertEqual(byID["1"]?["is_draft"] as? Bool, true)
        XCTAssertEqual(byID["7"]?["is_draft"] as? Bool, false)
        XCTAssertTrue(byID["4"]?["is_draft"] is NSNull)
        XCTAssertEqual(manifest["drafts_skipped"] as? Int, 0, "default mode excludes nothing")
    }

    func testStrictExportSkipsTheDraftAndRefusesTheUnknownUnderBothToolNames() async throws {
        let (server, root) = try await makeServer()
        for tool in Self.toolNames {
            let manifest = try await export(server, tool: tool, ids: ["1", "7", "4"],
                                            outputDir: root.appendingPathComponent("out-\(tool)"),
                                            extra: ["opts": .object(["skip_drafts": .bool(true)])])
            let byID = try items(manifest)
            XCTAssertEqual(byID["1"]?["status"] as? String, "draft_skipped", tool)
            XCTAssertEqual(byID["1"]?["skip_reason"] as? String, "draft", tool)
            XCTAssertEqual(byID["4"]?["status"] as? String, "error", tool)
            XCTAssertTrue((byID["4"]?["error"] as? String)?.contains("draft_status_unknown") == true, tool)
            XCTAssertEqual(byID["7"]?["status"] as? String, "written", "\(tool): \(byID["7"] ?? [:])")
            XCTAssertEqual(manifest["drafts_skipped"] as? Int, 1, tool)
            XCTAssertEqual(manifest["written"] as? Int, 1, tool)
            XCTAssertEqual(manifest["errors"] as? Int, 1, tool)
        }
    }

    /// The closure's own `Int(id)` guard, not the default: the item names the failed lookup.
    func testStrictExportReportsAFailedLookupForANonNumericId() async throws {
        let (server, root) = try await makeServer()
        let manifest = try await export(server, ids: ["not-a-row"], outputDir: root.appendingPathComponent("out"),
                                        extra: ["opts": .object(["skip_drafts": .bool(true)])])
        let error = try XCTUnwrap(try items(manifest)["not-a-row"]?["error"] as? String)
        XCTAssertTrue(error.contains("draft_status_unknown"), error)
        XCTAssertTrue(error.contains("lookup failed"), error)
    }

    // MARK: - Option parsing

    /// Each call would otherwise succeed (the index exists), so a throw here
    /// comes from option parsing, not from a missing index.
    func testHandlerRejectsMalformedDraftOptions() async throws {
        let (server, root) = try await makeServer()
        // The expected text is the message each guard throws, so a call that
        // fails for some other reason that merely mentions the option still fails.
        let notBoolean = "opts.skip_drafts must be a boolean"
        let misplaced = "skip_drafts belongs inside opts"
        let notObject = "opts must be an object"
        let cases: [(String, [String: Value], String)] = [
            ("string skip_drafts", ["opts": .object(["skip_drafts": .string("true")])], notBoolean),
            ("integer skip_drafts", ["opts": .object(["skip_drafts": .int(1)])], notBoolean),
            ("null skip_drafts", ["opts": .object(["skip_drafts": .null])], notBoolean),
            ("top-level skip_drafts", ["skip_drafts": .bool(true)], misplaced),
            ("boolean opts", ["opts": .bool(true)], notObject),
            ("string opts", ["opts": .string("x")], notObject),
            ("array opts", ["opts": .array([])], notObject),
        ]
        for (label, extra, named) in cases {
            do {
                _ = try await export(server, ids: ["7"], outputDir: root.appendingPathComponent("out"), extra: extra)
                XCTFail("\(label): accepted")
            } catch {
                let message = error.localizedDescription
                XCTAssertTrue(message.contains(named), "\(label): \(message)")
                XCTAssertFalse(message.contains("envelope index"), "\(label): failed for the wrong reason: \(message)")
            }
        }
    }

    /// A null opts means absent, and an explicit `skip_drafts: false` is the default.
    func testHandlerTreatsNullOptsAndFalseAsTheDefault() async throws {
        let (server, root) = try await makeServer()
        let variants: [(String, [String: Value])] = [
            ("null opts", ["opts": .null]),
            ("absent opts", [:]),
            ("skip_drafts false", ["opts": .object(["skip_drafts": .bool(false)])]),
        ]
        for (label, extra) in variants {
            let manifest = try await export(server, ids: ["1"], outputDir: root.appendingPathComponent("out-\(label)"),
                                            extra: extra)
            XCTAssertEqual(manifest["drafts_skipped"] as? Int, 0, label)
            XCTAssertEqual(try items(manifest)["1"]?["is_draft"] as? Bool, true, label)
        }
    }

    // MARK: - Refused paths (#625)

    private static let refusedParameters = ["output_dir", "skip_message_ids_path"]

    /// A folder outside the allowed root, removed afterwards.
    private func makeOutsideFolder(beside root: URL) throws -> URL {
        let folder = root.deletingLastPathComponent().appendingPathComponent("export625-secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// The text a caller reads when `parameter` is refused. A good `output_dir` is
    /// supplied, so a refused `skip_message_ids_path` is the only thing that can fail.
    private func refusal(_ server: CheAppleMailMCPServer, _ parameter: String, _ path: String, root: URL) async -> String {
        var arguments: [String: Value] = ["ids": .array([.string("7")]),
                                          "output_dir": .string(root.appendingPathComponent("out").path)]
        arguments[parameter] = .string(path)
        do {
            _ = try await server.executeToolCall(name: "batch_export_emails_markdown", arguments: arguments)
            XCTFail("\(parameter): accepted \(path)")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    /// Runs `body` with fd 2 pointed at a file and returns what landed there. A
    /// file, not a pipe, so a chatty server cannot fill a buffer and hang the test.
    private func capturingStderr(during body: () async throws -> Void) async throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("export625-stderr-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let saved = dup(STDERR_FILENO)
        guard saved >= 0 else { throw NSError(domain: "ExportHandlerFixture", code: 3) }
        defer { close(saved) }
        let sink = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard sink >= 0 else { throw NSError(domain: "ExportHandlerFixture", code: 4) }
        let redirected = dup2(sink, STDERR_FILENO)
        close(sink)
        guard redirected == STDERR_FILENO else { throw NSError(domain: "ExportHandlerFixture", code: 5) }
        var failure: Error?
        do { try await body() } catch { failure = error }
        XCTAssertEqual(dup2(saved, STDERR_FILENO), STDERR_FILENO, "fd 2 was not restored")
        if let failure { throw failure }
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Resolution runs before the check, so an interpolated error told a caller
    /// with only MCP tools where a link inside the allowed root points.
    func testARefusalDoesNotSayWhereALinkPoints() async throws {
        let (server, root) = try await makeServer()
        let secret = try makeOutsideFolder(beside: root)
        try FileManager.default.createSymbolicLink(atPath: root.path + "/link", withDestinationPath: secret.path)
        for parameter in Self.refusedParameters {
            let message = await refusal(server, parameter, root.path + "/link/target", root: root)
            XCTAssertEqual(message, "Invalid parameter: \(parameter) rejected by write-safety check: outside the permitted "
                + "export policy. Use a path within CHE_MAIL_EXPORT_ALLOWED_ROOTS (default: home excluding sensitive paths).")
            XCTAssertFalse(message.contains(secret.lastPathComponent), message)
            XCTAssertFalse(message.contains("escapesAllowedRoots"), message)
            XCTAssertFalse(message.contains("path:"), message)
        }
    }

    /// Different wording would tell a caller which kind of location a path is, so
    /// whether a protected directory lies behind a link. The premise is checked
    /// first: if a fixture stopped being the kind it claims, the comparison would
    /// prove nothing about that kind.
    func testEveryKindOfRefusalReadsTheSame() async throws {
        let (server, root) = try await makeServer()
        let outside = try makeOutsideFolder(beside: root)
        let home = NSHomeDirectory()
        try FileManager.default.createSymbolicLink(atPath: root.path + "/to-system", withDestinationPath: "/private/etc")
        try FileManager.default.createSymbolicLink(atPath: root.path + "/to-home", withDestinationPath: home + "/Library")
        let cases: [(path: String, kind: String)] = [
            (outside.path + "/target", "escapesAllowedRoots"),
            ("/usr/export625-target", "systemPath"),
            (root.path + "/to-system/export625-target", "systemPath"),
            (home + "/.ssh/export625-target", "deniedHomePath"),
            (root.path + "/to-home/export625-target", "deniedHomePath"),
        ]
        for (path, kind) in cases {
            XCTAssertThrowsError(try AllowedRootsValidator().validate(path, allowedRoots: [root.path])) { error in
                XCTAssertTrue("\(error)".hasPrefix(kind + "("), "\(path): \(error)")
            }
        }
        for parameter in Self.refusedParameters {
            var messages: Set<String> = []
            for (path, _) in cases { messages.insert(await refusal(server, parameter, path, root: root)) }
            XCTAssertEqual(messages.count, 1, "\(parameter): \(messages)")
        }
    }

    /// The operator still needs to know why: the reason moved, it did not go away.
    func testARefusalKeepsItsReasonOnStderr() async throws {
        let (server, root) = try await makeServer()
        let secret = try makeOutsideFolder(beside: root)
        try FileManager.default.createSymbolicLink(atPath: root.path + "/link", withDestinationPath: secret.path)
        for parameter in Self.refusedParameters {
            let log = try await capturingStderr {
                _ = await refusal(server, parameter, root.path + "/link/target", root: root)
            }
            XCTAssertTrue(log.contains(parameter), log)
            XCTAssertTrue(log.contains("escapesAllowedRoots"), log)
            XCTAssertTrue(log.contains(secret.lastPathComponent + "/target"), log)
        }
    }
}
