import XCTest
@testable import CheAppleMailMCP
@testable import MailSQLite

/// #720 — the AppleScript fallback's `MailController.decodeQuotedPrintable` must
/// do work linear in the length of the input, and its output must not change.
///
/// The differential tests compare it with the pre-#720 algorithm, kept below as
/// a test-only reference (a verbatim copy). The work-count tests read
/// `QuotedPrintableWorkProbe`, so no clock is involved.
final class QuotedPrintableLinearWorkTests: XCTestCase {

    override func tearDown() {
        QuotedPrintableWorkProbe.report = nil
        super.tearDown()
    }

    // MARK: - Differential

    private func assertSame(_ input: String, file: StaticString = #filePath, line: UInt = #line) async {
        let expected = Self.reference(input)
        let actual = await MailController.shared.decodeQuotedPrintable(input)
        if expected != actual {
            XCTFail("decodeQuotedPrintable diverged from the pre-#720 algorithm on \(String(reflecting: input)): "
                    + "expected \(String(reflecting: expected)), got \(String(reflecting: actual))",
                    file: file, line: line)
        }
    }

    private static let fixtures: [String] = [
        "<p>caf=C3=A9 r=C3=A9sum=C3=A9</p>",
        "<p>a=ZZb a=+5b a=-0b a=\u{FF10}\u{FF15}b a=5 b caf=c3=a9 end=4</p>",
        "soft=\r\nbreak", "soft=\nbreak", "trailing=", "trailing=4", "trailing=41", "=", "==", "===", "=41", "=4",
        "=\u{301}41", "=4\u{301}1", "=\r\n", "a=\r\n=\r\nb", "=ZZ=ZZ=ZZ", "=41=42=43", "=C3=A9=C3", "=C3", "",
        "plain text", "日=20本", "e\u{301}=41", "=41\u{301}", "=\u{FF14}\u{FF11}",
    ]

    func testFixturesMatchTheReference() async {
        for input in Self.fixtures { await assertSame(input) }
    }

    /// Every string up to length 5 over characters that matter to the decoder.
    func testEveryShortStringOverASmallAlphabetMatchesTheReference() async {
        let alphabet: [Character] = ["=", "A", "4", "1", "Z", "+", "\r\n", "\n", "\r", "é", "\u{FF10}", " ", "\u{301}"]
        var count = 0
        func collect(_ prefix: String, _ remaining: Int, into all: inout [String]) {
            all.append(prefix)
            if remaining == 0 { return }
            for c in alphabet { collect(prefix + String(c), remaining - 1, into: &all) }
        }
        var all: [String] = []
        collect("", 5, into: &all)
        for input in all { await assertSame(input); count += 1 }
        XCTAssertGreaterThan(count, 100_000)
    }

    func testSeededRandomValuesMatchTheReference() async {
        var rng = SplitMix64(seed: 0x720_0641)
        let pieces = ["=41", "=C3=A9", "=ZZ", "=+5", "=4", "=", "=\r\n", "=\n", "a", "é", "\r\n", " ", "<p>", "=E6=97=A5", "\u{301}", "=e6=97"]
        for _ in 0..<6000 {
            var value = ""
            for _ in 0..<Int(rng.next() % 60) {
                value += pieces[Int(rng.next() % UInt64(pieces.count))]
            }
            await assertSame(value)
        }
    }

    // MARK: - Work count

    private func work(_ value: String) async -> Int {
        var reported: Int?
        QuotedPrintableWorkProbe.report = { reported = $0 }
        _ = await MailController.shared.decodeQuotedPrintable(value)
        QuotedPrintableWorkProbe.report = nil
        return reported ?? -1
    }

    private func assertLinear(_ label: String, _ make: (Int) -> String,
                              file: StaticString = #filePath, line: UInt = #line) async {
        let n = 400
        let w1 = await work(make(n)), w2 = await work(make(2 * n)), w4 = await work(make(4 * n))
        XCTAssertGreaterThanOrEqual(w1, 0, "\(label): the probe did not report", file: file, line: line)
        XCTAssertLessThanOrEqual(w2, w1 * 2 + w1 / 4 + 64,
                                 "\(label): work grew faster than linearly from n to 2n (\(w1) -> \(w2))",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(w4, w1 * 4 + w1 / 2 + 64,
                                 "\(label): work grew faster than linearly from n to 4n (\(w1) -> \(w4))",
                                 file: file, line: line)
    }

    func testWorkIsLinearForManyEscapes() async {
        await assertLinear("valid escapes") { String(repeating: "=41", count: $0) }
    }

    func testWorkIsLinearForManyMalformedEscapes() async {
        await assertLinear("malformed escapes") { String(repeating: "=ZZ", count: $0) }
        await assertLinear("bare equals signs") { String(repeating: "=", count: $0) }
    }

    func testWorkIsLinearForMultibyteEscapesAndLiterals() async {
        await assertLinear("multibyte escapes") { String(repeating: "=C3=A9x", count: $0) }
        await assertLinear("no escapes") { String(repeating: "abc ", count: $0) }
    }

    func testWorkIsLinearForSoftBreaksAndTruncatedTail() async {
        await assertLinear("soft breaks") { String(repeating: "=41=\r\n", count: $0) + "=4" }
    }

    // MARK: - Source guard

    /// The work counter above counts loop steps and the characters the bounded
    /// length check looks at. It cannot see the cost of measuring the rest of the
    /// string, so putting `distance(from:to:)` back leaves every count unchanged
    /// (checked by mutation: the work-count tests stayed green). This guard reads
    /// the shipped function instead and fails if it measures a distance again.
    func testTheDecoderDoesNotMeasureTheRestOfTheString() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <package root>/
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let signature = "func decodeQuotedPrintable(_ input: String) -> String {"
        let start = try XCTUnwrap(text.range(of: signature), "the decoder was renamed or moved: update this guard")
        // The body runs to the brace that closes the function.
        var depth = 0
        var end = text.endIndex
        var index = text.index(before: start.upperBound)
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { end = text.index(after: index); break }
            }
            index = text.index(after: index)
        }
        let body = String(text[start.lowerBound..<end])
        XCTAssertTrue(body.contains("return String(decoding: bytes, as: UTF8.self)"),
                      "the function body was not found whole: the guard would pass vacuously")
        XCTAssertFalse(body.contains("distance("),
                       "decodeQuotedPrintable measures a distance again; on every `=` that is linear in the rest of the string (#720)")
        XCTAssertTrue(body.contains("limitedBy:"),
                      "the bounded length check is gone from decodeQuotedPrintable (#720)")
    }

    // MARK: - The algorithm before #720

    /// Verbatim copy of `MailController.decodeQuotedPrintable` before #720.
    /// Quadratic on purpose (`distance` on every `=`).
    static func reference(_ input: String) -> String {
        var result = input
        result = result.replacingOccurrences(of: "=\r\n", with: "")
        result = result.replacingOccurrences(of: "=\n", with: "")

        var bytes: [UInt8] = []
        var i = result.startIndex
        while i < result.endIndex {
            if result[i] == "=" && result.distance(from: i, to: result.endIndex) >= 3 {
                let hexStart = result.index(after: i)
                let lowStart = result.index(after: hexStart)
                if let byte = HexEscape.byte(result[hexStart], result[lowStart]) {
                    bytes.append(byte)
                    i = result.index(after: lowStart)
                } else {
                    bytes.append(contentsOf: result[i].utf8)
                    i = hexStart
                }
            } else {
                bytes.append(contentsOf: result[i].utf8)
                i = result.index(after: i)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// SplitMix64: a fixed-seed generator so the random corpus is the same every run.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
