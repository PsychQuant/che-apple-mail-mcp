import XCTest
@testable import CheAppleMailMCP

/// Only fixture-generated scripts are accepted. No Mail invocation or real data.
func attachmentStagePath(_ source: String) throws -> String {
    let regex = try NSRegularExpression(pattern: #"save att in POSIX file "([^"]+)""#)
    guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
          let range = Range(match.range(at: 1), in: source) else {
        throw NSError(domain: "AttachmentStageFixture", code: 1)
    }
    return String(source[range])
}

func stageAttachmentFixture(_ source: String, data: Data) throws -> String {
    let path = try attachmentStagePath(source)
    try data.write(to: URL(fileURLWithPath: path))
    return "Attachment saved to \(path)"
}
