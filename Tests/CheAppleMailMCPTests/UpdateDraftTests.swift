import XCTest
@testable import CheAppleMailMCP

/// #276 — `update_draft` upsert orchestration (draft-update spec) driven
/// through the real `MailController` methods with a fake script runner:
/// locate (list script) → create (legacy path forced via the ineligibility
/// seam) → delete-by-id, plus the refuse paths. No live Mail.
final class UpdateDraftTests: XCTestCase {

    private let RS = "\u{001E}", GS = "\u{001D}"

    /// Seam dispatcher: routes by script content — list script → `rows`,
    /// create-draft script → success/throw, delete script → success/throw.
    private func installSeam(
        rows: String,
        createThrows: Bool = false,
        deleteThrows: Bool = false,
        log: (@Sendable (String) -> Void)? = nil
    ) async {
        await MailController.shared.setTestSeams(
            scriptRunner: { script in
                log?(script)
                if script.contains("whose id is") {
                    if deleteThrows { throw MailError.scriptFailed(message: "delete boom", code: -1) }
                    return "Draft deleted"
                }
                if script.contains("make new outgoing message") || script.contains("save theMessage")
                    || script.contains("outgoing message") {
                    if createThrows { throw MailError.scriptFailed(message: "create boom", code: -1) }
                    return "Draft created successfully"
                }
                if script.contains("drafts mailbox") {
                    return rows
                }
                return ""
            },
            ineligibility: { "test forced legacy" })
    }

    private func teardownSeam() async {
        await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil)
    }

    // MARK: - listDrafts zip (spec: list_drafts returns draft ids)

    func testListDrafts_returnsIdAndSubjectPairs() async throws {
        addTeardownBlock { await self.teardownSeam() }
        await installSeam(rows: "101\(RS)102\(GS)Hello\(RS)Re: a, b, c")
        let drafts = try await MailController.shared.listDrafts(accountName: "Google")
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0]["id"] as? String, "101")
        XCTAssertEqual(drafts[0]["subject"] as? String, "Hello")
        XCTAssertEqual(drafts[1]["id"] as? String, "102")
        XCTAssertEqual(drafts[1]["subject"] as? String, "Re: a, b, c")
    }

    // MARK: - happy path (spec: update_draft upsert tool — successful upsert)

    func testUpdateDraft_byId_createThenDelete() async throws {
        addTeardownBlock { await self.teardownSeam() }
        let order = OrderLog()
        await installSeam(rows: "101\(RS)102\(GS)A\(RS)B", log: { s in
            if s.contains("whose id is") { order.append("delete") }
            else if s.contains("outgoing message") { order.append("create") }
        })
        let result = try await MailController.shared.updateDraft(
            draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
            to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
            attachments: nil, format: .plain, sanitizeLinks: false,
            fromAddress: nil, requireWrapperFree: false)
        XCTAssertEqual(result["deleted_old"] as? Bool, true)
        XCTAssertEqual(result["old_draft_id"] as? String, "101")
        XCTAssertTrue((result["new_draft"] as? String ?? "").contains("Draft created"))
        XCTAssertEqual(order.entries, ["create", "delete"],
                       "create-then-delete ordering (design D1) — never delete first")
    }

    // MARK: - refuse paths (spec: identify selector semantics)

    func testUpdateDraft_subjectMatch_ambiguous_refusesWithCandidates() async throws {
        addTeardownBlock { await self.teardownSeam() }
        let order = OrderLog()
        await installSeam(rows: "101\(RS)102\(GS)Same\(RS)Same", log: { s in
            if s.contains("outgoing message") { order.append("create") }
            if s.contains("whose id is") { order.append("delete") }
        })
        do {
            _ = try await MailController.shared.updateDraft(
                draftId: nil, subjectMatch: "Same", accountName: "Google", accountId: nil,
                to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
                attachments: nil, format: .plain, sanitizeLinks: false,
                fromAddress: nil, requireWrapperFree: false)
            XCTFail("ambiguous subject_match must refuse")
        } catch {
            let msg = "\(error)"
            XCTAssertTrue(msg.contains("101") && msg.contains("102"),
                          "refusal must list candidate ids; got: \(msg)")
        }
        XCTAssertTrue(order.entries.isEmpty, "refuse must not create nor delete anything")
    }

    func testUpdateDraft_zeroMatch_refusesWithoutCreating() async throws {
        addTeardownBlock { await self.teardownSeam() }
        let order = OrderLog()
        await installSeam(rows: "101\(GS)Other", log: { s in
            if s.contains("outgoing message") { order.append("create") }
        })
        do {
            _ = try await MailController.shared.updateDraft(
                draftId: nil, subjectMatch: "NoSuch", accountName: "Google", accountId: nil,
                to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
                attachments: nil, format: .plain, sanitizeLinks: false,
                fromAddress: nil, requireWrapperFree: false)
            XCTFail("zero-match must refuse (update requires an existing draft)")
        } catch { }
        XCTAssertTrue(order.entries.isEmpty, "zero-match refuse must not create anything")
    }

    // MARK: - failure semantics (spec: create fails / delete fails scenarios)

    func testUpdateDraft_createFails_oldDraftUntouched() async throws {
        addTeardownBlock { await self.teardownSeam() }
        let order = OrderLog()
        await installSeam(rows: "101\(GS)A", createThrows: true, log: { s in
            if s.contains("whose id is") { order.append("delete") }
        })
        do {
            _ = try await MailController.shared.updateDraft(
                draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
                to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
                attachments: nil, format: .plain, sanitizeLinks: false,
                fromAddress: nil, requireWrapperFree: false)
            XCTFail("create failure must propagate")
        } catch { }
        XCTAssertTrue(order.entries.isEmpty, "create failure must NOT delete the old draft")
    }

    func testUpdateDraft_deleteFails_reportsBothExist() async throws {
        addTeardownBlock { await self.teardownSeam() }
        await installSeam(rows: "101\(GS)A", deleteThrows: true)
        let result = try await MailController.shared.updateDraft(
            draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
            to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
            attachments: nil, format: .plain, sanitizeLinks: false,
            fromAddress: nil, requireWrapperFree: false)
        XCTAssertEqual(result["deleted_old"] as? Bool, false,
                       "delete failure after successful create must not throw (design D5)")
        XCTAssertTrue((result["new_draft"] as? String ?? "").contains("Draft created"))
        let note = (result["note"] as? String) ?? ""
        XCTAssertTrue(note.contains("both") || note.contains("並存") || note.contains("仍在"),
                      "must explicitly disclose that both drafts now exist; got: \(note)")
    }
}

/// Tiny thread-safe append log for asserting call order across the seam.
private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String] = []
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return _entries }
    func append(_ s: String) { lock.lock(); _entries.append(s); lock.unlock() }
}
