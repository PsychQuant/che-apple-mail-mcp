import XCTest
import MCP
@testable import CheAppleMailMCP

final class ComposeSignatureIntegrationTests: XCTestCase {
    func test_three_tools_share_signature_schema_and_description() throws {
        let tools = CheAppleMailMCPServer.defineTools()
        for name in ["compose_email", "create_draft", "update_draft"] {
            let tool = try XCTUnwrap(tools.first { $0.name == name })
            guard case .object(let root) = tool.inputSchema, case .object(let properties)? = root["properties"] else {
                return XCTFail("missing schema")
            }
            XCTAssertEqual(properties["signature"], ComposeSignatureSelection.schema)
            XCTAssertTrue(tool.description?.contains("Signature:") == true)
        }
    }

    func test_controller_passes_named_selection_and_discloses_receipt() async throws {
        let controller = MailController.shared
        let receipt = ComposeSignatureReceipt(mode: .named, selection: "Professional", selectionVerified: true, selectionApplied: true)
        let footer = ComposeSignatureReceipt.marker + (try JSONEncoder().encode(receipt).base64EncodedString()) + "]"
        await controller.setTestSeams(scriptRunner: { source in
            XCTAssertTrue(source.contains("signatureReceipt(\"named\""))
            XCTAssertTrue(source.contains("name is \"Professional\""))
            XCTAssertFalse(source.contains("set content"))
            return "Draft created successfully (mailto path)" + footer
        }, refusal: { nil })
        do {
            let result = try await controller.createDraft(to: ["a@example.invalid"], subject: "Title", body: "body only",
                                                         signature: .init(mode: .named, name: "Professional"))
            XCTAssertTrue(result.contains("signature_mode: named"))
            XCTAssertTrue(result.contains("signature_selection: \"Professional\""))
            XCTAssertTrue(result.contains("body_insertion_verified: false"))
            XCTAssertFalse(result.contains("signature-receipt:"))
            await controller.setTestSeams(scriptRunner: nil, refusal: nil)
        } catch {
            await controller.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
    }

    func test_missing_explicit_receipt_after_send_is_not_reported_as_safe_retry() async throws {
        let controller = MailController.shared
        await controller.setTestSeams(scriptRunner: { _ in "Email sent successfully (mailto path)" }, refusal: { nil })
        do {
            _ = try await controller.composeEmail(to: ["a@example.invalid"], subject: "Title", body: "body",
                                                  signature: .init(mode: .none))
            XCTFail("missing receipt")
        } catch {
            let text = error.localizedDescription.lowercased()
            XCTAssertTrue(text.contains("send") || text.contains("sent"), text)
            XCTAssertTrue(text.contains("retry") || text.contains("unknown"), text)
        }
        await controller.setTestSeams(scriptRunner: nil, refusal: nil)
    }
}
