import XCTest
import MCP
@testable import CheAppleMailMCP

/// #465 — task 4.1. The brief output's whole promise is that it **cannot**
/// carry account names, subjects, recipients, Message-IDs or document UUIDs.
/// This guard runs the fixtures — whose `%@` slots are stuffed with exactly
/// those things — through the real pipeline (parse → extract → alias →
/// serialize) and checks the bytes that would be sent.
final class BriefOutputNoIdentifierGuardTests: XCTestCase {

    /// Values planted in `identifiers.ndjson` / `recon463.ndjson`. None may appear.
    private let planted = [
        "alice.fixture", "bob.fixture", "account-one", "account-two", "FIXTURE-MSGID-77", "fixture-1@",
        "Fixture Secret Subject", "7F3A9C52-1B4E-4C8D-9A21-0E5D6F7A8B9C", "7F3A9C52-1B4E-4C8D-9A21-0E5D6F7A8B9D",
        "00000000-0000-4000-8000-000000000001", "example.invalid",
        "- Drafts]", "- Inbox]",      // mailbox names live in the %@ prefix ("Drafts" alone is also a legitimate CATEGORY name)
        "1695", "902", "903",         // numbers inside the APPENDUID text are content, not args
    ]

    private func briefOutput(fixtures: [String]) async throws -> String {
        var lines: [Data] = []
        for name in fixtures { lines += try MailLogFixtures.lines(name) }
        // The fixtures are 12:42–12:50 on 2026-10-02 (+08:00); ask for that whole hour.
        let args: [String: Value] = ["since": .string("2026-10-02T12:00:00+08:00"), "until": .string("2026-10-02T13:00:00+08:00")]
        return try await MailLogTool.handle(arguments: args, source: FakeLogSource(lines: lines),
                                            now: Date(timeIntervalSince1970: 1790919600),
                                            timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
    }

    func testPlantedIdentifiersNeverAppearInBriefOutput() async throws {
        let out = try await briefOutput(fixtures: ["recon463.ndjson", "identifiers.ndjson"])
        XCTAssertTrue(out.contains("\"returned\":12"), "sanity: all 12 fixture events came through the pipeline — \(out.prefix(300))")
        for value in planted {
            XCTAssertFalse(out.contains(value), "brief output leaked \(value.debugDescription)")
        }
    }

    func testNoEmailUUIDOrMessageIDShapeAppearsInBriefOutput() async throws {
        let out = try await briefOutput(fixtures: ["recon463.ndjson", "identifiers.ndjson"])
        let shapes: [(String, String)] = [
            ("email", #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#),
            ("uuid", #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#),
            ("message-id", #"<[^<>\s@]+@[^<>\s]+>"#),
            ("home path", #"/Users/[A-Za-z0-9._\-]+"#),
        ]
        for (name, pattern) in shapes {
            let re = try NSRegularExpression(pattern: pattern)
            XCTAssertNil(re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)), "\(name) shape in brief output")
        }
    }

    /// Detailed mode is the contrast: the same input DOES carry them (that is
    /// its declared purpose). If this ever stops being true the brief guard
    /// above would be passing vacuously.
    func testTheGuardIsNotVacuous_detailedModeDoesCarryThePlantedValues() async throws {
        var lines: [Data] = []
        for name in ["recon463.ndjson", "identifiers.ndjson"] { lines += try MailLogFixtures.lines(name) }
        let args: [String: Value] = ["detail": .string("detailed"),
                                     "since": .string("2026-10-02T12:00:00+08:00"), "until": .string("2026-10-02T13:00:00+08:00")]
        let out = try await MailLogTool.handle(arguments: args, source: FakeLogSource(lines: lines),
                                               now: Date(timeIntervalSince1970: 1790919600),
                                               timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        XCTAssertTrue(out.contains("alice.fixture"))
        XCTAssertTrue(out.contains("Fixture Secret Subject"))
    }

    func testEveryBriefEventValueIsEitherATemplateAnIntegerOrAnAlias() async throws {
        let out = try await briefOutput(fixtures: ["recon463.ndjson", "identifiers.ndjson"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let allowedKeys: Set<String> = ["time", "subsystem", "category", "event", "kind", "args", "activity", "account"]
        for event in Synthetic.results(object) {
            XCTAssertEqual(Set(event.keys), allowedKeys)
            for arg in (event["args"] as? [Any]) ?? [] {
                XCTAssertTrue(arg is Int || arg is NSNull, "args may hold only integers or null, got \(arg)")
            }
            if let account = event["account"] as? String {
                XCTAssertNotNil(account.range(of: "^[A-Z]{1,3}$", options: .regularExpression), "account must be an alias, got \(account)")
            }
        }
    }

    func testSubstringProbingOfBriefOutputIsRefused() async {
        let source = FakeLogSource(lines: [Synthetic.line(offset: 0)])
        do {
            _ = try await MailLogTool.handle(arguments: ["contains": .string("alice.fixture@")], source: source)
            XCTFail("contains must be refused in brief")
        } catch {
            XCTAssertTrue(source.requests.isEmpty)
        }
    }
}
