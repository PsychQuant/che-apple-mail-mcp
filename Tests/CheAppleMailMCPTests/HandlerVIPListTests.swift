import MCP
import SQLite3
import XCTest
@testable import CheAppleMailMCP

/// #656: `list_vip_senders` over a server built with a VIP list path reads only that file, so a
/// handler test does not depend on the developer's VIP list. The index is a throwaway SQLite file
/// (the reader only needs one it can read), and the account mapping is injected so the reader does
/// not read AccountsMap.plist either. Nothing reaches Mail.
final class HandlerVIPListTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handler656-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeIndex(at path: String) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(path, &db) == SQLITE_OK,
              sqlite3_exec(db, "CREATE TABLE messages (ROWID INTEGER PRIMARY KEY)", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "HandlerVIPListTests", code: 1)
        }
    }

    // spec-example: sqlite-query-engine / list_vip_senders answers from the server's VIP list path
    func testListVipSendersAnswersFromTheServersVIPListPath() async throws {
        let root = try makeRoot()
        let index = root.appendingPathComponent("Envelope Index").path
        try writeIndex(at: index)
        let vip = root.appendingPathComponent("VIPMailboxes.plist")
        try PropertyListSerialization.data(fromPropertyList: [["address": "vip@example.invalid"]], format: .xml, options: 0)
            .write(to: vip)
        let server = try await CheAppleMailMCPServer(
            databasePath: index, initialSync: false,
            classificationDirectory: root.appendingPathComponent("classification", isDirectory: true),
            accountMapping: [:], vipMailboxesPath: vip.path)
        let text = try await server.executeToolCall(name: "list_vip_senders", arguments: [:])
        let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: String]]
        XCTAssertEqual(decoded, [["address": "vip@example.invalid"]], text)
    }
}
