import XCTest
import MCP
@testable import CheAppleMailMCP

final class MailtoLengthTests: XCTestCase {
    func test_exact_measurement_matches_builder_for_unicode_and_optional_fields() {
        for body in ["ASCII", "中文", "👩‍👩‍👧‍👦", "e\u{301}", "\r\n", "a&b?c%", String(repeating: "中", count: 1279)] {
            for cc: [String]? in [nil, [], ["cc@example.invalid"], ["a@example.invalid", "b@example.invalid"]] {
                let report = measureMailtoURL(to: ["to@example.invalid"], subject: "Subject 中文", body: body,
                                             cc: cc, bcc: ["bcc@example.invalid"])
                XCTAssertEqual(report.encodedURLLength, buildMailtoURL(to: ["to@example.invalid"], subject: "Subject 中文", body: body, cc: cc, bcc: ["bcc@example.invalid"]).count)
                XCTAssertEqual(report.bodyEncodedLength, mailtoEncode(body).count)
                XCTAssertEqual(report.otherEncodedLength + report.bodyEncodedLength, report.encodedURLLength)
            }
        }
    }
    func test_preflight_uses_actual_recipient_partition() {
        let to = ["Person <person@example.invalid>", "bare@example.invalid"]
        let cc = ["Cc Person <cc@example.invalid>"]
        let bcc = ["bcc@example.invalid"]
        let report = composeLengthPreflight(to: to, subject: "Title", body: "正文", cc: cc, bcc: bcc)
        let partition = partitionRecipientsForMailto(to: to, cc: cc, bcc: bcc)
        XCTAssertEqual(report.encodedURLLength, buildMailtoURL(to: partition.urlTo, subject: "Title", body: "正文", cc: partition.urlCc, bcc: partition.urlBcc).count)
        XCTAssertFalse(report.otherRequirementsChecked)
    }
    func test_exact_limit_and_overhead_only_overflow() {
        let overhead = measureMailtoURL(to: ["a@b.c"], subject: "S", body: "").encodedURLLength
        let atLimit = composeLengthPreflight(to: ["a@b.c"], subject: "S", body: String(repeating: "x", count: 8000-overhead))
        XCTAssertTrue(atLimit.fits)
        XCTAssertEqual(atLimit.remaining, 0)
        let over = composeLengthPreflight(to: ["a@b.c"], subject: "S", body: String(repeating: "x", count: 8001-overhead))
        XCTAssertFalse(over.fits)
        XCTAssertEqual(over.remaining, -1)
        XCTAssertNotNil(over.refusal)
        let header = composeLengthPreflight(to: ["a@b.c"], subject: String(repeating: "中", count: 1000), body: "")
        XCTAssertFalse(header.fits)
        XCTAssertEqual(header.bodyEncodedLength, 0)
        XCTAssertTrue(header.refusal!.message.contains("MAILTO_URL_TOO_LONG"))
        XCTAssertTrue(header.refusal!.message.contains("Removing the body alone will not fit"))
    }
    func test_all_ascii_bytes_and_mixed_graphemes_match_encoder() {
        let ascii = String(String.UnicodeScalarView((0..<128).compactMap(UnicodeScalar.init)))
        for value in [ascii, "👨‍👩‍👧‍👦é漢字\r\n%?&=", String(repeating: "ASCII 中文 🧑🏽‍💻", count: 100)] {
            XCTAssertEqual(measureMailtoURL(to: [], subject: value, body: value, cc: [], bcc: []).encodedURLLength,
                           buildMailtoURL(to: [], subject: value, body: value, cc: [], bcc: []).count)
        }
    }

    func test_read_only_tool_dispatch_returns_exact_stats_without_mail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let server = try await CheAppleMailMCPServer(databasePath: root.appendingPathComponent("missing.sqlite").path,
                                                    initialSync: false, classificationDirectory: root)
        let tool = try XCTUnwrap(CheAppleMailMCPServer.defineTools().first { $0.name == "check_compose_length" })
        XCTAssertEqual(tool.annotations.readOnlyHint, true)
        let raw = try await server.executeToolCall(name: "check_compose_length", arguments: [
            "to": .array([.string("a@example.invalid")]), "subject": .string("S"), "body": .string(String(repeating: "中", count: 1000))])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(object["fits"] as? Bool, false)
        XCTAssertEqual(object["body_encoded_length"] as? Int, 9000)
        XCTAssertEqual(object["other_requirements_checked"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func test_long_compose_create_update_never_reach_mail_or_gui() async throws {
        let controller = MailController.shared
        await controller.setTestSeams(scriptRunner: { _ in XCTFail("must fail before any script"); return "" }, refusal: { nil })
        let body = String(repeating: "中", count: 1000)
        do {
            for kind in 0..<3 {
                do {
                    if kind == 0 { _ = try await controller.composeEmail(to: ["a@example.invalid"], subject: "S", body: body) }
                    if kind == 1 { _ = try await controller.createDraft(to: ["a@example.invalid"], subject: "S", body: body) }
                    if kind == 2 { _ = try await controller.updateDraft(draftId: "1", subjectMatch: nil, accountName: "A", accountId: nil, to: ["a@example.invalid"], subject: "S", body: body) }
                    XCTFail("expected named length refusal")
                } catch MailError.invalidParameter(let text) {
                    XCTAssertTrue(text.contains("MAILTO_URL_TOO_LONG"))
                    XCTAssertTrue(text.contains("8000"))
                    XCTAssertTrue(text.contains("9000"))
                    XCTAssertTrue(text.contains("manually paste"))
                }
            }
            await controller.setTestSeams(scriptRunner: nil, refusal: nil)
        } catch {
            await controller.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
    }
}
