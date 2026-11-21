import XCTest
@testable import CheAppleMailMCP

/// #742 — the record of sent drafts that Requirement: A submission has one of three
/// outcomes and Requirement: The sent copy and the draft's removal are separate
/// stages after submission read and write.
final class SendRecordStoreTests: XCTestCase {

    private func store() throws -> (SendRecordStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dt-record-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (SendRecordStore(directory: dir), dir)
    }

    private func entry(_ id: String, _ state: SendRecord.State,
                       sentCopy: SendRecord.Stage = .pending, removal: SendRecord.Stage = .pending) -> SendRecord {
        SendRecord(messageID: id, accountID: "UUID-I", state: state, sentCopy: sentCopy, draftRemoval: removal,
                   updatedAt: Date(timeIntervalSince1970: 1_800_000_000), serverReply: nil)
    }

    func testAnAbsentRecordIsEmpty() throws {
        let (store, _) = try store()
        XCTAssertNil(try store.entry(for: "<a@x>"))
    }

    func testAnEntryIsWrittenReadAndRemoved() throws {
        let (store, _) = try store()
        try store.put(entry("<a@x>", .submitted, sentCopy: .done))
        XCTAssertEqual(try store.entry(for: "<a@x>")?.state, .submitted)
        XCTAssertEqual(try store.entry(for: "<a@x>")?.sentCopy, .done)
        try store.put(entry("<b@x>", .unknown))
        try store.remove("<a@x>")
        XCTAssertNil(try store.entry(for: "<a@x>"))
        XCTAssertEqual(try store.entry(for: "<b@x>")?.state, .unknown)
    }

    /// A process that died between writing `attempting` and learning the outcome
    /// leaves an entry that the next call must not read as "not sent".
    func testAnAttemptingEntryIsReadAsUnknown() throws {
        let (store, _) = try store()
        try store.put(entry("<a@x>", .attempting))
        XCTAssertEqual(try store.entry(for: "<a@x>")?.effectiveState, .unknown)
    }

    func testTheFileIsPrivate_andHoldsNoMessageContent() throws {
        let (store, dir) = try store()
        try store.put(entry("<a@x>", .submitted))
        let url = dir.appendingPathComponent(SendRecordStore.fileName)
        let mode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        let keys = Set(try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]).keys)
        XCTAssertEqual(keys, ["entries"])
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        for word in ["subject", "to", "body", "recipients"] {
            XCTAssertFalse(text.contains("\"\(word)\""), word)
        }
    }

    func testARecordThatCannotBeReadIsRefused_notReadAsEmpty() throws {
        let (store, dir) = try store()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent(SendRecordStore.fileName))
        XCTAssertThrowsError(try store.entry(for: "<a@x>")) { error in
            XCTAssertTrue("\(error)".contains(SendRecordStore.fileName), "\(error)")
        }
        XCTAssertThrowsError(try store.put(entry("<a@x>", .attempting)))
    }
}
