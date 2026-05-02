import XCTest
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
}
