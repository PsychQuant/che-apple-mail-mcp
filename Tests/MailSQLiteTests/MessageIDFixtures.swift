import XCTest
@testable import MailSQLite

/// A throwaway Mail storage tree for the Message-ID tests (#682): `.emlx` files
/// written under `<root>/<account>/<mailbox>.mbox/<store>/Data/Messages/`.
/// Every address and id in it is synthetic.
final class MessageIDStore {
    static let account = "UUID-A"
    static let store = "5FCC6F13-2CE3-48B1-907D-686244C0229A"
    let root: URL

    init(testCase: XCTestCase) throws {
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        root = URL(fileURLWithPath: String(cString: canonical))
            .appendingPathComponent("msgid682-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let root = self.root
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    static func mailboxURL(_ name: String = "INBOX") -> String { "imap://\(account)/\(name)" }

    func messagesDirectory(mailbox: String = "INBOX") -> URL {
        root.appendingPathComponent("\(Self.account)/\(mailbox).mbox/\(Self.store)/Data/Messages", isDirectory: true)
    }

    /// Writes `<rowId>.emlx` (length line, message bytes, trailing plist) and returns its path.
    @discardableResult
    func write(rowId: Int, message: Data, mailbox: String = "INBOX", trailer: String = "\n<?xml version=\"1.0\"?><plist/>\n") throws -> String {
        let dir = messagesDirectory(mailbox: mailbox)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(rowId).emlx")
        try (Data("\(message.count)\n".utf8) + message + Data(trailer.utf8)).write(to: url)
        return url.path
    }

    /// Runs `body` with this tree as the mail storage path.
    func withStoragePath<T>(_ body: () throws -> T) rethrows -> T {
        let previous = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = root.path
        defer { EnvelopeIndexReader.mailStoragePathOverride = previous }
        return try body()
    }
}

/// The messages the parity tests feed through every path (name, raw bytes).
enum MessageIDSamples {
    static func bytes(_ s: String) -> Data { Data(s.utf8) }

    static let all: [(name: String, message: Data)] = [
        ("plain", bytes("From: a@example.invalid\r\nMessage-ID: <plain@example.invalid>\r\nSubject: s\r\n\r\nbody\r\n")),
        ("folded", bytes("From: a@example.invalid\r\nMessage-ID:\r\n <folded.part1\r\n .part2@example.invalid>\r\n\r\nbody")),
        ("folded-tab", bytes("Message-ID:\r\n\t<tab@example.invalid>\r\n\r\nbody")),
        ("encoded", bytes("Message-ID: =?UTF-8?Q?=3Cenc=40example.invalid=3E?=\r\n\r\nbody")),
        ("duplicate", bytes("Message-ID: <first@example.invalid>\r\nSubject: s\r\nMessage-ID: <second@example.invalid>\r\n\r\nbody")),
        ("cr-only", bytes("Subject: s\rMessage-ID: <cr@example.invalid>\rFrom: a@example.invalid\r\rbody")),
        ("lf-only", bytes("Subject: s\nMessage-ID: <lf@example.invalid>\n\nbody\n")),
        ("no-brackets", bytes("Message-ID: bare.value@example.invalid\r\n\r\nbody")),
        ("none", bytes("Subject: s\r\nFrom: a@example.invalid\r\n\r\nbody")),
        ("empty-value", bytes("Message-ID:\r\nSubject: s\r\n\r\nbody")),
        ("non-ascii", bytes("Message-ID: <caf\u{00E9}.\u{4E2D}\u{6587}@example.invalid>\r\n\r\nbody")),
        ("no-separator", bytes("Subject: s\r\nMessage-ID: <nosep@example.invalid>")),
        ("empty-message", Data()),
        ("lf-headers-crlf-body", bytes("Subject: s\nMessage-ID: <lfhead@example.invalid>\n\nline\r\n\r\nMessage-ID: <inbody@example.invalid>\r\n")),
        ("long-line", bytes("X-Long: " + String(repeating: "x", count: 100_000) + "\r\nMessage-ID: <long@example.invalid>\r\n\r\nbody")),
        ("long-header-block", bytes((0..<400).map { "X-Pad-\($0): value \($0)\r\n" }.joined() + "Message-ID: <pad@example.invalid>\r\n\r\n" + String(repeating: "b", count: 50_000))),
        ("headers-only-attachment-body", bytes("Message-ID: <att@example.invalid>\r\nContent-Type: application/octet-stream\r\n\r\n") + Data(repeating: 0x41, count: 300_000)),
    ]
}
