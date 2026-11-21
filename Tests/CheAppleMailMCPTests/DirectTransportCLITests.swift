import XCTest
@testable import CheAppleMailMCP

/// #742 — the two command-line modes: parsing, storing the credential, and
/// forgetting an unknown send. No keychain, no terminal.
final class DirectTransportCLITests: XCTestCase {

    // MARK: parsing

    func testTheModesTakeTheirValue_andAMissingValueIsAUsageError() {
        XCTAssertEqual(RunMode.parse(["bin", "--direct-transport-set-credential", "me@icloud.example"]),
                       .setDirectTransportCredential(address: "me@icloud.example"))
        XCTAssertEqual(RunMode.parse(["bin", "--direct-transport-forget", "<d1@icloud.example>"]),
                       .forgetDirectTransportSend(messageID: "<d1@icloud.example>"))
        for argv in [["bin", "--direct-transport-set-credential"],
                     ["bin", "--direct-transport-set-credential", "--setup"],
                     ["bin", "--direct-transport-forget"],
                     ["bin", "--direct-transport-forget", "x", "--direct-transport-set-credential", "y"]] {
            guard case .usageError = RunMode.parse(argv) else { return XCTFail("\(argv) should be a usage error") }
        }
        XCTAssertEqual(RunMode.parse(["bin"]), .server, "the default stays the stdio server")
    }

    // MARK: credential

    private final class Stored: @unchecked Sendable { var pairs: [(String, String)] = [] }

    func testTheTrailingLineEndIsDropped_andThePasswordIsNeverInTheMessage() {
        let stored = Stored()
        let outcome = DirectTransportCLI.setCredential(address: "me@icloud.example",
                                                       readPassword: { "abcd-efgh-ijkl-mnop\r\n" },
                                                       store: { stored.pairs.append(($0, $1)) })
        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(stored.pairs.map(\.0), ["me@icloud.example"])
        XCTAssertEqual(stored.pairs.map(\.1), ["abcd-efgh-ijkl-mnop"])
        XCTAssertFalse(outcome.message.contains("abcd"))
    }

    func testNothingIsStoredForABadAddress_anEmptyOrMultiLinePassword_orNoInput() {
        let stored = Stored()
        let store: (String, String) throws -> Void = { stored.pairs.append(($0, $1)) }
        XCTAssertEqual(DirectTransportCLI.setCredential(address: "not-an-address", readPassword: { "pw" }, store: store).status, 64)
        XCTAssertEqual(DirectTransportCLI.setCredential(address: "me@icloud.example", readPassword: { "\n" }, store: store).status, 65)
        XCTAssertEqual(DirectTransportCLI.setCredential(address: "me@icloud.example", readPassword: { "a\nb\n" }, store: store).status, 65)
        XCTAssertEqual(DirectTransportCLI.setCredential(address: "me@icloud.example", readPassword: { nil }, store: store).status, 66)
        XCTAssertTrue(stored.pairs.isEmpty)
    }

    // MARK: forget

    private func records() -> SendRecordStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dt-cli-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return SendRecordStore(directory: dir)
    }

    private func entry(_ id: String, _ state: SendRecord.State) -> SendRecord {
        SendRecord(messageID: id, accountID: "UUID-I", state: state, sentCopy: .pending, draftRemoval: .pending,
                   updatedAt: Date(timeIntervalSince1970: 1_800_000_000), serverReply: nil)
    }

    func testAnUnknownOrAttemptingEntryIsRemoved() throws {
        let store = records()
        try store.put(entry("<u@x>", .unknown))
        try store.put(entry("<a@x>", .attempting))
        XCTAssertEqual(DirectTransportCLI.forget(messageID: "<u@x>", records: store).status, 0)
        XCTAssertEqual(DirectTransportCLI.forget(messageID: "<a@x>", records: store).status, 0)
        XCTAssertNil(try store.entry(for: "<u@x>"))
        XCTAssertNil(try store.entry(for: "<a@x>"))
    }

    func testASubmittedEntryIsKept_soTheDraftCannotBeSubmittedTwice() throws {
        let store = records()
        try store.put(entry("<s@x>", .submitted))
        let outcome = DirectTransportCLI.forget(messageID: "<s@x>", records: store)
        XCTAssertEqual(outcome.status, 1)
        XCTAssertTrue(outcome.message.contains("kept"), outcome.message)
        XCTAssertNotNil(try store.entry(for: "<s@x>"))
    }

    func testTheMessageIDMayBeGivenWithoutBracketsOrWithSpaces() throws {
        let store = records()
        try store.put(entry("<u@x>", .unknown))
        try store.put(entry("<v@x>", .unknown))
        XCTAssertEqual(DirectTransportCLI.forget(messageID: "u@x", records: store).status, 0)
        XCTAssertEqual(DirectTransportCLI.forget(messageID: " <v@x> ", records: store).status, 0)
        XCTAssertNil(try store.entry(for: "<u@x>"))
        XCTAssertNil(try store.entry(for: "<v@x>"))
    }

    /// The local .emlx value and the server's envelope value meet in one form,
    /// or a draft_id lookup never matches.
    func testALocalMessageIDIsPutInTheServersForm() {
        XCTAssertEqual(SwiftMailSession.canonicalMessageID(" <a.b@x.example> "), "<a.b@x.example>")
        XCTAssertEqual(SwiftMailSession.canonicalMessageID("a.b@x.example"), "<a.b@x.example>")
        XCTAssertNil(SwiftMailSession.canonicalMessageID("no-at-sign"))
    }

    /// The Message-ID comes from the draft, which anyone can write. The command
    /// printed for a person to paste must not let it out of its quotes.
    func testThePrintedForgetCommandCannotBeBrokenOutOf() {
        XCTAssertEqual(DirectTransportCLI.forgetCommand(for: "<a@x>"), "--direct-transport-forget '<a@x>'")
        XCTAssertEqual(DirectTransportCLI.forgetCommand(for: "<a'$(touch p)'@x>"),
                       #"--direct-transport-forget '<a'\''$(touch p)'\''@x>'"#)
        XCTAssertNil(DirectTransportCLI.forgetCommand(for: "<a\n@x>"), "a control character: no command is printed")
        XCTAssertNil(DirectTransportCLI.forgetCommand(for: "<a\u{1B}[2J@x>"))
    }

    func testAnAbsentEntryRemovesNothing() {
        XCTAssertEqual(DirectTransportCLI.forget(messageID: "<none@x>", records: records()).status, 1)
    }
}
