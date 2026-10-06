import XCTest
@testable import CheAppleMailMCP
import MailSQLite

/// #472 — the orchestration seams of the experimental direct-draft path that
/// need no store and no Mail: the trigger script and the early exits.
final class DirectDraftPathTests: XCTestCase {

    func testTriggerScriptWaitsForTheDraftThenTogglesItsReadStatus() {
        let s = buildDirectDraftTriggerScript(rowId: 305619)
        XCTAssertTrue(s.contains("first message of drafts mailbox whose id is 305619"))
        XCTAssertTrue(s.contains("repeat 40 times"), "wait up to 10 s for Mail to list the new draft")
        XCTAssertTrue(s.contains("DIRECTDRAFT: Mail did not list the new draft"))
        let off = try! XCTUnwrap(s.range(of: "set read status of _m to false"))
        let on = try! XCTUnwrap(s.range(of: "set read status of _m to true"))
        XCTAssertTrue(off.upperBound < on.lowerBound, "false, then true: a net no-op that wakes the sync engine")
        XCTAssertFalse(s.contains("whose content contains"), "#221: never a full-content scan")
        XCTAssertTrue(s.contains("delay 0.5"), "the gap #472 records as validated in #463 (#472 saw 0.3 s leave one draft unread)")
    }

    func testReadRepairScriptMarksTheDraftRead() {
        // #472 live: with a 0.3 s gap one of two drafts ended unread locally
        // (server read=1). After the upload the path re-asserts read status.
        let s = buildDirectDraftMarkReadScript(rowId: 305742)
        XCTAssertTrue(s.contains("first message of drafts mailbox whose id is 305742"))
        XCTAssertTrue(s.contains("set read status of _m to true"))
        XCTAssertFalse(s.contains("to false"))
    }

    func testDisabledFlagIsNotAttemptedAndAddsNoNote() async {
        let outcome = await DirectDraftPath(controller: MailController.shared, reader: nil, enabled: false)
            .attempt(to: ["a@example.org"], subject: "S", body: "B", cc: nil, bcc: nil,
                     attachments: nil, format: .plain, fromAddress: "me@example.org")
        XCTAssertEqual(outcome, .notAttempted(nil), "with the flag off the GUI path runs exactly as before")
        XCTAssertNil(outcome.timingCode, "flag off: no direct rows at all")
    }

    func testIneligibleCallNamesTheReasonBeforeTouchingAnything() async {
        let outcome = await DirectDraftPath(controller: MailController.shared, reader: nil, enabled: true)
            .attempt(to: ["a@example.org"], subject: "S", body: "B", cc: ["c@example.org"], bcc: nil,
                     attachments: nil, format: .plain, fromAddress: "me@example.org")
        XCTAssertEqual(outcome, .notAttempted(.ineligible(.ccOrBcc)))
        XCTAssertEqual(outcome.timingCode, "not_attempted:ccOrBcc")
    }

    // MARK: - #475 outcome codes (closed list in specs/compose-timing)

    func testIneligibleCodesMatchTheSpecList() {
        let cases: [(DirectDraft.Ineligible, String)] = [
            (.format, "format"), (.attachments, "attachments"), (.ccOrBcc, "ccOrBcc"),
            (.noRecipient, "noRecipient"), (.displayName, "displayName"),
            (.unsupportedAddress, "unsupportedAddress"), (.emptySubject, "emptySubject"),
            (.missingFromAddress, "missingFromAddress"), (.fromNotBare, "fromNotBare"),
        ]
        for (ineligible, code) in cases {
            let gate = DirectDraftPath.Gate.ineligible(ineligible)
            XCTAssertEqual(gate.code, code)
            XCTAssertEqual(gate.reason, ineligible.reason, "the human reason is unchanged")
        }
    }

    func testGateCodesMatchTheSpecListAndCarryNoComma() {
        let gates: [(DirectDraftPath.Gate, String)] = [
            (.version, "version"), (.account(count: 2), "account"), (.index, "index"),
            (.draftsUnidentified("x, y"), "drafts_unidentified"), (.draftsUnmatched, "drafts_unmatched"),
            (.writerOpen("a, b"), "writer_open"), (.schemaDrift(["p", "q"]), "schema_drift"),
            (.mailbox, "mailbox"), (.sender, "sender"), (.insert("e, f"), "insert"),
        ]
        for (gate, code) in gates {
            XCTAssertEqual(gate.code, code)
            XCTAssertFalse(DirectDraftPath.Outcome.notAttempted(gate).timingCode!.contains(","))
        }
        // Reasons stay word-for-word what the GUI-path note has always said.
        XCTAssertEqual(DirectDraftPath.Gate.version.reason,
                       "Mail/macOS version outside the verified range (Mail 16, macOS 27)")
        XCTAssertEqual(DirectDraftPath.Gate.account(count: 2).reason,
                       "from_address maps to 2 accounts, not exactly one")
        XCTAssertEqual(DirectDraftPath.Gate.schemaDrift(["p", "q"]).reason,
                       "store schema differs from the verified one (p; q)")
    }

    func testCreatedAndFellBackCodes() {
        XCTAssertEqual(DirectDraftPath.Outcome.created("t", pending: false).timingCode, "created")
        XCTAssertEqual(DirectDraftPath.Outcome.created("t", pending: true).timingCode, "created:upload_pending")
        XCTAssertEqual(DirectDraftPath.Outcome.fellBack("r").timingCode, "fell_back:trigger")
    }

    // MARK: - #475 Direct-write path marks

    private func directSegments(enabled: Bool, cc: [String]?, from: String? = "me@example.org")
        async -> [ComposeTiming.Segment] {
        let run = ComposeTiming.Run()
        _ = await ComposeTiming.$currentRun.withValue(run) {
            await DirectDraftPath(controller: MailController.shared, reader: nil, enabled: enabled)
                .attempt(to: ["a@example.org"], subject: "S", body: "B", cc: cc, bcc: nil,
                         attachments: nil, format: .plain, fromAddress: from)
        }
        return run.collected
    }

    func testFlagOffRecordsNoDirectRows() async {
        let segments = await directSegments(enabled: false, cc: nil)
        XCTAssertTrue(segments.isEmpty, "with the flag off the direct path leaves no trace in the CSV")
    }

    func testIneligibleCallRecordsExactlyEnterAndReturned() async {
        let segments = await directSegments(enabled: true, cc: ["c@example.org"])
        XCTAssertEqual(segments.count, 1)
        guard let segment = segments.first else { return XCTFail("no direct segment recorded") }
        XCTAssertEqual(segment.path, "direct")
        XCTAssertEqual(segment.outcome, "not_attempted:ccOrBcc")
        XCTAssertEqual(segment.marks.map(\.label), ["enter", "returned"])
        XCTAssertTrue(segment.marks.allSatisfy { $0.source == "swift" })
        XCTAssertEqual(segment.config["from_address_set"], "true")
        XCTAssertNil(segment.config["window_delay"])
    }

    func testMissingFromAddressIsRecordedAsNotSet() async {
        let segments = await directSegments(enabled: true, cc: nil, from: nil)
        XCTAssertEqual(segments.first?.outcome, "not_attempted:missingFromAddress")
        XCTAssertEqual(segments.first?.config["from_address_set"], "false")
    }

    func testNoRunMeansNoTimingWork() async {
        // Timing off: no run context; the attempt must still behave exactly as before.
        XCTAssertNil(ComposeTiming.currentRun)
        let outcome = await DirectDraftPath(controller: MailController.shared, reader: nil, enabled: true)
            .attempt(to: ["a@example.org"], subject: "S", body: "B", cc: ["c@example.org"], bcc: nil,
                     attachments: nil, format: .plain, fromAddress: "me@example.org")
        XCTAssertEqual(outcome, .notAttempted(.ineligible(.ccOrBcc)))
    }

    // MARK: - #475 One run per create_draft call

    private func fakeGui(_ csvPath: String) -> () async throws -> String {
        {
            let t0 = Date().timeIntervalSinceReferenceDate
            ComposeTiming.record(ComposeTiming.Segment(
                path: "gui-mailto", outcome: "ok", config: [:],
                marks: [ComposeTiming.Mark(source: "swift", label: "enter", time: t0),
                        ComposeTiming.Mark(source: "swift", label: "returned", time: t0 + 0.25)]),
                csvPath: csvPath)
            return "GUI draft created"
        }
    }

    func testAFallbackIsOneRunWithTheDirectSegmentFirst() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("create-draft-run-\(UUID().uuidString).csv").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var direct = DirectDraftPath(controller: MailController.shared, reader: nil, enabled: true)
        direct.mailInfoPlist = "/nonexistent/Info.plist"   // version gate fails before anything is written
        let result = try await DirectDraftPath.createDraft(
            csvPath: path, directEnabled: true,
            direct: { await direct.attempt(to: ["a@example.org"], subject: "S", body: "B", cc: nil, bcc: nil,
                                           attachments: nil, format: .plain, fromAddress: "me@example.org") },
            gui: fakeGui(path))
        XCTAssertEqual(result, "GUI draft created"
            + " [experimental direct-write not used: Mail/macOS version outside the verified range (Mail 16, macOS 27) — GUI path]")

        let rows = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").dropFirst()
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(Set(rows.map { $0[0] }).count, 1, "one run_id for the whole call")
        XCTAssertEqual(rows.map { "\($0[10]):\($0[2])" },
                       ["direct:enter", "direct:eligibility", "direct:returned", "gui-mailto:enter", "gui-mailto:returned"])
        XCTAssertEqual(rows.first?[4], "0", "measured from the direct enter mark")
        XCTAssertTrue(rows.prefix(3).allSatisfy { $0[6] == "not_attempted:version" })
        XCTAssertTrue(rows.suffix(2).allSatisfy { $0[6] == "ok" })
        // ms_since_start keeps counting across the segment boundary: the GUI enter
        // row's offset is at least the direct returned row's.
        XCTAssertGreaterThanOrEqual(Int(rows[3][4])!, Int(rows[2][4])!)
    }

    func testACreatedDirectDraftSkipsTheGuiPath() async throws {
        var guiRan = false
        let result = try await DirectDraftPath.createDraft(
            csvPath: nil, directEnabled: true,
            direct: { .created("direct text", pending: false) },
            gui: { guiRan = true; return "gui" })
        XCTAssertEqual(result, "direct text")
        XCTAssertFalse(guiRan)
    }

    func testFlagOffRunsOnlyTheGuiPathWithNoNote() async throws {
        var directRan = false
        let result = try await DirectDraftPath.createDraft(
            csvPath: nil, directEnabled: false,
            direct: { directRan = true; return .created("x", pending: false) },
            gui: { "gui" })
        XCTAssertEqual(result, "gui")
        XCTAssertFalse(directRan)
    }

    // MARK: - #475 verify R2/R3: read status is reported from what was observed

    func testReadOutcomeFollowsWhatWasObserved() {
        XCTAssertEqual(DirectDraftPath.readOutcome([true]), .confirmed)
        XCTAssertEqual(DirectDraftPath.readOutcome([nil, true]), .confirmed, "a transient unreadable look is retried")
        XCTAssertEqual(DirectDraftPath.readOutcome([false, false]), .stillUnread)
        XCTAssertEqual(DirectDraftPath.readOutcome([false, nil, nil]), .stillUnread, "an unread look is a real observation")
        XCTAssertEqual(DirectDraftPath.readOutcome([nil, nil, nil, nil]), .unknown)
        XCTAssertEqual(DirectDraftPath.readOutcome([]), .unknown)
        // R3 (Codex): after a repair, eight unreadable looks are NOT "still unread".
        XCTAssertEqual(DirectDraftPath.readOutcome(Array(repeating: nil, count: 8)), .unknown)
    }

    func testReadOutcomeNotes() {
        XCTAssertEqual(DirectDraftPath.ReadOutcome.confirmed.note, "")
        XCTAssertEqual(DirectDraftPath.ReadOutcome.stillUnread.note,
                       " [note: the draft is uploaded but still shows as unread locally]")
        XCTAssertEqual(DirectDraftPath.ReadOutcome.unknown.note,
                       " [note: the draft is uploaded but its local read status could not be read]")
    }

    // MARK: - #475 verify R3: a failed upload request is only "created" when Mail has the draft

    func testFailedTriggerWithSuccessfulRollbackFallsBack() {
        let outcome = DirectDraftPath.outcomeAfterFailedTrigger(rollbackError: nil, triggerError: "timeout")
        XCTAssertEqual(outcome.timingCode, "fell_back:trigger")
        guard case .fellBack(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("timeout"))
    }

    func testFailedTriggerWithAnUploadedDraftIsCreated() {
        let outcome = DirectDraftPath.outcomeAfterFailedTrigger(
            rollbackError: DraftStoreWriter.WriteError.alreadyUploaded, triggerError: "timeout")
        XCTAssertEqual(outcome.timingCode, "created")
    }

    func testFailedTriggerWithAFailedRollbackIsPendingNotUploaded() {
        let outcome = DirectDraftPath.outcomeAfterFailedTrigger(
            rollbackError: DraftStoreWriter.WriteError.sql("database is locked"), triggerError: "timeout")
        XCTAssertEqual(outcome.timingCode, "created:upload_pending")
        guard case .created(let text, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(text.contains("uploaded "), "must not claim an upload nobody confirmed: \(text)")
        XCTAssertTrue(text.contains("could not be reversed"), text)
    }

    func testFallbackNoteFormat() {
        XCTAssertEqual(DirectDraftPath.fallbackNote("cc/bcc are not written directly"),
                       " [experimental direct-write not used: cc/bcc are not written directly — GUI path]")
    }
}
