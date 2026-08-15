import XCTest
@testable import CheAppleMailMCP

/// #276 — `update_draft` upsert orchestration (draft-update spec) driven
/// through the real `MailController` methods with a fake script runner:
/// locate (list script) → create → delete-by-id, plus the refuse paths.
/// No live Mail.
///
/// #304: the create step is the mailto GUI script (the legacy injection path
/// this used to force through the eligibility seam no longer exists), so the
/// dispatcher recognizes the create by the mailto hand-off rather than by
/// `make new outgoing message`.
final class UpdateDraftTests: XCTestCase {

    private let RS = "\u{001E}", GS = "\u{001D}"

    /// Seam dispatcher: routes by script content — list script → next element
    /// of `rowsSequence` (last element repeats; #276 R3: the post-create
    /// receipt re-lists, so tests script the before/after payloads),
    /// create-draft script → success/throw, delete script → success/throw.
    private func installSeam(
        rowsSequence: [String],
        createThrows: Bool = false,
        deleteError: Error? = nil,
        log: (@Sendable (String) -> Void)? = nil
    ) async {
        let counter = SeqCounter()
        await MailController.shared.setTestSeams(
            scriptRunner: { script in
                log?(script)
                if script.contains("whose id is") {
                    if let deleteError { throw deleteError }
                    return "Draft deleted"
                }
                if script.contains("mailto:") || script.contains("make new outgoing message") {
                    if createThrows { throw MailError.scriptFailed(message: "create boom", code: -1) }
                    return "Draft created successfully"
                }
                if script.contains("drafts mailbox") {
                    return rowsSequence[min(counter.next(), rowsSequence.count - 1)]
                }
                return ""
            },
            refusal: { nil })
    }

    private func installSeam(
        rows: String,
        createThrows: Bool = false,
        deleteError: Error? = nil,
        log: (@Sendable (String) -> Void)? = nil
    ) async {
        await installSeam(rowsSequence: [rows], createThrows: createThrows,
                          deleteError: deleteError, log: log)
    }

    private func teardownSeam() async {
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
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
        await installSeam(
            rowsSequence: ["101\(RS)102\(GS)A\(RS)B",
                           "101\(RS)102\(GS)A\(RS)B",
                           "101\(RS)102\(RS)999\(GS)A\(RS)B\(RS)s"],
            log: { s in
                if s.contains("whose id is") { order.append("delete") }
                else if s.contains("mailto:") { order.append("create") }
            })
        let result = try await MailController.shared.updateDraft(
            draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
            to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
            attachments: nil, format: .plain, fromAddress: nil)
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
                attachments: nil, format: .plain, fromAddress: nil)
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
            if s.contains("whose id is") { order.append("delete") }
        })
        do {
            _ = try await MailController.shared.updateDraft(
                draftId: nil, subjectMatch: "NoSuch", accountName: "Google", accountId: nil,
                to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
                attachments: nil, format: .plain, fromAddress: nil)
            XCTFail("zero-match must refuse (update requires an existing draft)")
        } catch { }
        XCTAssertTrue(order.entries.isEmpty, "zero-match refuse must not create anything")
    }

    // MARK: - selector validation (verify R1, Codex blocking 2 + empty subject_match)

    func testUpdateDraft_selectorValidation_strictAndExclusive() async throws {
        addTeardownBlock { await self.teardownSeam() }
        await installSeam(rows: "101\(GS)A")
        // both selectors → invalidParameter
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.updateDraft(
                draftId: "101", subjectMatch: "A", accountName: nil, accountId: nil,
                to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
                attachments: nil, format: .plain, fromAddress: nil))
        // neither selector → invalidParameter
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.updateDraft(
                draftId: nil, subjectMatch: nil, accountName: nil, accountId: nil,
                to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
                attachments: nil, format: .plain, fromAddress: nil))
        // non-ASCII Unicode digits (Character.isNumber would accept ١٢٣) → reject
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.updateDraft(
                draftId: "١٢٣", subjectMatch: nil, accountName: nil, accountId: nil,
                to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
                attachments: nil, format: .plain, fromAddress: nil))
    }

    func testUpdateDraft_emptySelectorValues_neverTreatedAsAbsent() async throws {
        // #276 verify R2 (Codex blocking 1): presence = key provided; an
        // explicitly EMPTY value must be rejected as its own error, never
        // silently downgraded to "absent" (which let draft_id +
        // subject_match:"" slip past the mutual-exclusion gate and run the
        // mutation).
        addTeardownBlock { await self.teardownSeam() }
        let order = OrderLog()
        await installSeam(rows: "101\(GS)A", log: { s in
            if s.contains("outgoing message") { order.append("create") }
            if s.contains("whose id is") { order.append("delete") }
        })
        // draft_id + empty subject_match → both selectors provided → reject
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.updateDraft(
                draftId: "101", subjectMatch: "", accountName: nil, accountId: nil,
                to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
                attachments: nil, format: .plain, fromAddress: nil))
        // empty draft_id + valid subject_match → invalid draft_id, reject
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.updateDraft(
                draftId: "", subjectMatch: "A", accountName: nil, accountId: nil,
                to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
                attachments: nil, format: .plain, fromAddress: nil))
        // sole empty subject_match → the DEDICATED empty-subject error
        do {
            _ = try await MailController.shared.updateDraft(
                draftId: nil, subjectMatch: "", accountName: nil, accountId: nil,
                to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
                attachments: nil, format: .plain, fromAddress: nil)
            XCTFail("sole empty subject_match must throw its dedicated error")
        } catch {
            XCTAssertTrue("\(error)".contains("non-empty"),
                          "must be the dedicated empty-subject_match error; got: \(error)")
        }
        XCTAssertTrue(order.entries.isEmpty,
                      "no rejected selector shape may create or delete anything")
    }

    // MARK: - phantom create receipt (verify R3, DA-2)

    func testUpdateDraft_createUnconfirmed_keepsOldDraft() async throws {
        // #276 verify R3 (DA-2, HIGH): the GUI mailto create path can return
        // success after firing keystrokes without the draft actually landing
        // (phantom success). The delete gate is therefore a RECEIPT: re-list
        // and require a NEW id (not in the pre-create set) before deleting
        // the old draft. No new id after the poll budget → keep the old
        // draft and say so.
        addTeardownBlock { await self.teardownSeam() }
        let order = OrderLog()
        await installSeam(rows: "101\(GS)A", log: { s in   // list always returns the SAME rows
            if s.contains("whose id is") { order.append("delete") }
        })
        let result = try await MailController.shared.updateDraft(
            draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
            to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
            attachments: nil, format: .plain, fromAddress: nil)
        XCTAssertEqual(result["deleted_old"] as? Bool, false)
        XCTAssertTrue(((result["note"] as? String) ?? "").contains("not confirmed"),
                      "must disclose the unconfirmed replacement; got: \(result["note"] ?? "")")
        XCTAssertTrue(order.entries.isEmpty,
                      "an unconfirmed replacement must NEVER delete the old draft")
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
                attachments: nil, format: .plain, fromAddress: nil)
            XCTFail("create failure must propagate")
        } catch { }
        XCTAssertTrue(order.entries.isEmpty, "create failure must NOT delete the old draft")
    }

    func testUpdateDraft_deleteFails_reportsBothMayExist() async throws {
        addTeardownBlock { await self.teardownSeam() }
        await installSeam(
            rowsSequence: ["101\(GS)A", "101\(GS)A", "101\(RS)999\(GS)A\(RS)s"],
            deleteError: MailError.scriptFailed(message: "delete boom", code: -1))
        let result = try await MailController.shared.updateDraft(
            draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
            to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
            attachments: nil, format: .plain, fromAddress: nil)
        XCTAssertEqual(result["deleted_old"] as? Bool, false,
                       "delete failure after successful create must not throw (design D5)")
        XCTAssertTrue((result["new_draft"] as? String ?? "").contains("Draft created"))
        let note = (result["note"] as? String) ?? ""
        XCTAssertTrue(note.contains("MAY") || note.contains("may"),
                      "a generic delete failure may only claim both drafts MAY exist (verify R5); got: \(note)")
        XCTAssertFalse(note.contains("both drafts now exist"),
                       "must not make a definite both-exist claim on an unverified failure")
    }
}

extension UpdateDraftTests {
    // MARK: - receipt retry + causality (verify R5)

    func testUpdateDraft_receiptConfirmedOnSecondPoll_thenDeletes() async throws {
        // Delayed async save: the replacement appears only on the SECOND
        // post-create poll — the receipt must retry, then delete.
        addTeardownBlock { await self.teardownSeam() }
        let order = OrderLog()
        await installSeam(
            rowsSequence: ["101\(GS)A",                      // locate
                           "101\(GS)A",                      // pre-receipt baseline
                           "101\(GS)A",                      // post poll 1 — not yet
                           "101\(RS)999\(GS)A\(RS)s"],     // post poll 2 — landed
            log: { s in if s.contains("whose id is") { order.append("delete") } })
        let result = try await MailController.shared.updateDraft(
            draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
            to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
            attachments: nil, format: .plain, fromAddress: nil)
        XCTAssertEqual(result["deleted_old"] as? Bool, true)
        XCTAssertEqual(order.entries, ["delete"])
    }

    func testUpdateDraft_unrelatedNewDraft_isNotAReceipt() async throws {
        // Causality: a new id whose subject differs from the replacement's
        // (an unrelated concurrent draft) must NOT stand in as the receipt —
        // old draft kept, zero deletes.
        addTeardownBlock { await self.teardownSeam() }
        let order = OrderLog()
        await installSeam(
            rowsSequence: ["101\(GS)A",
                           "101\(GS)A",
                           "101\(RS)777\(GS)A\(RS)totally-unrelated"],
            log: { s in if s.contains("whose id is") { order.append("delete") } })
        let result = try await MailController.shared.updateDraft(
            draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
            to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
            attachments: nil, format: .plain, fromAddress: nil)
        XCTAssertEqual(result["deleted_old"] as? Bool, false)
        XCTAssertTrue(((result["note"] as? String) ?? "").contains("not confirmed"))
        XCTAssertTrue(order.entries.isEmpty)
    }

    // MARK: - delete-outcome note honesty (verify R4 — Codex R3 blocking 1)

    func testUpdateDraft_deleteNotFound9276_confirmedAbsentNote() async throws {
        addTeardownBlock { await self.teardownSeam() }
        await installSeam(
            rowsSequence: ["101\(GS)A", "101\(GS)A", "101\(RS)999\(GS)A\(RS)s"],
            deleteError: MailError.scriptFailed(message: "not found", code: updateDraftDeleteNotFoundErrorNumber))
        let result = try await MailController.shared.updateDraft(
            draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
            to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
            attachments: nil, format: .plain, fromAddress: nil)
        XCTAssertEqual(result["deleted_old"] as? Bool, false)
        let note = (result["note"] as? String) ?? ""
        XCTAssertTrue(note.contains("confirmed absent") || note.contains("no longer present"),
                      "a clean-scan 9276 may claim confirmed absence; got: \(note)")
        XCTAssertFalse(note.contains("both drafts now exist"),
                       "9276 must not claim both exist")
    }

    func testUpdateDraft_deleteScanIncomplete9277_unknownStateNote() async throws {
        addTeardownBlock { await self.teardownSeam() }
        await installSeam(
            rowsSequence: ["101\(GS)A", "101\(GS)A", "101\(RS)999\(GS)A\(RS)s"],
            deleteError: MailError.scriptFailed(message: "scan incomplete", code: updateDraftDeleteScanIncompleteErrorNumber))
        let result = try await MailController.shared.updateDraft(
            draftId: "101", subjectMatch: nil, accountName: "Google", accountId: nil,
            to: ["a@x.co"], subject: "s", body: "b", cc: nil, bcc: nil,
            attachments: nil, format: .plain, fromAddress: nil)
        XCTAssertEqual(result["deleted_old"] as? Bool, false)
        let note = (result["note"] as? String) ?? ""
        XCTAssertTrue(note.contains("unknown") || note.contains("could not be verified"),
                      "an incomplete scan must report unknown old-draft state; got: \(note)")
        XCTAssertFalse(note.contains("confirmed absent"),
                       "9277 must never claim confirmed absence")
    }

    // MARK: - handler-boundary selector validation (verify R4 — Codex R3 blocking 2)

    func testHandlerSelectorValidation_keyPresenceAndTypes() throws {
        // Type confusion: draft_id present as an Int must be a parameter
        // error, NEVER silently downgraded to "absent" (which would run the
        // mutation on subject_match alone).
        XCTAssertThrowsError(try CheAppleMailMCPServer.validateUpdateDraftSelectors(
            ["draft_id": .int(123), "subject_match": .string("Unique")]))
        XCTAssertThrowsError(try CheAppleMailMCPServer.validateUpdateDraftSelectors(
            ["subject_match": .int(7)]))
        // Empty-value dedicated errors still fire at this boundary.
        XCTAssertThrowsError(try CheAppleMailMCPServer.validateUpdateDraftSelectors(
            ["subject_match": .string("")]))
        XCTAssertThrowsError(try CheAppleMailMCPServer.validateUpdateDraftSelectors(
            ["draft_id": .string("")]))
        XCTAssertThrowsError(try CheAppleMailMCPServer.validateUpdateDraftSelectors(
            ["draft_id": .string("1\u{0301}")]))
        // Both / neither.
        XCTAssertThrowsError(try CheAppleMailMCPServer.validateUpdateDraftSelectors(
            ["draft_id": .string("1"), "subject_match": .string("A")]))
        XCTAssertThrowsError(try CheAppleMailMCPServer.validateUpdateDraftSelectors([:]))
        // Account scoping fields (verify R6): non-string types must error,
        // never silently widen a mutation to all accounts.
        XCTAssertThrowsError(try CheAppleMailMCPServer.validateUpdateDraftSelectors(
            ["subject_match": .string("Unique"), "account_name": .int(123)]))
        XCTAssertThrowsError(try CheAppleMailMCPServer.validateUpdateDraftSelectors(
            ["draft_id": .string("1"), "account_id": .bool(true)]))
        // Happy paths.
        let byId = try CheAppleMailMCPServer.validateUpdateDraftSelectors(["draft_id": .string("101")])
        XCTAssertEqual(byId.draftId, "101"); XCTAssertNil(byId.subjectMatch)
        let bySubj = try CheAppleMailMCPServer.validateUpdateDraftSelectors(["subject_match": .string("A")])
        XCTAssertEqual(bySubj.subjectMatch, "A"); XCTAssertNil(bySubj.draftId)
    }
}

/// Thread-safe monotonically-increasing counter for the sequence-aware seam.
private final class SeqCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = -1
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

/// Tiny thread-safe append log for asserting call order across the seam.
private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String] = []
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return _entries }
    func append(_ s: String) { lock.lock(); _entries.append(s); lock.unlock() }
}
