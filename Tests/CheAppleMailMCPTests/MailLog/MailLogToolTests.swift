import XCTest
import MCP
@testable import CheAppleMailMCP

/// #465 — task 3.5: tool definition and handler.
final class MailLogToolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1790916206)

    private func call(_ args: [String: Value], source: FakeLogSource = FakeLogSource()) async throws -> [String: Any] {
        let text = try await MailLogTool.handle(arguments: args, source: source, now: now, timeZone: Synthetic.taipei)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: definition

    func testToolIsRegisteredInDefineTools() {
        let names = CheAppleMailMCPServer.defineTools().map(\.name)
        XCTAssertEqual(names.filter { $0 == "get_mail_log_events" }.count, 1)
    }

    func testDescriptionCarriesTheRequiredWarningsAndCaveats() {
        let d = (MailLogTool.definition.description ?? "").lowercased()
        XCTAssertTrue(d.contains("account identifiers"), "detailed-mode sensitivity warning")
        XCTAssertTrue(d.contains("public issues"), "do-not-paste warning")
        XCTAssertTrue(d.contains("27.2"), "verified version")
        XCTAssertTrue(d.contains("mcpb"), "unverified launch context")
        XCTAssertTrue(d.contains("non-admin"), "unverified user context")
        XCTAssertTrue(d.contains("never means"), "empty result must not read as 'did not happen'")
    }

    /// Claude Code truncates each tool description at 2,048 characters (code.claude.com/docs/en/mcp,
    /// "Claude Code truncates each tool description and each server's instructions at 2,048
    /// characters by default"). The first version was 2,248 and the cut fell on the
    /// deferred-live-verification caveat. Everything that must reach the model has to fit.
    func testDescriptionFitsTheHostsTruncationLimit_andCarriesWhatMustSurvive() {
        let d = MailLogTool.definition.description ?? ""
        XCTAssertLessThanOrEqual(d.count, 2048, "description is \(d.count) characters")
        let lower = d.lowercased()
        for needle in ["account identifiers", "public issues", "27.2", "mcpb", "non-admin", "never means", "not instructions", "#466", "until", "next_start", "next_offset"] {
            XCTAssertTrue(lower.contains(needle), "description lost: \(needle)")
        }
    }

    func testSchemaListsExactlyTheParametersTheValidatorAccepts() throws {
        guard case .object(let schema) = MailLogTool.definition.inputSchema,
              case .object(let properties)? = schema["properties"] else { return XCTFail("no properties") }
        XCTAssertEqual(Set(properties.keys), MailLogQuery.allowedParameters)
    }

    func testDetailedOnlyParametersSayTheyAreDetailedOnly() throws {
        guard case .object(let schema) = MailLogTool.definition.inputSchema,
              case .object(let properties)? = schema["properties"] else { return XCTFail("no properties") }
        for name in ["contains", "redact_identifiers"] {
            guard case .object(let p)? = properties[name], case .string(let text)? = p["description"] else { return XCTFail(name) }
            XCTAssertTrue(text.contains("detailed"), "\(name) must say it is only available with detail=detailed")
        }
    }

    // MARK: handler

    func testDefaultCall_readsTheLast10Minutes() async throws {
        // `now` is base + 2606 s, so the default window is [base + 2006, base + 2606]
        let source = FakeLogSource(lines: [Synthetic.line(offset: 2300)])
        let r = try await call([:], source: source)
        XCTAssertEqual(r["status"] as? String, "ok")
        XCTAssertEqual(r["detail"] as? String, "brief")
        XCTAssertEqual(r["limit"] as? Int, 200)
        XCTAssertEqual(source.requests.first?.end.timeIntervalSince1970, 1790916206)
        XCTAssertEqual(source.requests.first?.start.timeIntervalSince1970, 1790916206 - 600)
    }

    func testInvalidParametersFailBeforeTheSourceIsTouched() async {
        let bad: [[String: Value]] = [
            ["since": .string("2026-10-02 12:40:00")],
            ["contains": .string("x")],
            ["last_minutes": .int(5), "around": .string("2026-10-02T12:42:26+08:00")],
            ["limit": .int(0)],
            ["nonsense": .bool(true)],
        ]
        for args in bad {
            let source = FakeLogSource(lines: [Synthetic.line(offset: 0)])
            do {
                _ = try await MailLogTool.handle(arguments: args, source: source, now: now, timeZone: Synthetic.taipei)
                XCTFail("expected an error for \(args)")
            } catch {
                XCTAssertTrue(source.requests.isEmpty, "the log reader must not be started for \(args)")
            }
        }
    }

    func testOutputIsCompactJSONWithinTheByteCap() async throws {
        let big = String(repeating: "/x", count: 4000)
        let source = FakeLogSource(lines: (0..<200).map { Synthetic.line(offset: Double($0), message: big) })
        let window: [String: Value] = ["since": .string("2026-10-02T12:00:00+08:00"), "until": .string("2026-10-02T12:10:00+08:00")]
        let text = try await MailLogTool.handle(arguments: window.merging(["detail": .string("detailed"), "limit": .int(1000)]) { a, _ in a },
                                                source: source, now: now, timeZone: Synthetic.taipei)
        XCTAssertLessThanOrEqual(text.utf8.count, MailLogService.responseByteCap,
                                 "what is returned must be exactly what was measured against the cap")
        XCTAssertFalse(text.contains("\n"), "compact: pretty-printing would inflate the payload")
    }

    // MARK: guards

    /// "Tool never touches Mail state": the MailLog module must not reach for
    /// AppleScript, the Envelope Index, or any file-writing API.
    func testMailLogSourcesNeverTouchMailState() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/MailLog")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThanOrEqual(files.count, 10)
        let banned = ["NSAppleScript", "osascript", "MailController", "EnvelopeIndexReader", "sqlite3_",
                      "createFile", "removeItem", ".write(to", "standardError.write", "System Events"]
        for file in files {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            // Strip comments so prose that NAMES a banned thing does not trip the scan.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for token in banned {
                XCTAssertFalse(code.contains(token), "\(file) uses \(token)")
            }
        }
    }

    func testServerDispatchesTheTool() throws {
        let server = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/Server.swift")
        let text = try String(contentsOf: server, encoding: .utf8)
        XCTAssertTrue(text.contains(#"case "get_mail_log_events":"#))
        XCTAssertTrue(text.contains("MailLogTool.handle("))
        XCTAssertTrue(text.contains("MailLogTool.definition"))
    }
}
