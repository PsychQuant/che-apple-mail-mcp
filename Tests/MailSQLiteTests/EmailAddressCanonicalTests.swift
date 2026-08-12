import XCTest
@testable import MailSQLite

/// #343 — the inputs to #316's sender-identity comparison are not what the
/// comparison assumes.
///
/// `EmailMarkdownRenderer.bareEmail` took the LAST `<…>` pair in the header,
/// which is not an RFC 5322 mailbox parse. Since #316 made `direction` depend
/// on that value, a `From` the parser reads differently from a mail client
/// writes a wrong value into FROZEN frontmatter — persisted, not transient.
///
/// The scenarios below are the ones the cross-model audit constructed. They
/// were not reproduced against live Mail; they are pinned here as parser
/// behaviour, which is where the defect actually lives.
final class EmailAddressCanonicalTests: XCTestCase {

    // MARK: - #343-A: false `sent` (an external message archived as the user's)

    func testRFCCommentIsNotMistakenForTheAddress() {
        // The comment's angle brackets were taken as the address, so this
        // matched the own address `user@gmail.com` and an ATTACKER's message
        // was archived direction: sent.
        let from = "Attacker <attacker@example.net> (legacy <user@gmail.com>)"
        XCTAssertEqual(EmailAddress.canonical(from), "attacker@example.net")
    }

    func testQuotedLocalPartIsNotTruncated() {
        // `"x<user@gmail.com>"@evil.example` — the angle brackets are INSIDE a
        // quoted local part, so scanning for `<` truncated the address to the
        // own address and again produced a false `sent`.
        let from = "\"x<user@gmail.com>\"@evil.example"
        XCTAssertEqual(EmailAddress.canonical(from), "\"x<user@gmail.com>\"@evil.example")
    }

    // MARK: - #343-A: false `received` (the user's own message archived as incoming)

    func testFirstMailboxWinsInAMultiAuthorFrom() {
        // Last-address-wins archived the user's own message as received.
        // RFC 5322 allows multiple authors in From; the first is the primary.
        let from = "User <user@gmail.com>, Coauthor <coauthor@example.net>"
        XCTAssertEqual(EmailAddress.canonical(from), "user@gmail.com")
    }

    func testCommaInsideAQuotedDisplayNameIsNotAListSeparator() {
        let from = "\"Cheng, Che\" <che@example.com>, Other <other@example.net>"
        XCTAssertEqual(EmailAddress.canonical(from), "che@example.com")
    }

    // MARK: - #343-B: the own-address set can hold non-addresses

    func testDisplayNameFormNormalizesToTheBareAddress() {
        // An AccountURL of `imap://Work%20%3Cuser%40example.com%3E/` yields the
        // set member `Work <user@example.com>`. Mail genuinely sent from that
        // account parses to bare `user@example.com`, never matched, and was
        // archived received — with NO disclosure, because the set was
        // non-empty. Normalizing BOTH sides through this one function is the
        // property #316's design claimed but did not enforce.
        XCTAssertEqual(EmailAddress.canonical("Work <user@example.com>"), "user@example.com")
    }

    func testNonAddressSetMemberIsRejectedRatherThanKeptAsUnmatchable() {
        // A member that cannot be reduced to a bare address must be absent, so
        // the caller falls back to disclosure instead of holding a value that
        // can never match.
        XCTAssertNil(EmailAddress.canonical("ABCE3A85-1234-5678-9ABC-DEF012345678"))
        XCTAssertNil(EmailAddress.canonical(""))
        XCTAssertNil(EmailAddress.canonical("   "))
        XCTAssertNil(EmailAddress.canonical("Mailer Daemon"))
        XCTAssertNil(EmailAddress.canonical("<>"))
        XCTAssertNil(EmailAddress.canonical("user@"))
        XCTAssertNil(EmailAddress.canonical("@example.com"))
    }

    // MARK: - ordinary shapes must keep working

    func testPlainAndAngleFormsAreEquivalentAndCaseFolded() {
        XCTAssertEqual(EmailAddress.canonical("user@example.com"), "user@example.com")
        XCTAssertEqual(EmailAddress.canonical("  User@Example.COM  "), "user@example.com")
        XCTAssertEqual(EmailAddress.canonical("Name <User@Example.com>"), "user@example.com")
        XCTAssertEqual(EmailAddress.canonical("\"Quoted Name\" <a@b.co>"), "a@b.co")
    }

    func testBothSidesOfTheComparisonAreProducedIdentically() {
        // The invariant the fix exists to establish: canonical() is idempotent,
        // so a set member and a sender that denote the same mailbox compare
        // equal no matter which form each arrived in.
        for raw in ["Work <user@example.com>", "user@example.com", "USER@EXAMPLE.COM",
                    "\"Work\" <User@Example.com>"] {
            XCTAssertEqual(EmailAddress.canonical(raw), "user@example.com", "input: \(raw)")
            XCTAssertEqual(EmailAddress.canonical(EmailAddress.canonical(raw)!),
                           EmailAddress.canonical(raw), "not idempotent: \(raw)")
        }
    }
}
