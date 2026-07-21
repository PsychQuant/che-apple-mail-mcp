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

    func testExportTool_advertisesSkipPartialOpt() throws {
        // #283 (mirrors the #177 skip_message_ids_path precedent, one level
        // deeper): the new opt-in flag must be advertised under
        // opts.properties as a boolean — a schema/handler key-name typo would
        // otherwise ship silently (the caller's opts.skip_partial would no-op
        // back to default annotate-and-write).
        let t = try XCTUnwrap(tool(named: "batch_export_emails_markdown"))
        guard case .object(let schema) = t.inputSchema,
              case .object(let props)? = schema["properties"],
              case .object(let opts)? = props["opts"],
              case .object(let optProps)? = opts["properties"] else {
            return XCTFail("inputSchema must expose opts.properties")
        }
        guard case .object(let skipPartial)? = optProps["skip_partial"] else {
            return XCTFail("opts.properties must advertise skip_partial (#283)")
        }
        XCTAssertEqual(skipPartial["type"], .string("boolean"))
        // The description must scope the re-fetch recipe to skip_partial=true —
        // following it under default annotate-and-write mode produces a stale
        // header-only .md PLUS a -N-suffixed duplicate (#283 verify,
        // consumer-lens empirical finding).
        guard case .string(let desc)? = skipPartial["description"] else {
            return XCTFail("skip_partial must carry a description")
        }
        XCTAssertTrue(desc.contains("skip_partial:true") || desc.contains("With skip_partial:true"),
                      "the re-export recipe must be explicitly scoped to skip_partial:true")
        XCTAssertTrue(desc.contains("written_path"),
                      "default-mode guidance must name the stale-file cleanup via written_path")
    }

    // MARK: - #233 batch_export_emails_markdown canonical name + deprecated alias

    func testBatchAlias_bothNamesRegistered() {
        XCTAssertNotNil(tool(named: "batch_export_emails_markdown"),
                        "canonical name must be registered (#233)")
        XCTAssertNotNil(tool(named: "export_emails_markdown"),
                        "deprecated alias must stay registered until v3.0 (#233)")
    }

    func testBatchAlias_identicalInputSchema() throws {
        // The two registrations MUST NOT diverge — same handler, same schema.
        let canonical = try XCTUnwrap(tool(named: "batch_export_emails_markdown"))
        let alias = try XCTUnwrap(tool(named: "export_emails_markdown"))
        XCTAssertEqual(canonical.inputSchema, alias.inputSchema,
                       "canonical and alias input schemas must be deep-equal (#233)")
    }

    func testBatchAlias_descriptionContract() throws {
        let canonicalDesc = try XCTUnwrap(tool(named: "batch_export_emails_markdown")?.description)
        let aliasDesc = try XCTUnwrap(tool(named: "export_emails_markdown")?.description)
        XCTAssertTrue(aliasDesc.hasPrefix("DEPRECATED — renamed to batch_export_emails_markdown"),
                      "alias description must lead with the deprecation prefix (#233): \(aliasDesc.prefix(120))")
        XCTAssertTrue(aliasDesc.contains("v3.0"),
                      "alias description must state the removal gate (#233)")
        XCTAssertFalse(canonicalDesc.contains("DEPRECATED"),
                       "canonical description must not be marked deprecated (#233)")
        XCTAssertTrue(canonicalDesc.hasPrefix("Export a batch of emails"),
                      "canonical carries the full (non-deprecated) description (#233)")
    }

    func testBatchAlias_deprecationWarnMessage_singleLineNamingCanonical() {
        let msg = exportAliasDeprecationWarning()
        XCTAssertTrue(msg.contains("export_emails_markdown"), msg)
        XCTAssertTrue(msg.contains("batch_export_emails_markdown"), msg)
        XCTAssertEqual(msg.filter { $0 == "\n" }.count, 1,
                       "warn must be exactly one stderr line (single trailing newline): \(msg.debugDescription)")
    }

    func testBatchAlias_dispatchSharesOneCaseLabel() throws {
        // Source guard: both names must dispatch through the SAME case label so
        // the handlers can never diverge (#233).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/Server.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            source.contains("case \"export_emails_markdown\", \"batch_export_emails_markdown\":"),
            "dispatch must use one dual-name case label (#233)")
    }
}
