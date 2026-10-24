import XCTest
@testable import CheAppleMailMCP
@testable import MailSQLite

/// The Swift half of the repair command's Message-ID spelling fixture (#529).
///
/// `/archive-mail-repair-synthetic-ids` re-keys a file with the Message-ID that `get_email_headers` returns, and that
/// key has to be spelled exactly as a later batch export spells it, because `skipMessageIds` is an exact string
/// match. The SOP's recipe works out the spelling from the raw header text; this file pins the other side, the real
/// `RFC822Parser` and the real export, against the same list of cases the Python suite
/// (`plugin/tests/test-archive-mail-repair-recipes.py`) runs the recipe on.
///
/// What each test can and cannot tell you:
/// - The oracle test is a characterization test. It is green the day it is written; it turns red when Foundation's
///   `.whitespaces` / `.newlines` / string replacement semantics change, or when someone edits the parser. Read the
///   failure as "the parser now stores something else", then decide whether the fixture or the parser is wrong.
/// - The round trip covers only cases the recipe calls `ok`. It cannot say anything about a case the recipe refuses.
/// - The fixture was measured against both SDK stamps (the shipped binary is stamped sdk 13.0, `xctest` sdk 27.0, #561);
///   every case agreed. This file runs under `xctest`, so it would not notice a future divergence between the two.
final class RepairMessageIDSpellingFixtureTests: XCTestCase {

    private struct RecipeAnswer: Decodable {
        let status: String
        let comparison: String?
        let stored: String?
        let reason: String?
    }

    private struct FixtureCase: Decodable {
        let id: String
        let category: String
        let raw: String
        let swiftStored: String
        let recipe: RecipeAnswer
    }

    private struct Fixture: Decodable {
        let categories: [String]
        let trimmedCharacters: [UInt32]
        let newlineCharacters: [UInt32]
        let cases: [FixtureCase]
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CheAppleMailMCPTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("plugin/tests/fixtures/repair-message-id-spelling.json")

    /// Decoded with `JSONDecoder`, not `JSONSerialization`: the latter silently drops a U+FEFF at the start of a string
    /// value, which is exactly what the `outer-byte-order-mark-after-colon` case stores.
    private func loadFixture() throws -> Fixture {
        let path = Self.fixtureURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail("fixture file is missing: \(path)")
            throw CocoaError(.fileNoSuchFile)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL))
    }

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("idd529-spelling-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func parsedMessageID(_ raw: String) -> String {
        RFC822Parser.parseHeaders(from: Data(raw.utf8))["message-id"] ?? ""
    }

    private func export(_ messageId: String, skipping skip: Set<String>, to output: URL) throws -> ExportManifest {
        try ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: output, ownAddresses: [], fallbackDirection: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:], extraFrontmatter: [],
            fetch: { _ in
                EmailContent(
                    subject: "Topic", sender: "fixture@example.invalid", toRecipients: ["to@example.invalid"],
                    ccRecipients: [], date: "Sat, 13 Jun 2026 16:01:14 +0800", messageId: messageId, inReplyTo: "",
                    textBody: "body", htmlBody: nil, rawSource: nil, fromPartialEmlx: false)
            },
            attachmentNamesFor: { _ in [] }, attachmentData: { _, _ in Data() }, skipMessageIds: skip)
    }

    // MARK: - The fixture itself

    func testEveryCategoryHasCasesAndEveryCaseNamesAListedCategory() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(Set(fixture.cases.map(\.category)), Set(fixture.categories),
                       "a category lost all its cases, or a case invented one")
        XCTAssertEqual(Set(fixture.cases.map(\.id)).count, fixture.cases.count, "duplicate case id")
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 50, "the fixture shrank")
    }

    // MARK: - Oracle: what the real parser stores

    func testParserStoresWhatTheFixtureRecordsForEveryCase() throws {
        for fixtureCase in try loadFixture().cases {
            XCTAssertEqual(parsedMessageID(fixtureCase.raw), fixtureCase.swiftStored,
                           "case \(fixtureCase.id): RFC822Parser.parseHeaders stores something else")
        }
    }

    func testTheRecipeAndTheParserAgreeOnEveryUsableCase() throws {
        var usable = 0
        for fixtureCase in try loadFixture().cases where fixtureCase.recipe.status == "ok" {
            usable += 1
            XCTAssertEqual(fixtureCase.recipe.stored, parsedMessageID(fixtureCase.raw),
                           "case \(fixtureCase.id): the recipe would key the file differently from a batch export")
            let stored = try XCTUnwrap(fixtureCase.recipe.stored)
            let comparison = try XCTUnwrap(fixtureCase.recipe.comparison)
            XCTAssertEqual(comparison, stored.hasPrefix("<") ? String(stored.dropFirst().dropLast()) : stored,
                           "case \(fixtureCase.id): comparison value is not the stored value minus one pair of brackets")
        }
        XCTAssertGreaterThanOrEqual(usable, 15)
    }

    // MARK: - Round trip through the real export

    func testUsableCasesRoundTripToTheExactSkipKeyAndNoOtherSpellingMatches() throws {
        for fixtureCase in try loadFixture().cases where fixtureCase.recipe.status == "ok" {
            let stored = parsedMessageID(fixtureCase.raw)
            let comparison = try XCTUnwrap(fixtureCase.recipe.comparison)
            let directory = tempDir()

            let written = try export(stored, skipping: [], to: directory)
            XCTAssertEqual(written.written, 1, "case \(fixtureCase.id)")
            XCTAssertEqual(written.items[0].messageId, stored, "case \(fixtureCase.id)")
            let path = try XCTUnwrap(written.items[0].writtenPath, "case \(fixtureCase.id)")
            let markdown = try String(contentsOfFile: path)
            XCTAssertTrue(markdown.contains("message_id: \"\(stored)\"\n"),
                          "case \(fixtureCase.id): frontmatter does not carry the stored value verbatim")

            let skipped = try export(stored, skipping: [stored], to: directory)
            XCTAssertEqual(skipped.skipped, 1, "case \(fixtureCase.id): the stored value must be the exact skip key")
            XCTAssertEqual(skipped.written, 0, "case \(fixtureCase.id)")

            if comparison != stored {
                let wrongKey = try export(stored, skipping: [comparison], to: tempDir())
                XCTAssertEqual(wrongKey.skipped, 0,
                               "case \(fixtureCase.id): the comparison value must not masquerade as the stored key")
                XCTAssertEqual(wrongKey.written, 1, "case \(fixtureCase.id)")
            }
        }
    }

    // MARK: - Character sets the recipe spells out

    func testTrimmedCharactersAreExactlyFoundationWhitespaces() throws {
        let fixture = try loadFixture()
        var found: [UInt32] = []
        for value in UInt32(0)...UInt32(0x10FFFF) {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if CharacterSet.whitespaces.contains(scalar) { found.append(value) }
        }
        XCTAssertEqual(found, fixture.trimmedCharacters.sorted(),
                       "Foundation's .whitespaces changed; update the fixture list and the recipe's TRIMMED_CHARACTERS together")
    }

    func testLineBoundaryCharactersAreExactlyFoundationNewlines() throws {
        let fixture = try loadFixture()
        var found: [UInt32] = []
        for value in UInt32(0)...UInt32(0x10FFFF) {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if CharacterSet.newlines.contains(scalar) { found.append(value) }
        }
        XCTAssertEqual(found, fixture.newlineCharacters.sorted(),
                       "Foundation's .newlines changed; update the fixture list and the recipe's AMBIGUOUS_LINE_BOUNDARIES together")
    }
}
