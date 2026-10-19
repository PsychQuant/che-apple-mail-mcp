import Foundation

/// #465 — loads the synthetic ndjson fixtures by source location (the same
/// `#filePath` technique `ToolCountCensusGuardTests` uses), so no test-target
/// resource bundle is needed.
enum MailLogFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MailLog
        .deletingLastPathComponent()   // CheAppleMailMCPTests
        .appendingPathComponent("Fixtures/MailLog")

    static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    static func lines(_ name: String) throws -> [Data] {
        try text(name).split(separator: "\n").map { Data($0.utf8) }
    }
}
