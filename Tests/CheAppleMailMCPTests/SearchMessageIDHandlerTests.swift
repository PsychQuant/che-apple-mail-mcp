import Darwin
import MCP
import SQLite3
import XCTest
@testable import CheAppleMailMCP
@testable import MailSQLite

/// #682: `search_emails` with `include_message_id`, driven through `executeToolCall` against a
/// fixture Envelope Index and fixture `.emlx` files (all synthetic).
///
/// Row 1 has a plain Message-ID, 2 none, 3 a folded one, 4 two Message-ID headers, 5 an encoded
/// one, 6 a missing file, 7 CR-only line ends.
final class SearchMessageIDHandlerTests: XCTestCase {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return paths.count }
    }

    /// A factory whose lookup counts file reads and store-folder listings.
    private func countingFactory(_ reads: Reads, _ listings: Reads, failing: String? = nil) -> @Sendable () -> MessageIDLookup {
        { MessageIDLookup(readFile: { path in
            reads.add(path)
            if let failing, path.hasSuffix(failing) { throw NSError(domain: "SECRET-HEADER-TEXT", code: 1) }
            return try EmlxParser.readMessageID(atPath: path)
        }, storeFinder: { dir in listings.add(dir); return EmlxParser.findStoreUUID(in: dir) }) }
    }

    private static let messages: [Int: String] = [
        1: "From: a@example.invalid\r\nMessage-ID: <one@example.invalid>\r\n\r\nbody",
        2: "From: a@example.invalid\r\nSubject: s\r\n\r\nbody",
        3: "Message-ID:\r\n <fold@\r\n example.invalid>\r\n\r\nbody",
        4: "Message-ID: <first@example.invalid>\r\nMessage-ID: <last@example.invalid>\r\n\r\nbody",
        5: "Message-ID: =?UTF-8?Q?=3Cenc=40example.invalid=3E?=\r\n\r\nbody",
        7: "Subject: s\rMessage-ID: <cr@example.invalid>\r\rbody",
    ]

    private func makeRoot() throws -> URL {
        let pointer = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent("search682-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeIndex(at path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "SearchMessageIDHandlerTests", code: 1) }
        defer { sqlite3_close(db) }
        var sql = """
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, total_count INTEGER DEFAULT 0, unread_count INTEGER DEFAULT 0);
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, mailbox INTEGER,
          date_received INTEGER, read INTEGER DEFAULT 0, flagged INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0);
        INSERT INTO addresses VALUES (1, 'sender@example.invalid', 'Fixture');
        INSERT INTO mailboxes (ROWID, url) VALUES (1, 'imap://UUID-A/INBOX');
        """
        for row in 1...7 {
            sql += "INSERT INTO subjects VALUES (\(row), 'match \(row)');\n"
            sql += "INSERT INTO messages (ROWID, subject, sender, mailbox, date_received) VALUES (\(row), \(row), 1, 1, \(1000 + row));\n"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "SearchMessageIDHandlerTests", code: 2) }
    }

    private func makeServer(factory: (@Sendable () -> MessageIDLookup)? = nil) async throws -> (server: CheAppleMailMCPServer, root: URL) {
        let root = try makeRoot()
        let indexPath = root.appendingPathComponent("Envelope Index").path
        try writeIndex(at: indexPath)
        let storage = root.appendingPathComponent("Mail", isDirectory: true)
        let messagesDir = storage.appendingPathComponent("UUID-A/INBOX.mbox/5FCC6F13-2CE3-48B1-907D-686244C0229A/Data/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messagesDir, withIntermediateDirectories: true)
        for (row, text) in Self.messages {
            let bytes = Data(text.utf8)
            try (Data("\(bytes.count)\n".utf8) + bytes).write(to: messagesDir.appendingPathComponent("\(row).emlx"))
        }
        let previousStorage = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = storage.path
        addTeardownBlock { EnvelopeIndexReader.mailStoragePathOverride = previousStorage }
        let previousRoots = getenv("CHE_MAIL_EXPORT_ALLOWED_ROOTS").map { String(cString: $0) }
        setenv("CHE_MAIL_EXPORT_ALLOWED_ROOTS", root.path, 1)
        addTeardownBlock {
            if let previousRoots { setenv("CHE_MAIL_EXPORT_ALLOWED_ROOTS", previousRoots, 1) }
            else { unsetenv("CHE_MAIL_EXPORT_ALLOWED_ROOTS") }
        }
        await MailController.shared.setTestSeams(scriptRunner: { _ in
            throw MailError.operationFailed("SearchMessageIDHandlerTests: no Mail in this test")
        }, refusal: nil, scriptListRunner: { _ in
            throw MailError.operationFailed("SearchMessageIDHandlerTests: no Mail in this test")
        }, automationGranted: false)
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        let server = try await CheAppleMailMCPServer(
            databasePath: indexPath, initialSync: false,
            classificationDirectory: root.appendingPathComponent("classification", isDirectory: true),
            accountMapping: ["UUID-A": "Fixture"], messageIDLookupFactory: factory)
        return (server, root)
    }

    private func search(_ server: CheAppleMailMCPServer, _ extra: [String: Value] = [:]) async throws -> (raw: String, rows: [[String: Any]]) {
        var arguments: [String: Value] = ["query": .string("match"), "field": .string("subject"), "sort": .string("asc"), "limit": .int(20)]
        arguments.merge(extra) { _, new in new }
        let raw = try await server.executeToolCall(name: "search_emails", arguments: arguments)
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], raw)
        return (raw, try XCTUnwrap(envelope["results"] as? [[String: Any]], raw))
    }

    private func byID(_ rows: [[String: Any]]) -> [String: [String: Any]] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as? String ?? "", $0) })
    }

    // spec-example: sqlite-query-engine / The flag is off
    func testWithoutTheFlagRowsAreIdenticalAndNoFileIsRead() async throws {
        let reads = Reads(), listings = Reads(), built = Reads()
        let counting = countingFactory(reads, listings)
        let (server, _) = try await makeServer(factory: { built.add("built"); return counting() })
        for projection in ["full", "summary"] {
            let base = try await search(server, ["projection": .string(projection)])
            let explicitFalse = try await search(server, ["projection": .string(projection), "include_message_id": .bool(false)])
            let explicitNull = try await search(server, ["projection": .string(projection), "include_message_id": .null])
            XCTAssertEqual(base.raw, explicitFalse.raw, projection)
            XCTAssertEqual(base.raw, explicitNull.raw, projection)
            XCTAssertEqual(base.rows.count, 7, projection)
            XCTAssertTrue(base.rows.allSatisfy { $0["message_id"] == nil }, projection)
        }
        XCTAssertEqual(reads.count, 0, "no .emlx is read unless the flag is true")
        XCTAssertEqual(listings.count, 0, "no store folder is listed unless the flag is true")
        XCTAssertEqual(built.count, 0, "no lookup is even built unless the flag is true")
    }

    // spec-example: sqlite-query-engine / The value equals the one get_email reports
    func testTheValueEqualsWhatGetEmailAndTheExportReport() async throws {
        let (server, root) = try await makeServer()
        for projection in ["full", "summary"] {
            let rows = byID(try await search(server, ["projection": .string(projection), "include_message_id": .bool(true)]).rows)
            XCTAssertEqual(rows.count, 7, projection)
            for row in [1, 2, 3, 4, 5, 7] {
                let id = String(row)
                let viaGetEmail = try await server.executeToolCall(name: "get_email", arguments: ["id": .string(id)])
                let expected = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(viaGetEmail.utf8)) as? [String: Any])?["message_id"] as? String)
                XCTAssertEqual(rows[id]?["message_id"] as? String, expected, "\(projection) row \(row)")
            }
            XCTAssertEqual(rows["1"]?["message_id"] as? String, "<one@example.invalid>")
            XCTAssertEqual(rows["2"]?["message_id"] as? String, "", "no header is the empty string")
            XCTAssertEqual(rows["4"]?["message_id"] as? String, "<last@example.invalid>")
            XCTAssertNotNil(rows["6"], "a row whose file is missing is still returned")
            XCTAssertNil(rows["6"]?["message_id"], "and has no message_id key")
        }
        // The batch export's value for the same rows.
        let out = root.appendingPathComponent("out")
        let raw = try await server.executeToolCall(name: "batch_export_emails_markdown", arguments: [
            "ids": .array(["1", "3", "4", "5"].map { .string($0) }), "output_dir": .string(out.path)])
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], raw)
        let items = try XCTUnwrap(manifest["items"] as? [[String: Any]], raw)
        let searched = byID(try await search(server, ["include_message_id": .bool(true)]).rows)
        XCTAssertEqual(items.count, 4)
        for item in items {
            let id = try XCTUnwrap(item["id"] as? String)
            XCTAssertEqual(item["message_id"] as? String, searched[id]?["message_id"] as? String, "export row \(id)")
        }
    }

    func testOtherFieldsAreUnchangedWhenTheFlagIsOn() async throws {
        let (server, _) = try await makeServer()
        for projection in ["full", "summary"] {
            let off = byID(try await search(server, ["projection": .string(projection)]).rows)
            let on = byID(try await search(server, ["projection": .string(projection), "include_message_id": .bool(true)]).rows)
            XCTAssertEqual(Set(off.keys), Set(on.keys))
            for (id, row) in on {
                var rest = row
                rest.removeValue(forKey: "message_id")
                XCTAssertEqual(NSDictionary(dictionary: rest), NSDictionary(dictionary: off[id] ?? [:]), "\(projection) \(id)")
            }
        }
    }

    func testOneReadPerRowAndAnUnreadableRowIsReportedOncePerCall() async throws {
        let reads = Reads(), listings = Reads()
        let (server, _) = try await makeServer(factory: countingFactory(reads, listings, failing: "/3.emlx"))
        var rows: [String: [String: Any]] = [:]
        let stderr = try await capturingStderr {
            rows = self.byID(try await self.search(server, ["include_message_id": .bool(true)]).rows)
        }
        XCTAssertEqual(reads.count, 6, "row 6 has no file; the other six are each read once")
        XCTAssertEqual(listings.count, 1, "one mailbox, one store-folder listing")
        XCTAssertEqual(rows.count, 7)
        XCTAssertNil(rows["3"]?["message_id"])
        XCTAssertNil(rows["6"]?["message_id"])
        XCTAssertEqual(rows["1"]?["message_id"] as? String, "<one@example.invalid>")
        let lines = stderr.split(separator: "\n").filter { $0.contains("include_message_id") }
        XCTAssertEqual(lines.count, 1, stderr)
        XCTAssertTrue(lines[0].contains("2 of 7 row(s)"), stderr)
        XCTAssertFalse(stderr.contains("SECRET-HEADER-TEXT"), "no file text on stderr")
    }

    // spec-example: sqlite-query-engine / Projections without rows
    func testTheFlagIsRejectedForIdsAndCountAndWhenNotABoolean() async throws {
        let (server, _) = try await makeServer()
        for projection in ["ids", "count"] {
            await expectFailure(projection) { _ = try await self.search(server, ["projection": .string(projection), "include_message_id": .bool(true)]) }
            let fine = try await server.executeToolCall(name: "search_emails", arguments: [
                "query": .string("match"), "field": .string("subject"), "projection": .string(projection), "include_message_id": .bool(false)])
            XCTAssertFalse(fine.isEmpty)
        }
        for bad: Value in [.string("true"), .int(1), .array([]), .object([:])] {
            await expectFailure("\(bad)") { _ = try await self.search(server, ["include_message_id": bad]) }
        }
    }

    // A count mismatch must never drop or reorder a row.
    func testApplyMessageIDsKeepsEveryRowInOrder() {
        let rows: [[String: Any]] = [["id": "a"], ["id": "b"], ["id": "c"]]
        let full = CheAppleMailMCPServer.applyMessageIDs(rows, outcomes: [.value("<a>"), .unreadable(.noEmlx), .value("")])
        XCTAssertEqual(full.map { $0["id"] as? String }, ["a", "b", "c"])
        XCTAssertEqual(full.map { $0["message_id"] as? String }, ["<a>", nil, ""])
        let short = CheAppleMailMCPServer.applyMessageIDs(rows, outcomes: [.value("<a>")])
        XCTAssertEqual(short.map { $0["id"] as? String }, ["a", "b", "c"], "fewer outcomes than rows drops nothing")
        XCTAssertEqual(short.map { $0["message_id"] as? String }, ["<a>", nil, nil])
    }

    func testTheSchemaAndDescriptionDeclareTheFlag() throws {
        let tool: Tool = try XCTUnwrap(CheAppleMailMCPServer.defineTools().first(where: { $0.name == "search_emails" }))
        guard case .object(let schema) = tool.inputSchema,
              case .object(let properties)? = schema["properties"],
              case .object(let flag)? = properties["include_message_id"] else {
            return XCTFail("include_message_id is not in the search_emails input schema")
        }
        guard case .string(let type)? = flag["type"], case .string(let flagText)? = flag["description"] else {
            return XCTFail("include_message_id has no type or description")
        }
        XCTAssertEqual(type, "boolean")
        if case .array(let required)? = schema["required"] {
            XCTAssertFalse(required.contains(.string("include_message_id")))
        }
        for text in [tool.description ?? "", flagText] {
            XCTAssertTrue(text.contains("message_id"), text)
            XCTAssertTrue(text.contains("Not yet run against a real mail store"), "the outstanding live check is stated")
            XCTAssertTrue(text.contains("AppleScript fallback"), text)
            XCTAssertTrue(text.contains("4096 bytes"), text)
            XCTAssertTrue(text.contains("256 KiB"), text)
        }
    }

    private func expectFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                               _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("expected an error: \(message)", file: file, line: line) } catch {}
    }
}
