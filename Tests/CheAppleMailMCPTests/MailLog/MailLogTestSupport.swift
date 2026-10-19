import Foundation
import MCP
@testable import CheAppleMailMCP

/// #465 — shared helpers for the service/tool tests.
final class FakeLogSource: LogEventSource {
    var lines: [Data]
    var end: LogReadEnd
    private(set) var requests: [LogReadRequest] = []
    private(set) var delivered = 0
    /// When set, lines are generated without end until the handler stops.
    var endless: ((Int) -> Data)?

    init(lines: [Data] = [], end: LogReadEnd = .exhausted(exitStatus: 0, stderrTail: "")) {
        self.lines = lines
        self.end = end
    }

    func read(_ request: LogReadRequest, onLine: (Data) -> Bool) -> LogReadEnd {
        requests.append(request)
        if let endless {
            var i = 0
            while true {
                delivered += 1
                if !onLine(endless(i)) { return .stoppedByHandler }
                i += 1
            }
        }
        for line in lines {
            delivered += 1
            if !onLine(line) { return .stoppedByHandler }
        }
        return end
    }
}

enum Synthetic {
    /// 2026-10-02 12:00:00 +0800
    static let base = Date(timeIntervalSince1970: 1790913600)

    /// One ndjson line. `offset` is seconds after `base`.
    static func line(offset: Double, category: String = "IMAPSyncActivity",
                     format: String = "%@ Received %lu new local message actions",
                     message: String = "[account-one@example.invalid - Drafts] <Sync> Received 1 new local message actions",
                     process: String = "/System/Applications/Mail.app/Contents/MacOS/Mail",
                     thread: Int = 1001, activity: Int = 0) -> Data {
        let t = base.addingTimeInterval(offset)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        let object: [String: Any] = [
            "timestamp": f.string(from: t) + "+0800", "subsystem": "com.apple.mail", "category": category,
            "formatString": format, "eventMessage": message, "processImagePath": process,
            "threadID": thread, "activityIdentifier": activity,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func query(detail: MailLogDetail = .brief, limit: Int = 200, contains: String? = nil, redact: Bool = false) -> MailLogQuery {
        MailLogQuery(detail: detail, start: base, end: base.addingTimeInterval(600), categories: [],
                     contains: contains, redactIdentifiers: redact, limit: limit)
    }

    static let taipei = TimeZone(secondsFromGMT: 8 * 3600)!

    static func iso(_ offset: Double) -> String { MailLogTime(timeZone: taipei).format(base.addingTimeInterval(offset)) }

    static func serialized(_ response: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]), as: UTF8.self)
    }

    static func results(_ response: [String: Any]) -> [[String: Any]] { response["results"] as? [[String: Any]] ?? [] }
}
