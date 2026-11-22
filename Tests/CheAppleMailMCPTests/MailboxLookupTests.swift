import XCTest
@testable import CheAppleMailMCP

/// #748 — how the drafts and sent mailboxes are found. One test per row of the
/// decision table in `MailboxLookup`.
final class MailboxLookupTests: XCTestCase {

    private let listed = ["INBOX", "Drafts", "Sent Messages", "Deleted Messages", "Archive"]

    /// Counts how often the server was asked for its special-use mailboxes.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func note() { lock.lock(); count += 1; lock.unlock() }
        var times: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func resolve(_ role: MailboxLookup.Role = .drafts, marked: [String] = [], advertises: Bool = false,
                         onRequest: [String] = [], declared: String? = nil, listed: [MailboxLookup.Listed]? = nil,
                         asked: Asked = Asked(), capabilities: Asked = Asked()) async throws -> MailboxLookup.Found {
        try await MailboxLookup.resolve(role, listed: listed ?? self.listed.map { .init(name: $0, selectable: true) },
                                        markedInList: marked.map { .init(name: $0, selectable: true) }, declared: declared,
                                        advertisesSpecialUse: { capabilities.note(); return advertises }) {
            asked.note()
            return onRequest.map { .init(name: $0, selectable: true) }
        }
    }

    private func refusal(_ body: () async throws -> MailboxLookup.Found,
                         file: StaticString = #filePath, line: UInt = #line) async -> String {
        do {
            let found = try await body()
            XCTFail("expected a refusal, found \(found)", file: file, line: line)
            return ""
        } catch let refusal as SendDraftRefusal {
            return refusal.description
        } catch {
            XCTFail("expected a SendDraftRefusal, got \(error)", file: file, line: line)
            return ""
        }
    }

    // MARK: Row 1 and 2 — the plain list

    func testTheMailboxThePlainListMarksIsUsed_withoutAskingAgain() async throws {
        let asked = Asked()
        let found = try await resolve(marked: ["Drafts"], advertises: true, asked: asked)
        XCTAssertEqual(found.name, "Drafts")
        XCTAssertEqual(found.source, .plainList)
        XCTAssertEqual(asked.times, 0)
        XCTAssertTrue(found.note.contains("\\Drafts"))
        XCTAssertFalse(found.note.contains("direct-transport.json"))
    }

    func testTwoMailboxesMarkedInThePlainListAreRefused() async {
        let asked = Asked()
        let text = await refusal { try await self.resolve(marked: ["Drafts", "Archive"], advertises: true,
                                                         declared: "Drafts", asked: asked) }
        XCTAssertTrue(text.contains("marks 2 mailboxes \\Drafts"), text)
        XCTAssertTrue(text.contains("lists 5 mailboxes; SPECIAL-USE was not checked"), text)
        XCTAssertTrue(text.contains("nothing was submitted"), text)
        XCTAssertEqual(asked.times, 0)
    }

    // MARK: Row 3 — asking for special-use mailboxes

    func testAServerThatAdvertisesSpecialUseIsAskedOnce_whenItsPlainListMarkedNone() async throws {
        let asked = Asked()
        let found = try await resolve(advertises: true, onRequest: ["Drafts"], asked: asked)
        XCTAssertEqual(found.name, "Drafts")
        XCTAssertEqual(found.source, .explicitRequest)
        XCTAssertEqual(asked.times, 1)
        XCTAssertTrue(found.note.contains("SPECIAL-USE"), found.note)
    }

    func testAServerThatDoesNotAdvertiseSpecialUseIsNeverAsked() async {
        // SwiftMail's special-use listing guesses from mailbox names when the
        // server does not advertise the extension, so it must not be called.
        let asked = Asked()
        _ = await refusal { try await self.resolve(advertises: false, onRequest: ["Drafts"], asked: asked) }
        XCTAssertEqual(asked.times, 0)
        let withConfiguration = Asked()
        _ = try? await resolve(advertises: false, onRequest: ["Archive"], declared: "Drafts", asked: withConfiguration)
        XCTAssertEqual(withConfiguration.times, 0)
    }

    func testTwoMailboxesMarkedOnRequestAreRefused() async {
        let text = await refusal { try await self.resolve(advertises: true, onRequest: ["Drafts", "Archive"],
                                                         declared: "Drafts") }
        XCTAssertTrue(text.contains("marks 2 mailboxes \\Drafts"), text)
    }

    // MARK: Row 4 — the name in direct-transport.json

    func testTheConfiguredNameIsUsedWhenTheServerMarksNone() async throws {
        for advertises in [false, true] {
            let found = try await resolve(advertises: advertises, declared: "Drafts")
            XCTAssertEqual(found.name, "Drafts")
            XCTAssertEqual(found.source, .configuration)
            XCTAssertTrue(found.note.contains("drafts_mailbox"), found.note)
            XCTAssertTrue(found.note.contains(advertises ? "mailboxes and advertises SPECIAL-USE" : "mailboxes and does not advertise SPECIAL-USE"),
                          found.note)
            XCTAssertTrue(found.note.contains("5 mailboxes"), found.note)
        }
    }

    func testAConfiguredNameTheServerDoesNotListIsRefused_andLetterCaseCounts() async {
        for name in ["DRAFTS", "archive", " Archive", "Entwürfe"] {
            let text = await refusal { try await self.resolve(declared: name) }
            XCTAssertTrue(text.contains("`drafts_mailbox`"), text)
            XCTAssertTrue(text.contains("does not list"), text)
            XCTAssertTrue(text.contains("nothing was submitted"), text)
            XCTAssertFalse(text.contains(name), "the configured name is not echoed: \(text)")
        }
    }

    // MARK: Row 5 — nothing to go by

    func testWithNoMarkAndNoConfiguredNameTheCallIsRefused_sayingWhatWasSeen() async {
        for advertises in [false, true] {
            let text = await refusal { try await self.resolve(advertises: advertises) }
            XCTAssertTrue(text.contains("marks no mailbox \\Drafts"), text)
            XCTAssertTrue(text.contains("lists 5 mailboxes"), text)
            XCTAssertTrue(text.contains(advertises ? "mailboxes and advertises SPECIAL-USE" : "mailboxes and does not advertise SPECIAL-USE"), text)
            XCTAssertTrue(text.contains("`drafts_mailbox`"), text)
            XCTAssertTrue(text.contains("nothing was submitted"), text)
            for name in ["Sent Messages", "Deleted Messages", "Archive"] {
                XCTAssertFalse(text.contains(name), "no mailbox name from the server is echoed: \(text)")
            }
        }
    }

    // MARK: The server's mark comes first

    func testTheServersMarkWinsOverADifferentConfiguredName_andTheNoteSaysSo() async throws {
        let plain = try await resolve(marked: ["Drafts"], declared: "Archive")
        XCTAssertEqual(plain.name, "Drafts")
        XCTAssertEqual(plain.source, .plainList)
        XCTAssertTrue(plain.note.contains("`drafts_mailbox`"), plain.note)
        XCTAssertTrue(plain.note.contains("does not exactly match"), plain.note)
        XCTAssertFalse(plain.note.contains("Archive"), plain.note)

        let requested = try await resolve(advertises: true, onRequest: ["Drafts"], declared: "Archive")
        XCTAssertEqual(requested.name, "Drafts")
        XCTAssertTrue(requested.note.contains("does not exactly match"), requested.note)
    }

    func testAConfiguredNameThatAgreesWithTheServerAddsNothing() async throws {
        let found = try await resolve(marked: ["Drafts"], declared: "Drafts")
        XCTAssertFalse(found.note.contains("does not exactly match"), found.note)
    }

    // MARK: The sent mailbox

    func testTheSentMailboxUsesItsOwnAttributeKeyAndConsequence() async throws {
        let found = try await resolve(.sent, declared: "Sent Messages")
        XCTAssertEqual(found.name, "Sent Messages")
        XCTAssertTrue(found.note.contains("sent_mailbox"), found.note)
        XCTAssertTrue(found.note.contains("\\Sent"), found.note)

        let text = await refusal { try await self.resolve(.sent) }
        XCTAssertTrue(text.contains("marks no mailbox \\Sent"), text)
        XCTAssertTrue(text.contains("`sent_mailbox`"), text)
        XCTAssertTrue(text.contains("the sent copy was not stored"), text)
        XCTAssertFalse(text.contains("nothing was submitted"), text)
    }

    // MARK: Round 1 of the review

    func testADecisivePlainListNeverAsksForCapabilities() async throws {
        struct Broken: Error {}
        for marked in [["Drafts"], ["Drafts", "Archive"]] {
            let capabilities = Asked()
            _ = try? await resolve(marked: marked, capabilities: capabilities)
            XCTAssertEqual(capabilities.times, 0, "\(marked)")
            do {
                let found = try await MailboxLookup.resolve(.drafts, listed: listed.map { .init(name: $0, selectable: true) },
                                                            markedInList: marked.map { .init(name: $0, selectable: true) }, declared: nil,
                                                            advertisesSpecialUse: { throw Broken() }) { throw Broken() }
                XCTAssertEqual(found.name, "Drafts")
            } catch let refusal as SendDraftRefusal {
                XCTAssertEqual(marked.count, 2)
                XCTAssertTrue(refusal.description.contains("marks 2 mailboxes"), refusal.description)
            } catch {
                XCTFail("the capabilities were asked for: \(error)")
            }
        }
    }

    func testCapabilitiesAreAskedForOnceAtMost() async throws {
        let capabilities = Asked()
        _ = try? await resolve(advertises: true, onRequest: [], declared: "Drafts", capabilities: capabilities)
        XCTAssertEqual(capabilities.times, 1)
    }

    func testTheConfiguredNameIsComparedScalarByScalar_andTheServersSpellingIsUsed() async throws {
        let composed = "Entw\u{00FC}rfe", decomposed = "Entwu\u{0308}rfe"
        XCTAssertEqual(composed, decomposed, "Swift's == would treat them as one name")
        let onServer: [MailboxLookup.Listed] = [.init(name: decomposed, selectable: true), .init(name: "INBOX", selectable: true)]
        let text = await refusal { try await self.resolve(declared: composed, listed: onServer) }
        XCTAssertTrue(text.contains("does not list"), text)
        let found = try await resolve(declared: decomposed, listed: onServer)
        XCTAssertTrue(found.name.unicodeScalars.elementsEqual(decomposed.unicodeScalars))
    }

    func testAServerMarkThatDiffersOnlyInScalarsFromTheKeyIsReportedAsADisagreement() async throws {
        let found = try await resolve(marked: ["Entwu\u{0308}rfe"], declared: "Entw\u{00FC}rfe")
        XCTAssertTrue(found.note.contains("does not exactly match"), found.note)
    }

    func testTwoListedMailboxesWithTheConfiguredNameAreRefusedAsAmbiguous() async {
        let twice: [MailboxLookup.Listed] = [.init(name: "Drafts", selectable: true), .init(name: "Drafts", selectable: true)]
        let text = await refusal { try await self.resolve(declared: "Drafts", listed: twice) }
        XCTAssertTrue(text.contains("more than one"), text)
        XCTAssertFalse(text.contains("does not list"), text)
    }

    func testAConfiguredNameThatCannotBeSelectedIsRefused() async {
        let placeholder: [MailboxLookup.Listed] = [.init(name: "Brouillons", selectable: false)]
        let text = await refusal { try await self.resolve(declared: "Brouillons", listed: placeholder) }
        XCTAssertTrue(text.contains("cannot be selected"), text)
        XCTAssertFalse(text.contains("Brouillons"), text)
    }

    // MARK: Round 2 of the review

    func testCapabilitiesThatCannotBeReadRefuseTheCall_evenWithAListedConfiguredName() async {
        struct Broken: Error, CustomStringConvertible { var description: String { "CAPABILITY timed out: IMAP4rev1 SPECIAL-USE Drafts" } }
        let asked = Asked()
        defer { XCTAssertEqual(asked.times, 0, "no special-use request after the capabilities failed") }
        do {
            _ = try await MailboxLookup.resolve(.drafts, listed: listed.map { .init(name: $0, selectable: true) },
                                                markedInList: [], declared: "Drafts",
                                                advertisesSpecialUse: { throw Broken() }) { asked.note(); return [] }
            XCTFail("expected a refusal")
        } catch let refusal as SendDraftRefusal {
            XCTAssertTrue(refusal.description.contains("capabilities could not be read"), refusal.description)
            XCTAssertFalse(refusal.description.contains("timed out"), "no server or library text: \(refusal.description)")
            XCTAssertTrue(refusal.description.contains("lists 5 mailboxes"), refusal.description)
            XCTAssertTrue(refusal.description.contains("nothing was submitted"), refusal.description)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAServerMarkThatCannotBeSelectedIsRefused_withoutFallingBackToTheConfiguredName() async {
        let placeholder = MailboxLookup.Listed(name: "Brouillons", selectable: false)
        let usable = listed.map { MailboxLookup.Listed(name: $0, selectable: true) }
        for viaRequest in [false, true] {
            let capabilities = Asked(), requests = Asked()
            defer {
                XCTAssertEqual(capabilities.times, viaRequest ? 1 : 0, "viaRequest: \(viaRequest)")
                XCTAssertEqual(requests.times, viaRequest ? 1 : 0, "viaRequest: \(viaRequest)")
            }
            do {
                _ = try await MailboxLookup.resolve(.drafts, listed: usable + [placeholder],
                                                    markedInList: viaRequest ? [] : [placeholder], declared: "Drafts",
                                                    advertisesSpecialUse: { capabilities.note(); return true }) { requests.note(); return [placeholder] }
                XCTFail("expected a refusal (viaRequest: \(viaRequest))")
            } catch let refusal as SendDraftRefusal {
                XCTAssertTrue(refusal.description.contains("cannot be selected"), refusal.description)
                XCTAssertFalse(refusal.description.contains("Brouillons"), refusal.description)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func testTheSameMailboxGuardIgnoresASCIICase_soItErrsTowardKeepingTheDraft() {
        // Over-matching only leaves the stages pending; missing a match can lose the only copy.
        XCTAssertTrue(MailboxLookup.sameMailbox("INBOX", "Inbox"))
        XCTAssertTrue(MailboxLookup.sameMailbox("INBOX.Sent", "inbox.sent"))
        XCTAssertTrue(MailboxLookup.sameMailbox("Drafts", "drafts"))
        XCTAssertTrue(MailboxLookup.sameMailbox("Entwu\u{0308}rfe", "Entwu\u{0308}rfe"))
        XCTAssertFalse(MailboxLookup.sameMailbox("Drafts", "Sent Messages"))
        XCTAssertTrue(MailboxLookup.sameMailbox("Entw\u{00FC}rfe", "Entwu\u{0308}rfe"), "a server may normalise; the guard errs toward keeping")
        XCTAssertFalse(MailboxLookup.sameName("Entw\u{00FC}rfe", "Entwu\u{0308}rfe"), "configured names still match scalar by scalar")
    }

    func testAFailedSpecialUseRequestRefusesWithWhatIsKnown_andNoFallback() async {
        struct Broken: Error, CustomStringConvertible { var description: String { "NO LIST failed for \"Brouillons\"" } }
        do {
            _ = try await MailboxLookup.resolve(.drafts, listed: listed.map { .init(name: $0, selectable: true) },
                                                markedInList: [], declared: "Drafts",
                                                advertisesSpecialUse: { true }) { throw Broken() }
            XCTFail("expected a refusal")
        } catch let refusal as SendDraftRefusal {
            XCTAssertTrue(refusal.description.contains("lists 5 mailboxes and advertises SPECIAL-USE"), refusal.description)
            XCTAssertTrue(refusal.description.contains("request for its special-use mailboxes failed"), refusal.description)
            XCTAssertFalse(refusal.description.contains("Brouillons"), "no server text: \(refusal.description)")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

}
