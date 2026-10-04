import XCTest
@testable import MailSQLite

/// #472 — the direct-draft writer needs the path a NEW message's .emlx will
/// live at. `resolveEmlxPathDetailed` only answers for files that already exist
/// and splits the lossy `mailboxPath`; this variant requires only the mailbox's
/// store directory and builds the path from `pathComponents`.
final class NewEmlxPathTests: XCTestCase {

    private let accountUUID = "29076D02-3E4C-4FBB-BFCE-DE02B6B125C3"
    private let storeUUID = "5FCC6F13-2CE3-48B1-907D-686244C0229A"
    private var root: URL!
    private var originalBase: String?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("new-emlx-\(UUID().uuidString)")
        originalBase = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = root.path
    }

    override func tearDownWithError() throws {
        EnvelopeIndexReader.mailStoragePathOverride = originalBase
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(_ segments: [String]) throws -> URL {
        var dir = root.appendingPathComponent(accountUUID)
        for s in segments { dir = dir.appendingPathComponent("\(s).mbox") }
        let store = dir.appendingPathComponent(storeUUID)
        try FileManager.default.createDirectory(at: store.appendingPathComponent("Data"),
                                                withIntermediateDirectories: true)
        return store
    }

    func testBuildsThePathForANewMessageWithoutRequiringTheFile() throws {
        let store = try makeStore(["[Gmail]", "草稿"])
        let url = "imap://\(accountUUID)/%5BGmail%5D/%E8%8D%89%E7%A8%BF"
        let path = try XCTUnwrap(EmlxParser.newEmlxPath(rowId: 305561, mailboxURL: url))
        XCTAssertEqual(path, store.appendingPathComponent("Data/5/0/3/Messages/305561.emlx").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the file itself need not exist")
    }

    func testRowIdBelowAThousandLivesDirectlyUnderDataMessages() throws {
        let store = try makeStore(["INBOX"])
        let path = try XCTUnwrap(EmlxParser.newEmlxPath(rowId: 42, mailboxURL: "imap://\(accountUUID)/INBOX"))
        XCTAssertEqual(path, store.appendingPathComponent("Data/Messages/42.emlx").path)
    }

    func testUsesPathComponentsSoAnEncodedSlashStaysInsideOneName() throws {
        // A mailbox literally named "a/b" is percent-encoded as one component.
        let store = try makeStore(["a/b"])
        let path = try XCTUnwrap(EmlxParser.newEmlxPath(rowId: 1001, mailboxURL: "imap://\(accountUUID)/a%2Fb"))
        XCTAssertTrue(path.hasPrefix(store.path), "must not split the name at the encoded slash: \(path)")
    }

    func testReturnsNilWhenTheMailboxHasNoStoreDirectory() {
        XCTAssertNil(EmlxParser.newEmlxPath(rowId: 5, mailboxURL: "imap://\(accountUUID)/Missing"))
    }
}
