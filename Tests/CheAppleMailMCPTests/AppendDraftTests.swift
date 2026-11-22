import MCP
import SwiftMail
import XCTest
@testable import CheAppleMailMCP

/// #744 — `append_draft`: the message the tool builds, the three outcomes of
/// the APPEND, and the tool around them. A stand-in server; no keychain, no
/// network, no Mail.
final class AppendDraftTests: XCTestCase {

    private typealias FakeSession = SendDraftFlowTests.FakeSession

    private let accountID = "AAAAAAAA-2222-4333-8444-555555555555"
    private let config = """
    {"accounts": [{"account_id": "AAAAAAAA-2222-4333-8444-555555555555", "address": "me@icloud.example",
      "smtp": {"host": "smtp.example", "port": 587}, "imap": {"host": "imap.example", "port": 993},
      "sent_copy": "append", "allowed_from": []}]}
    """

    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let fixedID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    private func message(fromName: String? = nil, to: [String] = ["a@x.example"], cc: [String] = [],
                         bcc: [String] = [], subject: String = "Hello", body: String = "Line one\nLine two") -> DraftMessage.Built {
        DraftMessage.build(fromName: fromName, fromAddress: "me@icloud.example", to: to, cc: cc, bcc: bcc,
                           subject: subject, body: body, date: fixedDate, messageIDLocalPart: fixedID,
                           timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
    }

    private func text(_ built: DraftMessage.Built) -> String { String(decoding: built.mime, as: UTF8.self) }

    private func headerBlock(_ built: DraftMessage.Built) -> String {
        text(built).components(separatedBy: "\r\n\r\n").first ?? ""
    }

    private func bodyBlock(_ built: DraftMessage.Built) -> String {
        let whole = text(built)
        guard let range = whole.range(of: "\r\n\r\n") else { return "" }
        return String(whole[range.upperBound...])
    }

    // MARK: - The message

    func testEveryLineEndsWithCRLF_andNoBareLineFeedRemains() {
        let built = message(body: "one\ntwo\r\nthree\rfour")
        let bytes = [UInt8](built.mime)
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            XCTAssertTrue(index > 0 && bytes[index - 1] == 0x0D, "a line feed without a carriage return at \(index)")
        }
        for (index, byte) in bytes.enumerated() where byte == 0x0D {
            XCTAssertTrue(index + 1 < bytes.count && bytes[index + 1] == 0x0A, "a carriage return without a line feed at \(index)")
        }
    }

    func testTheHeadersAreTheOnesASentPlainMessageCarries() throws {
        let built = message(fromName: "Che", to: ["a@x.example", "b@x.example"], cc: ["c@x.example"], bcc: ["d@x.example"])
        let fields = try BccRemoval.fields(in: built.mime)
        let names = fields.map { $0.name.lowercased() }
        XCTAssertEqual(Set(names), ["from", "to", "cc", "bcc", "subject", "date", "message-id", "mime-version",
                                    "content-type", "content-transfer-encoding"])
        XCTAssertEqual(names.count, Set(names).count, "a header appears twice")
        func value(_ name: String) -> String? { fields.first { $0.name.lowercased() == name }?.value.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(value("from"), "Che <me@icloud.example>")
        XCTAssertEqual(value("to"), "a@x.example, b@x.example")
        XCTAssertEqual(value("cc"), "c@x.example")
        XCTAssertEqual(value("bcc"), "d@x.example")
        XCTAssertEqual(value("message-id"), "<11111111-2222-4333-8444-555555555555@icloud.example>")
        XCTAssertEqual(built.messageID, "<11111111-2222-4333-8444-555555555555@icloud.example>")
        XCTAssertEqual(value("date"), "Fri, 15 Jan 2027 16:00:00 +0800")
        XCTAssertEqual(value("mime-version"), "1.0")
    }

    func testEmptyCcAndBccLeaveNoField() throws {
        let names = try BccRemoval.fields(in: message().mime).map { $0.name.lowercased() }
        XCTAssertFalse(names.contains("cc"))
        XCTAssertFalse(names.contains("bcc"))
    }

    func testTheMessageIsNotInMailsDraftLayout() {
        let headers = headerBlock(message()).lowercased()
        XCTAssertFalse(headers.contains("x-uniform-type-identifier"), "the draft marker would reach the recipient (#745)")
        XCTAssertFalse(headers.contains("x-apple-"))
        XCTAssertFalse(headers.contains("multipart"))
        XCTAssertTrue(headers.contains("content-type: text/plain; charset=utf-8"))
    }

    func testAShortASCIIBodyGoesOutAs7bit_withItsLineEndingsNormalised() {
        let built = message(body: "one\ntwo\r\nthree")
        XCTAssertTrue(headerBlock(built).contains("Content-Transfer-Encoding: 7bit"))
        XCTAssertEqual(bodyBlock(built), "one\r\ntwo\r\nthree\r\n")
    }

    func testANonASCIIBodyGoesOutAsBase64_inLinesOf76_andDecodesToTheBody() throws {
        let body = String(repeating: "這是一封測試信。", count: 40) + "\n第二行"
        let built = message(body: body)
        XCTAssertTrue(headerBlock(built).contains("Content-Transfer-Encoding: base64"))
        let lines = bodyBlock(built).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertTrue(lines.allSatisfy { $0.utf8.count <= 76 })
        let decoded = try XCTUnwrap(Data(base64Encoded: lines.joined()))
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), body.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n")
    }

    func testAnASCIIBodyWithALineOverTheLimitGoesOutAsBase64() {
        let built = message(body: String(repeating: "a", count: 1200))
        XCTAssertTrue(headerBlock(built).contains("Content-Transfer-Encoding: base64"))
        XCTAssertTrue(text(built).components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 998 })
    }

    func testANonASCIISubjectAndNameAreEncodedWords_andNoHeaderLinePassesTheLimit() throws {
        let built = message(fromName: "鄭澈", subject: String(repeating: "測試主旨", count: 60))
        let headers = headerBlock(built)
        XCTAssertTrue(headers.contains("From: =?utf-8?B?"))
        XCTAssertTrue(headers.contains("Subject: =?utf-8?B?"))
        XCTAssertTrue(headers.unicodeScalars.allSatisfy { $0.isASCII })
        XCTAssertTrue(headers.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 998 })
        // Still one Subject field once unfolded.
        XCTAssertEqual(try BccRemoval.fields(in: built.mime).filter { $0.name.lowercased() == "subject" }.count, 1)
    }

    /// The words of a header value that are RFC 2047 `B` encoded words, decoded and joined.
    private func decodedWords(_ value: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"=\?utf-8\?B\?([A-Za-z0-9+/=]+)\?="#)
        var bytes = Data()
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            if let range = Range(match.range(at: 1), in: value), let data = Data(base64Encoded: String(value[range])) {
                bytes.append(data)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func testTheLongestAcceptedSubjectsAndNamesStayUnderTheLineLimit_andDecodeToThemselves() throws {
        let unbrokenASCII = String(repeating: "a", count: AppendDraftTool.maxSubjectOctets)
        let longCJKName = String(repeating: "鄭", count: AppendDraftTool.maxFromNameOctets / 3)
        let longASCIIName = String(repeating: "n", count: AppendDraftTool.maxFromNameOctets)
        for (subject, name) in [(unbrokenASCII, longCJKName), (String(repeating: "測", count: 600), longASCIIName)] {
            let built = message(fromName: name, subject: subject)
            XCTAssertTrue(headerBlock(built).components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 998 })
            let fields = try BccRemoval.fields(in: built.mime)
            let subjectValue = try XCTUnwrap(fields.first { $0.name.lowercased() == "subject" }?.value)
            let unfolded = subjectValue.replacingOccurrences(of: "\r\n", with: "")
            XCTAssertEqual(unfolded.contains("=?utf-8?B?") ? decodedWords(unfolded) : unfolded.trimmingCharacters(in: .whitespaces), subject)
            let fromValue = try XCTUnwrap(fields.first { $0.name.lowercased() == "from" }?.value)
            XCTAssertTrue(fromValue.hasSuffix("<me@icloud.example>"), fromValue)
            if name.unicodeScalars.allSatisfy({ $0.isASCII }) {
                XCTAssertTrue(fromValue.contains(name))
            } else {
                XCTAssertEqual(decodedWords(fromValue), name)
            }
        }
    }

    func testEachEncodedWordIsValidOnItsOwn_andAtMost75Characters() throws {
        let subject = String(repeating: "a測😀é", count: 120)
        let name = String(repeating: "鄭😀", count: 30)
        let fields = try BccRemoval.fields(in: message(fromName: name, subject: subject).mime)
        let word = try NSRegularExpression(pattern: #"^=\?utf-8\?B\?([A-Za-z0-9+/]+={0,2})\?=$"#)
        for (field, expected, suffix) in [("subject", subject, ""), ("from", name, " <me@icloud.example>")] {
            var value = try XCTUnwrap(fields.first { $0.name.lowercased() == field }?.value).trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(value.hasSuffix(suffix), value)
            value = String(value.dropLast(suffix.count))
            // Every whitespace-separated token of the field is one complete encoded word.
            let tokens = value.split(whereSeparator: { $0 == " " || $0 == "\r" || $0 == "\n" || $0 == "\t" }).map(String.init)
            XCTAssertGreaterThan(tokens.count, 1, field)
            var decoded = ""
            for token in tokens {
                XCTAssertLessThanOrEqual(token.count, 75, token)
                let range = NSRange(token.startIndex..., in: token)
                let match = try XCTUnwrap(word.firstMatch(in: token, range: range), "\(field): not a complete encoded word: \(token)")
                let payload = try XCTUnwrap(Range(match.range(at: 1), in: token).map { String(token[$0]) })
                let text = try XCTUnwrap(Data(base64Encoded: payload).flatMap { String(data: $0, encoding: .utf8) },
                                         "\(field): a character split across encoded words: \(token)")
                decoded += text
            }
            XCTAssertEqual(decoded, expected, field)
        }
    }

    func testABodyOfLineBreaksAndMixedEndingsIsNormalised() {
        let built = message(body: String(repeating: "\n", count: 1_000_000))
        XCTAssertTrue(headerBlock(built).contains("Content-Transfer-Encoding: 7bit"))
        XCTAssertEqual(bodyBlock(built).utf8.count, 2_000_000)
        let mixed = message(body: "a\r\n\r\rb\n")
        XCTAssertEqual(bodyBlock(mixed), "a\r\n\r\n\r\nb\r\n")
    }

    func testManyRecipientsFoldWithoutSplittingAnAddress() throws {
        let many = (0..<80).map { "recipient-number-\($0)@a-rather-long-domain.example" }
        let built = message(to: many)
        XCTAssertTrue(headerBlock(built).components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 998 })
        let to = try XCTUnwrap(BccRemoval.fields(in: built.mime).first { $0.name.lowercased() == "to" })
        XCTAssertEqual(BccRemoval.addressList(inFieldValue: to.value), 80)
    }

    // MARK: - Validation

    private func refusal(to: [String] = ["a@x.example"], cc: [String] = [], bcc: [String] = [],
                         subject: String = "Hello", body: String = "b", fromName: String? = nil) -> String? {
        AppendDraftTool.refusal(to: to, cc: cc, bcc: bcc, subject: subject, body: body, fromName: fromName)
    }

    func testAnAcceptableCallHasNoRefusal() {
        XCTAssertNil(refusal(to: ["a@x.example"], cc: ["b@x.example"], bcc: ["c@x.example"], fromName: "鄭澈 Che"))
        XCTAssertNil(refusal(to: [], bcc: ["c@x.example"]), "a draft with only a Bcc recipient is a draft")
    }

    func testNoRecipientAtAllIsRefused() {
        XCTAssertTrue(refusal(to: [])?.contains("at least one recipient") == true)
    }

    func testAnEmptySubjectIsRefused() {
        XCTAssertTrue(refusal(subject: "")?.contains("subject") == true)
    }

    func testAControlCharacterInAHeaderValueIsRefused() {
        for bad in ["Hello\r\nBcc: x@y.example", "Hello\nX: y", "Hello\u{0}", "Hello\u{7F}", "Tab\tbed"] {
            XCTAssertTrue(refusal(subject: bad)?.contains("control character") == true, bad.debugDescription)
            XCTAssertTrue(refusal(fromName: bad)?.contains("control character") == true, bad.debugDescription)
        }
    }

    func testOnlyBareAddressesAreAccepted() {
        for bad in ["Name <a@x.example>", "a@x.example, b@x.example", "a@x.example\r\nBcc: z@y.example", "not-an-address",
                    " a@x.example", String(repeating: "a", count: 250) + "@x.example"] {
            XCTAssertTrue(refusal(to: [bad])?.contains("bare address") == true, bad.debugDescription)
            XCTAssertTrue(refusal(cc: [bad])?.contains("bare address") == true, bad.debugDescription)
            XCTAssertTrue(refusal(bcc: [bad])?.contains("bare address") == true, bad.debugDescription)
        }
    }

    func testTheAddressGrammarIsTheSubsetTheSpecStates() {
        for good in ["a@x.example", "o'brien+tag@mail.x.example", "first.last@x-y.example", String(repeating: "a", count: 64) + "@x.example"] {
            XCTAssertTrue(AppendDraftTool.isBareAddress(good), good)
        }
        for bad in ["a@.example.com", "a@example..com", "a@example.com.", "a@-x.example", "a@x-.example", "a@localhost",
                    ".a@x.example", "a.@x.example", "a..b@x.example", String(repeating: "a", count: 65) + "@x.example",
                    "\"a b\"@x.example", "a@[192.0.2.1]", "ä@x.example", "a@x.exämple", "a@b@x.example",
                    "a@" + String(repeating: "x", count: 64) + ".example"] {
            XCTAssertFalse(AppendDraftTool.isBareAddress(bad), bad)
        }
    }

    func testTheSizeLimitsAreEnforced() {
        XCTAssertNil(refusal(subject: String(repeating: "s", count: AppendDraftTool.maxSubjectOctets)))
        XCTAssertTrue(refusal(subject: String(repeating: "s", count: AppendDraftTool.maxSubjectOctets + 1))?.contains("'subject' is longer") == true)
        XCTAssertNil(refusal(fromName: String(repeating: "n", count: AppendDraftTool.maxFromNameOctets)))
        XCTAssertTrue(refusal(fromName: String(repeating: "n", count: AppendDraftTool.maxFromNameOctets + 1))?.contains("'from_name' is longer") == true)
        XCTAssertTrue(refusal(body: String(repeating: "b", count: AppendDraftTool.maxBodyOctets + 1))?.contains("'body' is longer") == true)
        let many = (0..<AppendDraftTool.maxRecipients).map { "r\($0)@x.example" }
        XCTAssertNil(refusal(to: many))
        XCTAssertTrue(refusal(to: many, bcc: ["one-more@x.example"])?.contains("at most \(AppendDraftTool.maxRecipients) recipients") == true)
    }

    func testABodyWithANULIsRefused() {
        XCTAssertTrue(refusal(body: "a\u{0}b")?.contains("NUL") == true)
    }

    // MARK: - The flow

    private let account = DirectTransportConfig.Account(
        accountID: "AAAAAAAA-2222-4333-8444-555555555555", address: "me@icloud.example",
        smtp: .init(host: "smtp", port: 587), imap: .init(host: "imap", port: 993),
        sentCopy: .append, allowedFrom: [])

    private func run(_ session: FakeSession) async -> AppendDraftResult {
        await AppendDraftFlow(session: session).run(message())
    }

    func testAnAcceptedAppendReportsTheMailboxAndTheUID() async throws {
        let session = FakeSession()
        session.appendDraftOutcome = .appended(uid: 42, uidValidity: 9)
        let result = await run(session)
        XCTAssertEqual(result.outcome, .appended)
        XCTAssertEqual(result.mailbox, "Drafts")
        XCTAssertEqual(result.uid, 42)
        XCTAssertEqual(result.uidValidity, 9)
        XCTAssertEqual(result.messageID, "<11111111-2222-4333-8444-555555555555@icloud.example>")
        XCTAssertEqual(session.appendedDrafts.count, 1)
        XCTAssertEqual(session.appendedDrafts.first, message().mime, "the bytes appended are the bytes built")
        XCTAssertTrue(result.notes.contains(AppendDraftFlow.indexNoteAppended))
        XCTAssertTrue(result.notes.contains(AppendDraftFlow.notDeduplicatedNote), "a success also says a repeat adds a draft")
    }

    func testAnAppendWithoutUIDPLUSIsStillAppended_withNoUID() async throws {
        let session = FakeSession()
        session.appendDraftOutcome = .appended(uid: nil, uidValidity: nil)
        let result = await run(session)
        XCTAssertEqual(result.outcome, .appended)
        XCTAssertNil(result.uid)
    }

    func testARefusedAppendIsNotAppended_andIsNotLookedUp() async throws {
        let session = FakeSession()
        session.appendDraftOutcome = .notAppended(detail: "NO [OVERQUOTA]")
        let result = await run(session)
        XCTAssertEqual(result.outcome, .notAppended)
        XCTAssertNil(result.uid)
        XCTAssertFalse(session.calls.contains("searchMessageID"))
        XCTAssertTrue(result.notes.contains { $0.contains("NO [OVERQUOTA]") })
    }

    func testAnUnknownAppendThatTheServerThenShowsIsAppended_andSaysHowItWasEstablished() async throws {
        let session = FakeSession()
        session.appendDraftOutcome = .unknown(detail: "connection closed")
        session.storeDraftDespiteOutcome = true
        let result = await run(session)
        XCTAssertEqual(result.outcome, .appended)
        XCTAssertEqual(result.uid, 1)
        XCTAssertTrue(result.notes.contains { $0.contains("found it in the drafts mailbox") })
        XCTAssertFalse(result.notes.contains { $0.contains("reply") && $0.contains("not received") },
                       "an unrecognised error does not show that no reply arrived")
    }

    func testAnUnknownAppendThatIsNotFoundStaysUnknown_andIsNotRetried() async throws {
        let session = FakeSession()
        session.appendDraftOutcome = .unknown(detail: "connection closed")
        let result = await run(session)
        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertEqual(session.calls.filter { $0.hasPrefix("appendDraft") }.count, 1, "an unknown append is never repeated")
        XCTAssertTrue(result.notes.contains { $0.contains("not evidence") })
        XCTAssertTrue(result.notes.contains { $0.contains("If this draft was stored and a later call also stores one, there are two") },
                      "the warning is conditional on both calls storing a draft")
    }

    func testAnUnknownAppendWhoseLookupFailsStaysUnknown_andSaysTheSearchWasNotMade() async throws {
        let session = FakeSession()
        session.appendDraftOutcome = .unknown(detail: "timeout")
        session.searchError = SendDraftFlowTests.Boom()
        let result = await run(session)
        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertTrue(result.notes.contains { $0.contains("could not be made") }, "\(result.notes)")
        XCTAssertFalse(result.notes.contains { $0.contains("did not show it") }, "a failed search is not a search that found nothing")
        XCTAssertTrue(result.notes.contains(AppendDraftFlow.indexNoteUnknown))
    }

    func testAHitWhoseMessageIDOnlyContainsOursIsNotEvidence() async throws {
        let session = FakeSession()
        session.appendDraftOutcome = .unknown(detail: "timeout")
        session.nearMissHits = [DraftSummary(uid: 9, subject: "Hello",
                                             messageID: "<11111111-2222-4333-8444-555555555555@icloud.example.other>")]
        let result = await run(session)
        XCTAssertEqual(result.outcome, .unknown, "IMAP's header search matches substrings; only an exact Message-ID counts")
    }

    func testTheAppendAndTheSearchGoToTheMailboxTheServerMarksDrafts() async throws {
        let session = FakeSession()
        session.draftsMailboxName = "[Gmail]/Drafts"
        session.appendDraftOutcome = .unknown(detail: "timeout")
        let result = await run(session)
        XCTAssertEqual(result.mailbox, "[Gmail]/Drafts")
        XCTAssertTrue(session.calls.contains("appendDraft:[Gmail]/Drafts"), "\(session.calls)")
        XCTAssertEqual(session.searchedMailboxes, ["[Gmail]/Drafts"])
    }

    func testTwoHitsAfterAnUnknownAppendAreNotReadAsOneDraft() async throws {
        let session = FakeSession()
        session.appendDraftOutcome = .unknown(detail: "timeout")
        let id = message().messageID
        session.drafts = [
            FetchedDraft(uid: 3, message: Data(), messageID: id, subject: "Hello", from: [], recipients: [], hasInvalidRecipient: false),
            FetchedDraft(uid: 4, message: Data(), messageID: id, subject: "Hello", from: [], recipients: [], hasInvalidRecipient: false),
        ]
        let result = await run(session)
        XCTAssertEqual(result.outcome, .appended)
        XCTAssertNil(result.uid, "which of the two it is cannot be said")
    }

    func testNoDraftsMailboxIsNotAppended_withNoMailbox_andNothingIsSent() async {
        let session = FakeSession()
        session.draftsMailboxError = SendDraftRefusal(description: "the server marks no mailbox \\Drafts")
        let result = await run(session)
        XCTAssertEqual(result.outcome, .notAppended)
        XCTAssertNil(result.mailbox)
        XCTAssertTrue(result.notes.contains { $0.contains("\\Drafts") })
        XCTAssertTrue(session.appendedDrafts.isEmpty)
        XCTAssertFalse(session.calls.contains { $0.hasPrefix("appendDraft") })
    }

    // spec-example: direct-transport / append outcomes
    func testTheAppendOutcomesExample() async throws {
        struct Row {
            let reported: Result<AppendResult, Error>
            let stored: Bool
            let alreadyThere: Int
            let searchFails: Bool
            let outcome: AppendDraftResult.Outcome
            let uid: UInt32?
            let searches: Int
        }
        let rows: [(String, Row)] = [
            ("tagged OK with APPENDUID", Row(reported: .success(AppendResult(uidValidity: UIDValidity(9), uids: [UID(42)])), stored: true, alreadyThere: 0, searchFails: false, outcome: .appended, uid: 42, searches: 0)),
            ("tagged OK without APPENDUID", Row(reported: .success(AppendResult(uidValidity: nil, uids: [])), stored: true, alreadyThere: 0, searchFails: false, outcome: .appended, uid: nil, searches: 0)),
            ("tagged NO", Row(reported: .failure(IMAPError.commandFailed("no(OVERQUOTA)")), stored: false, alreadyThere: 0, searchFails: false, outcome: .notAppended, uid: nil, searches: 0)),
            ("over the size limit", Row(reported: .failure(IMAPError.appendLimitExceeded(10, 5)), stored: false, alreadyThere: 0, searchFails: false, outcome: .notAppended, uid: nil, searches: 0)),
            ("timeout, one hit", Row(reported: .failure(IMAPError.timeout), stored: true, alreadyThere: 0, searchFails: false, outcome: .appended, uid: 1, searches: 1)),
            ("timeout, two hits", Row(reported: .failure(IMAPError.timeout), stored: true, alreadyThere: 1, searchFails: false, outcome: .appended, uid: nil, searches: 1)),
            ("connection closed, the search fails", Row(reported: .failure(IMAPError.connectionFailed("closed")), stored: false, alreadyThere: 0, searchFails: true, outcome: .unknown, uid: nil, searches: 1)),
            ("timeout, no hit", Row(reported: .failure(IMAPError.timeout), stored: false, alreadyThere: 0, searchFails: false, outcome: .unknown, uid: nil, searches: 1)),
        ]
        for (name, row) in rows {
            let session = FakeSession()
            session.appendDraftOutcome = SwiftMailSession.classifyAppend(row.reported)
            if case .appended = session.appendDraftOutcome {} else { session.storeDraftDespiteOutcome = row.stored }
            if row.searchFails { session.searchError = SendDraftFlowTests.Boom() }
            for _ in 0..<row.alreadyThere {
                session.drafts.append(FetchedDraft(uid: 100, message: Data(), messageID: message().messageID, subject: "Hello",
                                                   from: [], recipients: [], hasInvalidRecipient: false))
            }
            let result = await run(session)
            XCTAssertEqual(result.outcome, row.outcome, name)
            XCTAssertEqual(result.uid, row.uid, name)
            XCTAssertEqual(session.calls.filter { $0.hasPrefix("appendDraft") }.count, 1, "\(name): exactly one APPEND")
            XCTAssertEqual(session.calls.filter { $0 == "searchMessageID" }.count, row.searches, name)
        }
    }

    // MARK: - The tool

    private final class Opened: @unchecked Sendable { var count = 0 }

    /// #748: the session's note on how the drafts mailbox was found reaches the
    /// result, also when the APPEND that follows is refused.
    func testTheSessionsMailboxNotesReachTheResult() async throws {
        for outcome: AppendOutcome in [.appended(uid: 3, uidValidity: 9), .notAppended(detail: "NO [OVERQUOTA]")] {
            let session = FakeSession()
            session.recordsLookupNotes = true
            session.appendDraftOutcome = outcome
            let text = try await AppendDraftTool.run(arguments(), try environment(config: config, session: session))
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let notes = try XCTUnwrap(object["notes"] as? [String])
            XCTAssertTrue(notes.contains("drafts lookup note"), "\(outcome): \(notes)")
        }
    }

    private func environment(config text: String?, password: String? = "secret-pw",
                             session: FakeSession = FakeSession(), opened: Opened = Opened()) throws -> AppendDraftTool.Environment {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("append-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        if let text { try Data(text.utf8).write(to: dir.appendingPathComponent(DirectTransportConfig.fileName)) }
        return AppendDraftTool.Environment(
            stateDirectory: dir,
            password: { _ in password },
            openSession: { _, _ in opened.count += 1; return session },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            newID: { UUID(uuidString: "11111111-2222-4333-8444-555555555555")! })
    }

    private func arguments(_ extra: [String: Value] = [:]) -> [String: Value] {
        var base: [String: Value] = ["account_id": .string(accountID), "to": .array([.string("a@x.example")]),
                                     "subject": .string("Hello"), "body": .string("Body")]
        for (key, value) in extra { base[key] = value }
        return base
    }

    private func failure(_ arguments: [String: Value], _ environment: AppendDraftTool.Environment) async -> String? {
        do { _ = try await AppendDraftTool.run(arguments, environment); return nil } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func testAnArgumentOutsideTheListIsRefusedByName_beforeAnyConnection() async throws {
        let opened = Opened()
        let env = try environment(config: config, opened: opened)
        for extra in ["attachments", "format", "from_address", "draft_id", "in_reply_to", "save_as_draft"] {
            let message = await failure(arguments([extra: .string("x")]), env)
            XCTAssertTrue(message?.contains("'\(extra)'") == true, "\(extra): \(message ?? "not refused")")
        }
        XCTAssertEqual(opened.count, 0)
    }

    func testArgumentsOfTheWrongTypeAreRefusedByName() async throws {
        let opened = Opened()
        let env = try environment(config: config, opened: opened)
        let cases: [(String, Value)] = [
            ("to", .string("a@x.example")), ("to", .array([.int(1)])), ("to", .null), ("cc", .array([.null])),
            ("bcc", .string("x")), ("subject", .null), ("subject", .int(3)), ("body", .null), ("from_name", .int(1)),
            ("account_id", .null),
        ]
        for (name, value) in cases {
            let message = await failure(arguments([name: value]), env)
            XCTAssertTrue(message?.contains("'\(name)'") == true, "\(name)=\(value): \(message ?? "not refused")")
        }
        XCTAssertEqual(opened.count, 0)
    }

    func testSubjectAndBodyAreRequired() async throws {
        let env = try environment(config: config)
        var noSubject = arguments(); noSubject["subject"] = nil
        var noBody = arguments(); noBody["body"] = nil
        let first = await failure(noSubject, env)
        XCTAssertTrue(first?.contains("subject") == true, first ?? "not refused")
        let second = await failure(noBody, env)
        XCTAssertTrue(second?.contains("body") == true, second ?? "not refused")
    }

    func testAnUnconfiguredAccountIsRefused_andNoMailPathIsUsed() async throws {
        let opened = Opened()
        let none = await failure(arguments(), try environment(config: nil, opened: opened))
        XCTAssertTrue(none?.contains("not configured") == true, none ?? "not refused")
        XCTAssertTrue(none?.contains("Nothing was appended") == true)
        let other = await failure(arguments(["account_id": .string("BBBBBBBB-2222-4333-8444-555555555555")]),
                                  try environment(config: config, opened: opened))
        XCTAssertTrue(other?.contains("not configured") == true, other ?? "not refused")
        XCTAssertEqual(opened.count, 0)
    }

    func testNoStoredCredentialNamesTheCommandLineMode_beforeAnyConnection() async throws {
        let opened = Opened()
        let message = await failure(arguments(), try environment(config: config, password: nil, opened: opened))
        XCTAssertTrue(message?.contains("--direct-transport-set-credential") == true, message ?? "not refused")
        XCTAssertEqual(opened.count, 0)
    }

    func testAContentRefusalHappensBeforeAnyConnection() async throws {
        let opened = Opened()
        let message = await failure(arguments(["to": .array([.string("Name <a@x.example>")])]),
                                    try environment(config: config, opened: opened))
        XCTAssertTrue(message?.contains("bare address") == true, message ?? "not refused")
        XCTAssertEqual(opened.count, 0)
    }

    func testTheResultIsJSONWithTheOutcomeAndTheMessageID() async throws {
        let session = FakeSession()
        session.appendDraftOutcome = .appended(uid: 42, uidValidity: 9)
        let text = try await AppendDraftTool.run(arguments(["from_name": .string("Che")]), try environment(config: config, session: session))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["outcome"] as? String, "appended")
        XCTAssertEqual(object["message_id"] as? String, "<11111111-2222-4333-8444-555555555555@icloud.example>")
        XCTAssertEqual(object["mailbox"] as? String, "Drafts")
        XCTAssertEqual(object["uid"] as? Int, 42)
        XCTAssertEqual(object["uid_validity"] as? Int, 9)
        XCTAssertNotNil(object["notes"] as? [String])
        let appended = try XCTUnwrap(session.appendedDrafts.first)
        XCTAssertTrue(String(decoding: appended, as: UTF8.self).contains("From: Che <me@icloud.example>\r\n"))
    }

    func testAnUnknownOutcomeIsAResult_notAnError_andCarriesNoUID() async throws {
        let session = FakeSession()
        session.appendDraftOutcome = .unknown(detail: "connection closed")
        let text = try await AppendDraftTool.run(arguments(), try environment(config: config, session: session))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["outcome"] as? String, "unknown")
        XCTAssertTrue(object["uid"] is NSNull)
    }

    func testAConnectionThatFailsIsNotAppended_asAResult() async throws {
        let dir = try environment(config: config).stateDirectory
        let env = AppendDraftTool.Environment(
            stateDirectory: dir, password: { _ in "secret-pw" },
            openSession: { _, _ in throw SwiftMailSession.Failure(description: "could not log in to the IMAP server imap.example:993 (timeout)") },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }, newID: { UUID() })
        let text = try await AppendDraftTool.run(arguments(), env)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["outcome"] as? String, "not_appended")
        XCTAssertTrue(object["mailbox"] is NSNull)
        XCTAssertTrue((object["notes"] as? [String])?.contains { $0.contains("could not log in") } == true)
    }

    func testASecondDirectTransportCallIsRefusedBeforeItConnects() async throws {
        let opened = Opened()
        let env = try environment(config: config, opened: opened)
        try await SendRecordStore(directory: env.stateDirectory).withSubmissionLock {
            let message = await failure(arguments(), env)
            XCTAssertTrue(message?.contains("another send_draft or append_draft call is running") == true, message ?? "not refused")
        }
        XCTAssertEqual(opened.count, 0)
    }

    private struct Leak: Error, CustomStringConvertible { var description: String { "server said: bad password secret-pw" } }

    func testThePasswordIsRemovedFromEveryResult_whateverTheErrorSource() async throws {
        // The connection fails.
        let dir = try environment(config: config).stateDirectory
        let failing = AppendDraftTool.Environment(
            stateDirectory: dir, password: { _ in "secret-pw" }, openSession: { _, _ in throw Leak() },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }, newID: { UUID() })
        let first = try await AppendDraftTool.run(arguments(), failing)
        XCTAssertFalse(first.contains("secret-pw"), first)
        XCTAssertTrue(first.contains("not_appended"))
        // Finding the drafts mailbox fails.
        let noDrafts = FakeSession()
        noDrafts.draftsMailboxError = Leak()
        let second = try await AppendDraftTool.run(arguments(), try environment(config: config, session: noDrafts))
        XCTAssertFalse(second.contains("secret-pw"), second)
        // The APPEND is unknown and the search fails.
        let lostSearch = FakeSession()
        lostSearch.appendDraftOutcome = .unknown(detail: "timeout after secret-pw")
        lostSearch.searchError = Leak()
        let third = try await AppendDraftTool.run(arguments(), try environment(config: config, session: lostSearch))
        XCTAssertFalse(third.contains("secret-pw"), third)
        XCTAssertTrue(third.contains("could not be made"))
    }

    func testTheLockIsHeldUntilTheConnectionIsClosed() async throws {
        let session = FakeSession()
        let opened = Opened()
        let env = try environment(config: config, session: session, opened: opened)
        final class Box: @unchecked Sendable { var message: String? }
        let box = Box()
        session.onClose = { [self] in
            session.onClose = nil
            box.message = await self.failure(self.arguments(), env)
        }
        _ = try await AppendDraftTool.run(arguments(), env)
        XCTAssertTrue(box.message?.contains("another send_draft or append_draft call is running") == true, box.message ?? "the second call ran")
        XCTAssertEqual(opened.count, 1, "the second call opened no connection")
    }

    func testTheServersMailboxNameIsRedactedInTheResult() async throws {
        let session = FakeSession()
        session.draftsMailboxName = "Drafts-secret-pw"
        let text = try await AppendDraftTool.run(arguments(), try environment(config: config, session: session))
        XCTAssertFalse(text.contains("secret-pw"), text)
        let shown = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["mailbox"] as? String)
        XCTAssertTrue(shown.hasPrefix("Drafts-") && shown != "Drafts-secret-pw", "the result keeps a redacted name: \(shown)")
        XCTAssertTrue(session.calls.contains("appendDraft:Drafts-secret-pw"), "the real name is still the one appended to")
    }

    func testTooManyRecipientsAcrossTheListsAreRefusedBeforeTheirElementsAreRead() async throws {
        let opened = Opened()
        let third = AppendDraftTool.maxRecipients / 3 + 1
        func list(_ prefix: String) -> Value { .array((0..<third).map { .string("\(prefix)\($0)@x.example") }) }
        // Each list is under the cap, the total is over it, and one element is not even a string.
        var bcc = (0..<third).map { Value.string("b\($0)@x.example") }
        bcc[0] = .int(7)
        let message = await failure(arguments(["to": list("t"), "cc": list("c"), "bcc": .array(bcc)]),
                                    try environment(config: config, opened: opened))
        XCTAssertTrue(message?.contains("at most \(AppendDraftTool.maxRecipients) recipients") == true, message ?? "not refused")
        XCTAssertEqual(opened.count, 0)
    }

    func testEveryCallHasItsOwnMessageID() async throws {
        let session = FakeSession()
        let dir = try environment(config: config).stateDirectory
        let env = AppendDraftTool.Environment(
            stateDirectory: dir, password: { _ in "secret-pw" }, openSession: { _, _ in session },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }, newID: UUID.init)
        var ids: [String] = []
        for _ in 0..<2 {
            let text = try await AppendDraftTool.run(arguments(), env)
            ids.append(try XCTUnwrap((JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["message_id"] as? String))
        }
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(Set(session.drafts.compactMap(\.messageID)), Set(ids), "two drafts, each findable by its own Message-ID")
    }

    func testAnArgumentNameIsShownWithoutItsControlCharacters() async throws {
        let message = await failure(arguments(["x\r\ny": .string("v")]), try environment(config: config))
        XCTAssertTrue(message?.contains("'x??y'") == true, message ?? "not refused")
        XCTAssertFalse(message?.contains("\r\n") == true)
    }

    func testADraftAppendedHereIsSentByItsMessageID_withMailClosed() async throws {
        let session = FakeSession()
        let env = try environment(config: config, session: session)
        let appended = try await AppendDraftTool.run(arguments(["to": .array([.string("a@x.example")]),
                                                                "bcc": .array([.string("hidden@x.example")])]), env)
        let id = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(appended.utf8)) as? [String: Any])?["message_id"] as? String)
        let send = SendDraftTool.Environment(
            stateDirectory: env.stateDirectory, password: { _ in "secret-pw" }, openSession: { _, _ in session },
            localMessageID: { _ in XCTFail("the local store was read"); return nil }, now: env.now)
        let sent = try await SendDraftTool.run(["account_id": .string(accountID), "message_id": .string(id)], send)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        XCTAssertEqual(object["outcome"] as? String, "submitted", sent)
        XCTAssertEqual(session.submitted.count, 1)
        let submission = try XCTUnwrap(session.submitted.first)
        XCTAssertEqual(Set(submission.to), ["a@x.example", "hidden@x.example"])
        XCTAssertFalse(String(decoding: submission.message, as: UTF8.self).lowercased().contains("\r\nbcc:"),
                       "the Bcc field does not reach the recipients")
        XCTAssertEqual(submission.from, "me@icloud.example")
    }

    func testTheDescriptionCarriesTheCaveats() {
        let description = AppendDraftTool.description
        XCTAssertTrue(description.contains("NOT YET RUN AGAINST A REAL MAIL SERVER"))
        XCTAssertTrue(description.contains("#744"))
        XCTAssertTrue(description.contains("if two calls both store their drafts, there are two drafts"))
        XCTAssertTrue(description.contains("no Mail path is used instead"))
    }

    func testTheToolIsListedAsPreparingMail_likeCreateDraft_notSending() {
        XCTAssertEqual(ToolAccess.of("append_draft"), .prepareMail)
        XCTAssertEqual(ToolAccess.of("append_draft"), ToolAccess.of("create_draft"))
        let hints = ToolAccess.prepareMail.annotations
        XCTAssertEqual(hints.readOnlyHint, false)
        XCTAssertEqual(hints.destructiveHint, false)
        XCTAssertEqual(hints.idempotentHint, false)
        XCTAssertEqual(hints.openWorldHint, true)
    }

    // MARK: - What SwiftMail reports for an APPEND

    func testOnlyAServerRefusalOrALocalLimitIsProvablyNotAppended() {
        func outcome(_ error: Error) -> AppendOutcome { SwiftMailSession.classifyAppend(.failure(error)) }
        if case .notAppended = outcome(IMAPError.commandFailed("no(...)")) {} else { XCTFail("a tagged NO is a refusal") }
        if case .notAppended = outcome(IMAPError.appendLimitExceeded(10, 5)) {} else { XCTFail("the size limit is checked before anything is sent") }
        for error: Error in [IMAPError.connectionFailed("closed"), IMAPError.timeout, SendDraftFlowTests.Boom()] {
            if case .unknown = outcome(error) {} else { XCTFail("\(error) does not prove the draft was not stored") }
        }
    }

    func testASuccessfulAppendCarriesTheServersUID_whenItGivesOne() {
        let with = SwiftMailSession.classifyAppend(.success(AppendResult(uidValidity: UIDValidity(9), uids: [UID(42)])))
        XCTAssertEqual(with, .appended(uid: 42, uidValidity: 9))
        let without = SwiftMailSession.classifyAppend(.success(AppendResult(uidValidity: nil, uids: [])))
        XCTAssertEqual(without, .appended(uid: nil, uidValidity: nil))
    }
}
