import MCP
import XCTest
@testable import CheAppleMailMCP

/// #633: a handler given an address as `account_name` resolves it from the mapping the test passed
/// to `init`. The addresses end in `.invalid`, so no machine's AccountsMap.plist can hold them: a
/// pass here cannot come from the developer's accounts.
///
/// Nothing reaches Mail: the script seam records the script and throws.
final class HandlerAccountMappingTests: XCTestCase {
    private final class Scripts: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func add(_ script: String) { lock.lock(); seen.append(script); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    private func makeServer(mapping: [String: String]) async throws -> (CheAppleMailMCPServer, Scripts) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handler633-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let scripts = Scripts()
        await MailController.shared.setTestSeams(scriptRunner: { script in
            scripts.add(script)
            throw MailError.operationFailed("HandlerAccountMappingTests: no Mail in this test")
        }, refusal: nil, scriptListRunner: { script in
            scripts.add(script)
            throw MailError.operationFailed("HandlerAccountMappingTests: no Mail in this test")
        }, automationGranted: false)
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        let server = try await CheAppleMailMCPServer(
            databasePath: root.appendingPathComponent("no-index").path, initialSync: false,
            classificationDirectory: root.appendingPathComponent("classification", isDirectory: true),
            accountMapping: mapping)
        return (server, scripts)
    }

    private func markRead(_ server: CheAppleMailMCPServer, accountName: String) async throws -> String {
        try await server.executeToolCall(name: "mark_read", arguments: [
            "id": .string("1"), "mailbox": .string("INBOX"),
            "account_name": .string(accountName), "read": .bool(true),
        ])
    }

    func testAnAddressResolvesFromTheInjectedMapping() async throws {
        let (server, scripts) = try await makeServer(mapping: ["UUID-A": "a@example.invalid"])
        _ = try? await markRead(server, accountName: "A@EXAMPLE.INVALID")
        XCTAssertFalse(scripts.all.isEmpty, "the handler stopped before reaching the script seam")
        XCTAssertTrue(scripts.all.contains { $0.contains(#"account id "UUID-A""#) }, "\(scripts.all)")
    }

    func testAnAddressHeldByTwoAccountsIsRefusedNamingBoth() async throws {
        let (server, scripts) = try await makeServer(mapping: ["UUID-B": "dup@example.invalid",
                                                               "UUID-C": "dup@example.invalid"])
        do {
            _ = try await markRead(server, accountName: "dup@example.invalid")
            XCTFail("an ambiguous address must not pick an account")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("mark_read"), message)
            XCTAssertTrue(message.contains("matches multiple Mail accounts"), message)
            XCTAssertTrue(message.contains("UUID-B, UUID-C"), message)
        }
        XCTAssertTrue(scripts.all.isEmpty, "no script may run for an ambiguous address: \(scripts.all)")
    }

    func testAnAddressTheMappingDoesNotHoldStaysAnAccountName() async throws {
        let (server, scripts) = try await makeServer(mapping: ["UUID-A": "a@example.invalid"])
        _ = try? await markRead(server, accountName: "nobody@example.invalid")
        XCTAssertFalse(scripts.all.isEmpty, "the handler stopped before reaching the script seam")
        XCTAssertFalse(scripts.all.contains { $0.contains("account id") }, "\(scripts.all)")
        XCTAssertTrue(scripts.all.contains { $0.contains(#"account "nobody@example.invalid""#) }, "\(scripts.all)")
    }
}
