import XCTest
import SQLite3
@testable import MailSQLite

/// #344 — #317 replaced the mailbox filter's `LIKE` patterns (run against the
/// RAW url) with Swift string comparisons (run against the DECODED path). That
/// removed a real injection, but silently changed two semantics:
///
///  A. SQLite `LIKE` is ASCII-case-insensitive by default, the Swift compares
///     are exact — so `mailbox: "inbox"` stopped matching `INBOX`, which
///     RFC 3501 §5.1 makes case-insensitive BY SPEC. A legitimate name started
///     returning a silent zero.
///  C. `MailboxURL.decode` percent-decodes the WHOLE path in one go, so a
///     mailbox literally named `R&D/Sent` (raw `R%26D%2FSent`) is
///     indistinguishable from the hierarchy `R&D` → `Sent`. `hasSuffix("/Sent")`
///     then pulls that mailbox in for a `Sent` query — over-matching, the exact
///     class #317 set out to kill, re-entering through the decode side.
///
/// The fix is one rewrite, not two patches: components must exist before "the
/// leaf" can be defined, and "should the leaf fold case?" cannot be stated
/// until then. `MailboxURL.pathComponents` splits the ENCODED path first and
/// decodes each piece, so a `%2F` can never masquerade as a separator; the
/// matcher then compares component runs.
///
/// Case policy (deliberately NOT the blanket fold the issue proposed): `INBOX`
/// folds per RFC 3501; every other component is exact, because on a
/// case-sensitive server `Work` and `work` are two mailboxes and over-matching
/// hands back another mailbox's mail — invisible, where a miss is visible.
/// What makes exactness affordable is the near-miss diagnostic: a resolution
/// that finds nothing but has a case-only (or whitespace-only) candidate throws
/// naming it, so the zero is never silent.
///
/// Kept in a fixture of its own so `MailboxFilterTests` (#317's injection pins)
/// keeps testing exactly what it tested before.
final class MailboxComponentMatchingTests: XCTestCase {

    // MARK: - fixture

    /// Mailboxes (all messages share subject "match"):
    ///   1  UUID-A          INBOX            2 msgs, 3 unread
    ///   2  UUID-A          Work             1 msg   (case-sensitivity probe)
    ///   3  UUID-A          R&D/Sent         1 msg   ← ONE mailbox, literal '/'
    ///   4  UUID-A          R&D → Sent       1 msg   ← genuine two-level hierarchy
    ///   5  UUID-A          Sent             1 msg   (top-level)
    ///   6  E51B96AC-CAFE   Archive          1 msg   ← UPPER-case authority
    ///   7  UUID-A          INBOX → Sub      1 msg   ← child of the root INBOX
    ///   8  UUID-A          Team → INBOX     1 msg   ← 'INBOX' at a NON-root position
    ///   9  UUID-A          Team → inbox     1 msg   ← its case twin, a DIFFERENT mailbox
    private func makeFixtureDB() throws -> String {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(
            "MailboxComponentMatchingTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("Envelope Index").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
                              nil) == SQLITE_OK else {
            throw NSError(domain: "MailboxComponentMatchingTests", code: 1)
        }
        defer { sqlite3_close(db) }

        let sql = """
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, unread_count INTEGER DEFAULT 0);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, mailbox INTEGER, date_received INTEGER, read INTEGER DEFAULT 0, flagged INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0);
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        INSERT INTO addresses VALUES (1, 'sender@example.com', 'Sender');
        INSERT INTO mailboxes VALUES (1, 'imap://UUID-A/INBOX', 3);
        INSERT INTO mailboxes VALUES (2, 'imap://UUID-A/Work', 1);
        INSERT INTO mailboxes VALUES (3, 'imap://UUID-A/R%26D%2FSent', 1);
        INSERT INTO mailboxes VALUES (4, 'imap://UUID-A/R%26D/Sent', 1);
        INSERT INTO mailboxes VALUES (5, 'imap://UUID-A/Sent', 1);
        INSERT INTO mailboxes VALUES (6, 'imap://E51B96AC-CAFE/Archive', 1);
        INSERT INTO mailboxes VALUES (7, 'imap://UUID-A/INBOX/Sub', 0);
        INSERT INTO mailboxes VALUES (8, 'imap://UUID-A/Team/INBOX', 0);
        INSERT INTO mailboxes VALUES (9, 'imap://UUID-A/Team/inbox', 0);
        INSERT INTO subjects VALUES (1, 'match one');
        INSERT INTO messages (ROWID, subject, sender, mailbox, date_received) VALUES
            (1, 1, 1, 1, 1001), (2, 1, 1, 1, 1002), (3, 1, 1, 2, 1003),
            (4, 1, 1, 3, 1004), (5, 1, 1, 4, 1005), (6, 1, 1, 5, 1006),
            (7, 1, 1, 6, 1007), (8, 1, 1, 7, 1008), (9, 1, 1, 8, 1009),
            (10, 1, 1, 9, 1010);
        """
        var err: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let m = err.map { String(cString: $0) } ?? "?"
            throw NSError(domain: "MailboxComponentMatchingTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: m])
        }
        return dbPath
    }

    private func makeReader() throws -> EnvelopeIndexReader {
        // NOTE the account mapping holds the authority in LOWER case while
        // mailbox 6's URL carries it UPPER case — finding B's shape.
        try EnvelopeIndexReader(databasePath: try makeFixtureDB(),
                                accountMapping: ["UUID-A": "Alice",
                                                 "e51b96ac-cafe": "Bob"])
    }

    private func count(_ reader: EnvelopeIndexReader, mailbox: String,
                       account: String? = nil) throws -> Int {
        try reader.searchCount(SearchParameters(
            query: "match", field: .subject,
            accountName: account, mailbox: mailbox, limit: 100))
    }

    // MARK: - (1) MailboxURL.pathComponents — split BEFORE decoding

    /// The whole fix rests on this: a `%2F` must stay inside one component.
    /// `mailboxPath` (the lossy join) is deliberately left alone — it is what
    /// `search_emails` reports and has consumers across six files.
    func testPathComponents_keepEncodedSlashInsideOneComponent() throws {
        let one = MailboxURL.decode("imap://UUID-A/R%26D%2FSent")
        XCTAssertEqual(one?.pathComponents, ["R&D/Sent"],
            "a percent-encoded slash is part of the NAME — splitting must happen "
            + "on the encoded path, before decoding")
        XCTAssertEqual(one?.mailboxPath, "R&D/Sent",
            "mailboxPath keeps its existing (lossy) meaning — unchanged by #344")

        let two = MailboxURL.decode("imap://UUID-A/R%26D/Sent")
        XCTAssertEqual(two?.pathComponents, ["R&D", "Sent"],
            "a real separator still separates")

        // Both URLs decode to the SAME mailboxPath — that collision is exactly
        // why the matcher may no longer reason about '/' in the decoded string.
        XCTAssertEqual(one?.mailboxPath, two?.mailboxPath)
    }

    func testPathComponents_preservesEmptySegments() throws {
        XCTAssertEqual(MailboxURL.decode("imap://UUID-A/A//B")?.pathComponents,
                       ["A", "", "B"],
            "dropping empty segments would make A//B and A/B indistinguishable — "
            + "the same lossy collapse this fix exists to remove")
    }

    // MARK: - (3) case policy: INBOX folds, nothing else does

    /// RFC 3501 §5.1 makes INBOX case-insensitive by spec. #317 made it exact,
    /// so `inbox` silently returned nothing.
    func testInbox_isCaseInsensitivePerRFC3501() throws {
        let reader = try makeReader()
        // Root INBOX (2) + its child INBOX/Sub (1) + Team/inbox (1, matched by
        // ORDINARY exact leaf comparison, not by the fold). Team/INBOX is the
        // one excluded — see testInboxFold_isConfinedToThePathRoot.
        XCTAssertEqual(try count(reader, mailbox: "inbox"), 4,
            "INBOX is case-insensitive by RFC 3501 §5.1 — 'inbox' must resolve")
        XCTAssertEqual(try count(reader, mailbox: "InBoX"), 3,
            "a mixed-case spelling folds at the root (INBOX + INBOX/Sub) but matches "
            + "no leaf exactly, so Team/inbox drops out — the fold and exact matching "
            + "are visibly separate mechanisms")
        XCTAssertEqual(try reader.getUnreadCount(mailbox: "inbox", accountName: nil), 3,
            "the same rule must hold on the getUnreadCount fast path")
    }

    /// The deliberate divergence from the issue's suggested remedy: folding
    /// EVERY name would let `work` return `Work`'s mail on a case-sensitive
    /// server. A miss is visible; a wrong hit is not.
    func testNonInboxName_staysExact_andReportsTheNearMiss() throws {
        let reader = try makeReader()
        XCTAssertThrowsError(try count(reader, mailbox: "work")) { error in
            guard case MailSQLiteError.mailboxNotResolvable(let name, let candidates) = error else {
                return XCTFail("expected mailboxNotResolvable, got \(error)")
            }
            XCTAssertEqual(name, "work")
            XCTAssertEqual(candidates, ["Work"],
                "the near-miss must be NAMED — that is what makes exactness affordable")
        }
        XCTAssertEqual(try count(reader, mailbox: "Work"), 1,
            "the exact name still resolves")
    }

    /// Same mechanism, a different near-miss class: outer whitespace.
    func testNearMiss_coversOuterWhitespace() throws {
        let reader = try makeReader()
        XCTAssertThrowsError(try count(reader, mailbox: " Work ")) { error in
            guard case MailSQLiteError.mailboxNotResolvable(_, let candidates) = error else {
                return XCTFail("expected mailboxNotResolvable, got \(error)")
            }
            XCTAssertEqual(candidates, ["Work"])
        }
    }

    /// A name that resembles nothing must still be an honest empty, not a
    /// throw — otherwise every legitimately-empty filter becomes an error.
    func testUnrelatedName_stillReturnsAnHonestZero() throws {
        let reader = try makeReader()
        XCTAssertEqual(try count(reader, mailbox: "NoSuchBox"), 0)
        XCTAssertEqual(try reader.getUnreadCount(mailbox: "NoSuchBox", accountName: nil), 0)
    }

    // MARK: - (2) component-wise matching — %2F is not a separator

    /// Finding C. `R&D/Sent` is ONE mailbox whose name contains a slash; a
    /// query for `Sent` must not collect it.
    func testEncodedSlashMailbox_isNotCaughtByALeafQuery() throws {
        let reader = try makeReader()
        XCTAssertEqual(try count(reader, mailbox: "Sent"), 2,
            "'Sent' matches the top-level Sent and the leaf of R&D → Sent — but NOT "
            + "the mailbox literally NAMED 'R&D/Sent' (raw R%26D%2FSent)")
    }

    /// Same asymmetry from the descendant side.
    func testEncodedSlashMailbox_isNotADescendantOfItsOwnPrefix() throws {
        let reader = try makeReader()
        XCTAssertEqual(try count(reader, mailbox: "R&D"), 1,
            "only the genuine R&D → Sent hierarchy descends from R&D; the mailbox "
            + "NAMED 'R&D/Sent' has no parent named R&D")
    }

    /// The one string clause that survives the rewrite: exact full-path
    /// equality, so `search_emails` still accepts its own `mailbox` output even
    /// for a name containing a literal slash. The two mailboxes are genuinely
    /// indistinguishable in that (lossy) representation, so both come back.
    func testExactFullPath_stillRoundTrips() throws {
        let reader = try makeReader()
        XCTAssertEqual(try count(reader, mailbox: "R&D/Sent"), 2,
            "the decoded path 'R&D/Sent' names both mailboxes and the caller has no "
            + "way to say which — matching both is the only non-arbitrary answer")
    }

    // MARK: - (5) account UUID case

    /// Finding B. UUIDs are hex — case carries no meaning, and folding them
    /// cannot over-match onto a different account.
    func testAccountUUID_comparesCaseInsensitively() throws {
        let reader = try makeReader()
        XCTAssertEqual(try count(reader, mailbox: "Archive", account: "Bob"), 1,
            "the mapping holds 'e51b96ac-cafe' while the URL authority is "
            + "'E51B96AC-CAFE' — a hex UUID has no semantic case")
    }

    // MARK: - descendant / leaf semantics must survive the rewrite

    // MARK: - the INBOX fold belongs at the root, and nowhere else (verify R1)

    /// The first cut of this fix folded `INBOX` at **every** component
    /// position, so a store holding both `Team/INBOX` and `Team/inbox` returned
    /// both mailboxes' mail for a query naming either — the exact over-match
    /// this issue's diagnosis rejected when it argued against blanket folding,
    /// reintroduced one level down. RFC 3501 §5.1's `INBOX` is a mailbox
    /// *name*, not a token that may appear anywhere in a hierarchy.
    func testInboxFold_isConfinedToThePathRoot() throws {
        let reader = try makeReader()
        XCTAssertEqual(try count(reader, mailbox: "Team/inbox"), 1,
            "must resolve ONLY the mailbox actually named Team/inbox")
        XCTAssertEqual(try count(reader, mailbox: "Team/INBOX"), 1,
            "…and its case twin must resolve only itself — these are two mailboxes")
        XCTAssertEqual(try count(reader, mailbox: "Team"), 2,
            "both are descendants of Team, so the parent query still sees both")
    }

    /// The other half, and the sharpest statement of the rule: `inbox` and
    /// `INBOX` both resolve four messages, but **not the same four**. The
    /// counts being equal is a coincidence; the membership is the point.
    ///
    ///  - `inbox`  → root INBOX(2) + INBOX/Sub(1) + Team/inbox(1)   [Team/INBOX out]
    ///  - `INBOX`  → root INBOX(2) + INBOX/Sub(1) + Team/INBOX(1)   [Team/inbox out]
    ///
    /// Each reaches a nested mailbox only by matching it EXACTLY. The fold buys
    /// exactly one thing — the root — which is what RFC 3501 §5.1 grants.
    func testTheFoldAndExactMatchingAreSeparateMechanisms() throws {
        let reader = try makeReader()
        // Scope to the nested pair so the membership, not the total, is asserted.
        XCTAssertEqual(try count(reader, mailbox: "Team/inbox"), 1)
        XCTAssertEqual(try count(reader, mailbox: "Team/INBOX"), 1)
        // A mixed-case spelling can only ever hit the root: it matches no leaf
        // exactly, and the fold does not apply below position 0.
        XCTAssertEqual(try count(reader, mailbox: "InBoX"), 3,
            "root INBOX(2) + INBOX/Sub(1) — neither Team/INBOX nor Team/inbox, because "
            + "off-root components compare exactly and 'InBoX' equals neither")
    }

    /// An EXACT-case query is unaffected by any of this: it matches at any
    /// depth, exactly as every other mailbox name does.
    func testExactCaseINBOX_stillMatchesAtAnyDepth() throws {
        let reader = try makeReader()
        XCTAssertEqual(try count(reader, mailbox: "INBOX"), 4,
            "root INBOX (2) + INBOX/Sub (1) + Team/INBOX (1); Team/inbox is excluded "
            + "because exact comparison, not folding, is what matched here")
    }

    /// A child of INBOX folds at the root and stays exact below it.
    func testInboxChild_rootFoldsButTheChildDoesNot() throws {
        let reader = try makeReader()
        XCTAssertEqual(try count(reader, mailbox: "inbox/Sub"), 1,
            "root folds, child compares exactly")
        XCTAssertThrowsError(try count(reader, mailbox: "inbox/sub"),
            "the child is not INBOX, so 'sub' must not fold — and the near-miss "
            + "diagnostic should name the real one rather than return a silent zero")
    }

    func testDescendantAndLeafSemanticsPreserved() throws {
        let reader = try makeReader()
        // Leaf query reaching a nested mailbox (component run at the end).
        XCTAssertEqual(try count(reader, mailbox: "Archive"), 1)
        // Multi-component query matching a full path.
        XCTAssertEqual(try count(reader, mailbox: "R&D/Sent", account: "Alice"), 2)
    }
}
