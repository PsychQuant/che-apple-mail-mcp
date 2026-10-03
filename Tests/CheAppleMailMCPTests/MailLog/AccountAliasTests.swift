import XCTest
@testable import CheAppleMailMCP

/// #465 — task 2.3, as amended by verify round 1 finding #13: only the `[account - mailbox]` form
/// carries an account. A bracketed label with no separator (`[Fixture.Server]`, `[iCloud]`) is a
/// connection or server name — giving it a letter made one account look like two across categories.
final class AccountAliasTests: XCTestCase {

    func testTwoAccountsInOneResponse() {
        var a = AccountAliaser()
        XCTAssertEqual(a.alias(forMessage: "[first - inbox] x"), "A")
        XCTAssertEqual(a.alias(forMessage: "[second - drafts] y"), "B")
        XCTAssertEqual(a.alias(forMessage: "[first - drafts] z"), "A")
        XCTAssertEqual(a.count, 2)
    }

    func testNoBracketedPrefix_isNil() {
        var a = AccountAliaser()
        XCTAssertNil(a.alias(forMessage: "Created append action 11198"))
        XCTAssertNil(a.alias(forMessage: ""))
        XCTAssertEqual(a.count, 0)
    }

    func testBracketLabelWithoutTheAccountMailboxSeparatorIsNotAnAccount() {
        var a = AccountAliaser()
        XCTAssertNil(a.alias(forMessage: "[Fixture.Server] <connection id:[Mailbox name=Fixture]> Read: 7"))
        XCTAssertNil(a.alias(forMessage: "[iCloud] foo"))
        XCTAssertNil(a.alias(forMessage: "[Google] bar"))
        XCTAssertEqual(a.count, 0, "such labels must not inflate accounts_seen")
    }

    func testOnlyTheFirstDashSeparatesAccountFromMailbox() {
        var a = AccountAliaser()
        XCTAssertEqual(a.alias(forMessage: "[acct - box - sub] x"), "A")
        XCTAssertEqual(a.alias(forMessage: "[acct - other] x"), "A")
    }

    func testMalformedPrefixes_areNil() {
        var a = AccountAliaser()
        XCTAssertNil(a.alias(forMessage: "[] x"))
        XCTAssertNil(a.alias(forMessage: "[ - box] x"))
        XCTAssertNil(a.alias(forMessage: "[unterminated - x"))
        XCTAssertEqual(a.count, 0)
    }

    func testAliasesContinuePastZ() {
        var a = AccountAliaser()
        var last: String?
        for i in 1...27 { last = a.alias(forMessage: "[acct\(i) - box] x") }
        XCTAssertEqual(last, "AA")
        XCTAssertEqual(a.alias(forMessage: "[acct26 - box] x"), "Z")
    }

    func testTheAccountKeyNeverAppearsInAnAlias() {
        var a = AccountAliaser()
        let alias = a.alias(forMessage: "[someone.fixture@example.invalid - Inbox] x")!
        XCTAssertFalse(alias.contains("fixture"))
        XCTAssertFalse(alias.contains("@"))
    }

    /// Verify round 2, finding 18: the letter was computed for EVERY event, so a placeholder-only
    /// template — whose whole message is runtime text — could carry `[guess - x]` and learn, through
    /// letter equality, whether `guess` is a real account name. The bracket only names an account
    /// when the TEMPLATE puts it there: in the leading `%@` of a template with literal text of its own,
    /// or in the first slot of a template that itself opens with `[%@ - `.
    func testOnlyAWildcardLedTemplateWithLiteralTextGetsALetter() {
        let lines = [
            Synthetic.line(offset: 0, format: "%@ Received %lu new local message actions",
                           message: "[real - Drafts] Received 1 new local message actions"),
            Synthetic.line(offset: 1, format: "%{public}@", message: "[real - x] anything"),
            Synthetic.line(offset: 2, format: "%@ %lu", message: "[real - x] 3"),
            Synthetic.line(offset: 3, format: "Moved %lu messages", message: "[real - x] Moved 3 messages"),
            Synthetic.line(offset: 4, format: "%@ a.b@example.invalid", message: "[real - x] a.b@example.invalid"),
            // The bracket written in the TEMPLATE itself, account in its first slot: 1,898 real events
            // in eight hours (`[%{public}@ - %{public}@] Reset mailbox in sync state`).
            Synthetic.line(offset: 5, format: "[%{public}@ - %{public}@] Reset mailbox in sync state",
                           message: "[real - INBOX] Reset mailbox in sync state"),
            Synthetic.line(offset: 6, format: "[%{public}@] Reset", message: "[other - x] Reset"),
        ]
        let r = MailLogService(source: FakeLogSource(lines: lines), timeZone: Synthetic.taipei).run(Synthetic.query())
        let accounts = Synthetic.results(r).map { $0["account"] as? String }
        XCTAssertEqual(accounts, ["A", nil, nil, nil, nil, "A", nil])
        XCTAssertEqual(r["accounts_seen"] as? Int, 1)
    }
}
