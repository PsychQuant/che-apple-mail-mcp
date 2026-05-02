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
}
