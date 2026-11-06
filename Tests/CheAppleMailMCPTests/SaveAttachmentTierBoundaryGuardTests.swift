import XCTest

/// #575 — a failure to publish Tier-1 bytes must end the call. The destination
/// was refused or could not be written; the AppleScript tier would write to the
/// same place, and a second backend must not get a turn at a destination
/// problem (#402). This holds only because `destination.publish` sits outside
/// the Tier-1 `do` / `catch`, whose catch-all falls through to AppleScript, and
/// moving it inside would pass every behavioural test: reaching it needs an
/// Envelope Index and an `.emlx` fixture together, so a structural check pins it.
final class SaveAttachmentTierBoundaryGuardTests: XCTestCase {

    private func handlerBody() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/Server.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "case \"save_attachment\":"))
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "\n        case \""))
        return tail[..<end.lowerBound].components(separatedBy: "\n")
    }

    /// The blocks open at the line that holds `needle`, outermost first. Comments
    /// and string contents are ignored, so a brace in either cannot shift it.
    private func enclosingBlocks(of needle: String, in lines: [String]) throws -> [String] {
        var stack: [String] = []
        for line in lines {
            let code = Self.stripped(line)
            if code.contains(needle) { return stack }
            for character in code {
                if character == "{" { stack.append(code.trimmingCharacters(in: .whitespaces)) }
                if character == "}", !stack.isEmpty { stack.removeLast() }
            }
        }
        throw XCTSkip("needle not found: \(needle)")
    }

    private static func stripped(_ line: String) -> String {
        var result = "", inString = false, previous: Character = " "
        for character in line {
            if character == "\"", previous != "\\" { inString.toggle(); previous = character; continue }
            if !inString {
                if character == "/", previous == "/" { result.removeLast(); break }
                result.append(character)
            }
            previous = character
        }
        return result
    }

    private func isCatchOrDo(_ block: String) -> Bool {
        block.hasPrefix("do {") || block.hasPrefix("} catch") || block.hasPrefix("catch")
    }

    func testTier1PublicationIsOutsideEveryDoAndCatch() throws {
        let blocks = try enclosingBlocks(of: "destination.publish(", in: try handlerBody())
        XCTAssertFalse(blocks.isEmpty, "the call sits inside the Tier-1 branch")
        XCTAssertTrue(blocks.contains { $0.hasPrefix("if let reader = indexReader") },
                      "the guard must be looking at the Tier-1 branch: \(blocks)")
        XCTAssertEqual(blocks.filter(isCatchOrDo), [],
                       "a throw from publish must leave the handler, not reach the fallback")
    }

    func testTheExtractionItselfStaysInsideItsDo() throws {
        // The control: if this stopped holding, the check above would prove nothing.
        let blocks = try enclosingBlocks(of: "EmlxParser.attachmentData(", in: try handlerBody())
        XCTAssertTrue(blocks.contains(where: isCatchOrDo), "\(blocks)")
    }

    func testTheCheckNoticesAPublishInsideACatch() throws {
        // What the guard exists to catch, written out, so the scanner is known to see it.
        let moved = """
            if let reader = indexReader, let rowId = Int(id) {
                do {
                    return try destination.publish(localData, allowEmpty: allowEmpty)
                } catch {
                    Diagnostics.emit("falling through {\\n")
                }
            }
            """.components(separatedBy: "\n")
        let blocks = try enclosingBlocks(of: "destination.publish(", in: moved)
        XCTAssertFalse(blocks.filter(isCatchOrDo).isEmpty, "\(blocks)")
    }

    func testPublishIsTheOnlyTier1Write() throws {
        let body = try handlerBody().joined(separator: "\n")
        XCTAssertFalse(body.contains(".write(to:"), "Tier 1 writes only through the pinned destination")
    }
}
