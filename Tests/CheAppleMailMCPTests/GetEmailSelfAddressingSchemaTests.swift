import XCTest
import MCP
@testable import CheAppleMailMCP

/// #299 schema contract guard: `get_email` addresses a message from its rowId
/// alone. Re-adding `mailbox` / `account_name` to `required` would silently
/// re-break the body-materialization recovery loop — the flagged ids come from
/// an export manifest / a search `summary`|`ids` projection, none of which
/// return an account, so a required account is a value the caller cannot supply.
final class GetEmailSelfAddressingSchemaTests: XCTestCase {

    private func tool(named name: String) -> Tool? {
        CheAppleMailMCPServer.defineTools().first { $0.name == name }
    }

    private func requiredFields(of t: Tool) throws -> [String] {
        guard case .object(let schema) = t.inputSchema,
              case .array(let requiredValues)? = schema["required"] else {
            throw XCTSkip("inputSchema must have a required array")
        }
        return requiredValues.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    private func properties(of t: Tool) throws -> [String: Value] {
        guard case .object(let schema) = t.inputSchema,
              case .object(let props)? = schema["properties"] else {
            throw XCTSkip("inputSchema must have properties")
        }
        return props
    }

    /// The contract: `id` is the ONLY required field.
    func testGetEmail_requiresIdOnly() throws {
        let t = try XCTUnwrap(tool(named: "get_email"))
        let required = try requiredFields(of: t)
        XCTAssertEqual(required, ["id"],
                       "#299: a rowId is self-addressing — mailbox/account_name must stay optional; got \(required)")
    }

    /// The optional selectors must still be advertised (they remain the
    /// explicit-override path and keep pre-#299 behavior byte-for-byte).
    func testGetEmail_stillAdvertisesOptionalSelectors() throws {
        let t = try XCTUnwrap(tool(named: "get_email"))
        let props = try properties(of: t)
        for key in ["id", "mailbox", "account_name", "account_id", "format"] {
            XCTAssertNotNil(props[key], "\(key) must remain advertised")
        }
    }

    /// A caller reading only the schema must learn that omitting the pair is
    /// legitimate — otherwise the affordance exists but nobody uses it, and the
    /// recovery loop stays broken in practice.
    func testGetEmail_documentsOptionality() throws {
        let t = try XCTUnwrap(tool(named: "get_email"))
        let props = try properties(of: t)
        func description(_ key: String) -> String {
            guard case .object(let o)? = props[key], case .string(let d)? = o["description"] else { return "" }
            return d
        }
        XCTAssertTrue(description("mailbox").lowercased().contains("optional"),
                      "mailbox description must state it is optional (#299)")
        XCTAssertTrue(description("account_name").lowercased().contains("optional"),
                      "account_name description must state it is optional (#299)")
        XCTAssertTrue(description("mailbox").contains("#299"),
                      "the optionality must be traceable to its issue")
    }

    /// `get_emails_batch` is deliberately NOT relaxed: its `id`+`mailbox`+
    /// `account_name` requirement is a frozen clause in the batch-operations
    /// spec, so relaxing it needs a spec amendment, not a code change (#299
    /// scoping). Pinned so a future sweep doesn't "helpfully" widen the change.
    func testBatchTool_requirementDeliberatelyUnchanged() throws {
        let t = try XCTUnwrap(tool(named: "get_emails_batch"))
        let required = try requiredFields(of: t)
        XCTAssertTrue(required.contains("emails"),
                      "get_emails_batch keeps its own contract; #299 scoped itself to get_email")
    }
}
