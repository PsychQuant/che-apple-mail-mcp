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
                         onRequest: [String] = [], declared: String? = nil,
                         asked: Asked = Asked()) async throws -> MailboxLookup.Found {
        try await MailboxLookup.resolve(role, listed: listed, markedInList: marked,
                                        advertisesSpecialUse: advertises, declared: declared) {
            asked.note()
            return onRequest
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

    func testAFailureWhileAskingIsHandedOn() async {
        struct Broken: Error {}
        do {
            _ = try await MailboxLookup.resolve(.drafts, listed: listed, markedInList: [],
                                                advertisesSpecialUse: true, declared: "Drafts") { throw Broken() }
            XCTFail("expected the failure")
        } catch is Broken {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Row 4 — the name in direct-transport.json

    func testTheConfiguredNameIsUsedWhenTheServerMarksNone() async throws {
        for advertises in [false, true] {
            let found = try await resolve(advertises: advertises, declared: "Drafts")
            XCTAssertEqual(found.name, "Drafts")
            XCTAssertEqual(found.source, .configuration)
            XCTAssertTrue(found.note.contains("drafts_mailbox"), found.note)
            XCTAssertTrue(found.note.contains(advertises ? "advertises SPECIAL-USE" : "does not advertise SPECIAL-USE"),
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
            XCTAssertTrue(text.contains(advertises ? "advertises SPECIAL-USE" : "does not advertise SPECIAL-USE"), text)
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
        XCTAssertTrue(plain.note.contains("another mailbox"), plain.note)
        XCTAssertFalse(plain.note.contains("Archive"), plain.note)

        let requested = try await resolve(advertises: true, onRequest: ["Drafts"], declared: "Archive")
        XCTAssertEqual(requested.name, "Drafts")
        XCTAssertTrue(requested.note.contains("another mailbox"), requested.note)
    }

    func testAConfiguredNameThatAgreesWithTheServerAddsNothing() async throws {
        let found = try await resolve(marked: ["Drafts"], declared: "Drafts")
        XCTAssertFalse(found.note.contains("another mailbox"), found.note)
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
}
