import XCTest
import MCP
@testable import CheAppleMailMCP

final class ExportEmailsMarkdownToolSchemaTests: XCTestCase {

    private func tool(named name: String) -> Tool? {
        CheAppleMailMCPServer.defineTools().first { $0.name == name }
    }

    func testExportTool_registered() {
        XCTAssertNotNil(tool(named: "export_emails_markdown"),
                        "export_emails_markdown must be registered in defineTools()")
    }

    func testExportTool_requiredFields() throws {
        let t = try XCTUnwrap(tool(named: "export_emails_markdown"))
        guard case .object(let schema) = t.inputSchema,
              case .array(let requiredValues)? = schema["required"] else {
            return XCTFail("inputSchema must have a required array")
        }
        let required = requiredValues.compactMap { value -> String? in
            if case .string(let s) = value { return s }
            return nil
        }
        XCTAssertTrue(required.contains("ids"), "ids must be required")
        XCTAssertTrue(required.contains("output_dir"), "output_dir must be required")
    }

    func testExportTool_advertisesOptsAndIds() throws {
        let t = try XCTUnwrap(tool(named: "export_emails_markdown"))
        guard case .object(let schema) = t.inputSchema,
              case .object(let props)? = schema["properties"] else {
            return XCTFail("inputSchema must have properties")
        }
        XCTAssertNotNil(props["ids"])
        XCTAssertNotNil(props["output_dir"])
        XCTAssertNotNil(props["opts"])
    }
}
