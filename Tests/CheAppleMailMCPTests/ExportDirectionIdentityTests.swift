import XCTest
@testable import CheAppleMailMCP
@testable import MailSQLite

/// #351 / #343 — `direction` in frozen frontmatter, and the disclosure that is
/// supposed to accompany an uncertain one.
///
/// The two issues are one defect seen from two sides: the inputs to #316's
/// sender-identity comparison are not what the comparison assumes, and the
/// fail-open test could not detect that. Measured on the reporting machine:
/// 8 configured accounts, 6 IMAP resolve to an address, **2 EWS accounts
/// resolve to nothing** (their AccountURL is an opaque store id, #9). Mail sent
/// from an EWS account therefore matched no own address and was written
/// `received` — with NO `direction_inferred`, because the six other accounts
/// kept the set non-empty and the gate only asked "is the WHOLE set empty".
///
/// The contract that makes this severe: an ABSENT `direction_inferred` means
/// "identity resolved, trust this value". So the failure did not merely produce
/// a wrong `direction`; it produced a wrong one wearing a confidence badge, in
/// a file the archive treats as frozen.
final class ExportDirectionIdentityTests: XCTestCase {

    fileprivate func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("direction-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    fileprivate func email(from sender: String) -> EmailContent {
        EmailContent(
            subject: "Topic", sender: sender, toRecipients: ["x@y.com"], ccRecipients: [],
            date: "Sat, 14 Dec 2024 19:11:21 +0800", messageId: "<m@x>", inReplyTo: "",
            textBody: "body", htmlBody: nil, rawSource: nil, fromPartialEmlx: false)
    }

    /// Run one email and return (direction, direction_inferred, file body).
    fileprivate func export(
        sender: String,
        ownAddresses: Set<String>,
        fallbackDirection: String = "received",
        identityResolvable: @escaping (String) -> Bool = { _ in true }
    ) throws -> (direction: String, inferred: Bool?, text: String) {
        let out = tempDir()
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, ownAddresses: ownAddresses,
            fallbackDirection: fallbackDirection, includeAttachments: false,
            filenameTemplate: nil, filenameOverrides: [:], extraFrontmatter: [],
            identityResolvable: identityResolvable,
            fetch: { _ in self.email(from: sender) },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })
        let item = try XCTUnwrap(manifest.items.first)
        let path = try XCTUnwrap(item.writtenPath)
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        let line = text.split(separator: "\n").first { $0.hasPrefix("direction:") } ?? ""
        let direction = line.replacingOccurrences(of: "direction:", with: "")
            .trimmingCharacters(in: .whitespaces)
        return (direction, item.directionInferred, text)
    }

    // MARK: - #351: the EWS account that contributes nothing

    func testMailSentFromAnAccountWithNoResolvableAddressIsDisclosedNotAssertedReceived() throws {
        // The reported case: the sender is the user's own address ON AN EXCHANGE
        // ACCOUNT, so it is absent from the own set (which holds only the
        // IMAP-resolved addresses); the message sits in that account's sent
        // mailbox, so the mailbox-label fallback says "sent".
        let r = try export(
            sender: "Owner <owner@exchange.example.edu>",
            ownAddresses: ["owner@imap.example.org", "owner@mail.example.net"],
            fallbackDirection: "sent",
            identityResolvable: { _ in false })      // EWS account: no addresses

        XCTAssertEqual(r.inferred, true,
            "identity could NOT be established for this email — the manifest must say so. "
            + "An absent direction_inferred means 'trust this value', and that is the "
            + "claim #351 showed to be false.")
        XCTAssertEqual(r.direction, "sent",
            "with identity unavailable the mailbox-label fallback applies; here it also "
            + "happens to be the correct answer")
    }

    /// The counterpart that must NOT regress: a genuinely external message from
    /// an account that DOES resolve stays a confident `received`.
    func testExternalSenderFromAResolvableAccountStaysConfidentReceived() throws {
        let r = try export(
            sender: "Someone Else <stranger@example.net>",
            ownAddresses: ["owner@imap.example.org"],
            identityResolvable: { _ in true })
        XCTAssertEqual(r.direction, "received")
        XCTAssertNil(r.inferred, "identity WAS established — no disclosure should be emitted")
    }

    /// A positive match wins even when the email's own account is unresolvable:
    /// mail sent from account A can legitimately sit in account B's store.
    func testPositiveIdentityMatchWinsOverAnUnresolvableAccount() throws {
        let r = try export(
            sender: "Owner <owner@imap.example.org>",
            ownAddresses: ["owner@imap.example.org"],
            identityResolvable: { _ in false })
        XCTAssertEqual(r.direction, "sent")
        XCTAssertNil(r.inferred, "the sender matched an own address — that IS identity")
    }

    func testEmptyOwnAddressSetStillDisclosesAsBefore() throws {
        let r = try export(sender: "a@b.com", ownAddresses: [], fallbackDirection: "received")
        XCTAssertEqual(r.direction, "received")
        XCTAssertEqual(r.inferred, true, "#316's original fail-open must be preserved")
    }

    // MARK: - #343-A: the parse itself decides direction

    func testRFCCommentCannotForgeASentDirection() throws {
        // Pre-fix: the comment's <user@gmail.com> was taken as the address, so
        // an ATTACKER's message was archived as the user's own.
        let r = try export(
            sender: "Attacker <attacker@example.net> (legacy <user@gmail.com>)",
            ownAddresses: ["user@gmail.com"])
        XCTAssertEqual(r.direction, "received",
            "the address is attacker@example.net; an RFC comment must not supply identity")
        XCTAssertNil(r.inferred)
    }

    func testMultiAuthorFromIsNotArchivedAsReceived() throws {
        // Pre-fix: last-address-wins made the user's own message `received`.
        let r = try export(
            sender: "User <user@gmail.com>, Coauthor <coauthor@example.net>",
            ownAddresses: ["user@gmail.com"])
        XCTAssertEqual(r.direction, "sent")
        XCTAssertNil(r.inferred)
    }

    func testQuotedLocalPartCannotForgeASentDirection() throws {
        let r = try export(
            sender: "\"x<user@gmail.com>\"@evil.example",
            ownAddresses: ["user@gmail.com"])
        XCTAssertEqual(r.direction, "received")
    }

    func testUnparseableFromIsDisclosedRatherThanCalledReceived() throws {
        let r = try export(sender: "Mailer Daemon", ownAddresses: ["user@gmail.com"],
                           fallbackDirection: "received")
        XCTAssertEqual(r.inferred, true,
            "a From that yields no address is 'cannot tell', not 'not yours'")
    }

    // MARK: - #343-B: a set member that is not a bare address

    func testDisplayNameSetMemberStillMatchesItsOwnMail() throws {
        // `imap://Work%20%3Cuser%40example.com%3E/` → set member
        // `Work <user@example.com>`. Server normalises members through the same
        // function as the sender, so this now matches instead of silently
        // becoming an entry that can never match.
        let normalized = Set([EmailAddress.canonical("Work <user@example.com>")].compactMap { $0 })
        let r = try export(sender: "User <user@example.com>", ownAddresses: normalized)
        XCTAssertEqual(r.direction, "sent")
        XCTAssertNil(r.inferred)
    }

    // MARK: - the frontmatter `sender` field uses the same parse

    func testFrontmatterSenderIsTheParsedAddressNotTheCommentAddress() throws {
        let r = try export(
            sender: "Attacker <attacker@example.net> (legacy <user@gmail.com>)",
            ownAddresses: ["user@gmail.com"])
        XCTAssertTrue(r.text.contains("sender: attacker@example.net"),
            "the sender line and the direction decision must come from ONE parse; "
            + "found:\n\(r.text.prefix(400))")
    }
}

/// #343-B / #351 at the layer where the identity inputs are BUILT.
///
/// The account shapes below mirror the reporting machine's `AccountsMap.plist`
/// (addresses substituted): 6 IMAP accounts whose AccountURL percent-decodes to
/// an address, and 2 EWS accounts whose AccountURL is an opaque store id so
/// `email_addresses` comes back empty (#9). That asymmetry is #351.
final class ExportIdentityInputsTests: XCTestCase {

    private func imap(_ uuid: String, _ addr: String) -> [String: Any] {
        ["uuid": uuid, "email_addresses": [addr], "name": addr]
    }
    private func ews(_ uuid: String) -> [String: Any] {
        ["uuid": uuid, "email_addresses": [String](), "name": uuid]
    }

    func testEWSAccountContributesNoAddressAndIsNotCountedAsResolved() {
        let accounts = [imap("U1", "owner@imap.example.org"), ews("EWS-A"), ews("EWS-B")]
        XCTAssertEqual(ExportIdentity.ownAddresses(from: accounts), ["owner@imap.example.org"])
        XCTAssertEqual(ExportIdentity.resolvedAccountUUIDs(from: accounts), ["u1"],
            "an EWS account resolves to no address, so mail sent from it cannot be judged — "
            + "it must be absent here so the export discloses instead of asserting received")
    }

    func testTheSetIsNonEmptyWhileAnAccountIsStillUnresolvable() {
        // Precisely #351's configuration: the whole-set emptiness test the old
        // code used sees a healthy non-empty set and reports nothing wrong.
        let accounts = [imap("U1", "a@x.com"), imap("U2", "b@y.com"), ews("EWS1")]
        XCTAssertFalse(ExportIdentity.ownAddresses(from: accounts).isEmpty,
            "the old fail-open condition is FALSE here — which is why it never fired")
        XCTAssertFalse(ExportIdentity.resolvedAccountUUIDs(from: accounts).contains("EWS1"),
            "…while this, the condition that matters, is true")
    }

    func testDisplayNameMemberIsNormalizedRatherThanLeftUnmatchable() {
        // `imap://Work%20%3Cuser%40example.com%3E/` → "Work <user@example.com>"
        let accounts = [["uuid": "U1", "email_addresses": ["Work <user@example.com>"]]]
        XCTAssertEqual(ExportIdentity.ownAddresses(from: accounts), ["user@example.com"])
        XCTAssertEqual(ExportIdentity.resolvedAccountUUIDs(from: accounts), ["u1"],
            "UUIDs are case-folded — hex case carries no meaning (#343 verify)")
    }

    func testMemberThatIsNotAnAddressIsDroppedAndItsAccountIsUnresolved() {
        // #9's fallback stores the UUID itself as the mapping value; it must not
        // become a set member that can never match.
        let accounts = [["uuid": "U1", "email_addresses": ["ABCE3A85-1234-5678-9ABC-DEF012345678"]]]
        XCTAssertTrue(ExportIdentity.ownAddresses(from: accounts).isEmpty)
        XCTAssertTrue(ExportIdentity.resolvedAccountUUIDs(from: accounts).isEmpty,
            "no usable address → the account is unresolved → its mail is disclosed")
    }

    func testCaseAndWhitespaceVariantsCollapseToOneMember() {
        let accounts = [imap("U1", "  User@Example.COM "), imap("U2", "user@example.com")]
        XCTAssertEqual(ExportIdentity.ownAddresses(from: accounts), ["user@example.com"])
    }
}

extension ExportDirectionIdentityTests {

    /// #343 verify: the co-author case in the order the first fix failed on.
    func testOwnAddressLastInAMultiAuthorFromIsStillSent() throws {
        let r = try export(
            sender: "Coauthor <coauthor@example.net>, Owner <owner@imap.example.org>",
            ownAddresses: ["owner@imap.example.org"])
        XCTAssertEqual(r.direction, "sent",
            "every mailbox in From is an author; position must not decide identity")
        XCTAssertNil(r.inferred)
    }

    /// A structurally broken From must reach the disclosure path, not be
    /// tidied into a confident `received`.
    func testBrokenFromIsDisclosed() throws {
        for broken in ["owner@imap.example.org)", "owner@imap.example.org>",
                       "owner@imap.example.org (unclosed"] {
            let r = try export(sender: broken, ownAddresses: ["other@example.net"])
            XCTAssertEqual(r.inferred, true, "should be disclosed, not asserted: \(broken)")
        }
    }
}

extension ExportIdentityInputsTests {

    /// #343 verify: hex case in a UUID carries no meaning, and the reader folds
    /// it elsewhere. A store reporting one case in the account map and the
    /// other in the mailbox URL would otherwise make a perfectly resolvable
    /// account look unresolvable, silently downgrading its mail to the
    /// mailbox-label fallback.
    func testAccountUUIDComparisonIsCaseInsensitive() {
        let upper = [["uuid": "ABCD-1234", "email_addresses": ["a@x.com"]]]
        XCTAssertEqual(ExportIdentity.resolvedAccountUUIDs(from: upper), ["abcd-1234"])
        let lower = [["uuid": "abcd-1234", "email_addresses": ["a@x.com"]]]
        XCTAssertEqual(ExportIdentity.resolvedAccountUUIDs(from: lower),
                       ExportIdentity.resolvedAccountUUIDs(from: upper),
                       "the same account written in either case must resolve identically")
    }
}
