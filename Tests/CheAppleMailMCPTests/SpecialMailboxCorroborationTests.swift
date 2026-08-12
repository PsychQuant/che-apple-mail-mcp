import XCTest
@testable import CheAppleMailMCP

/// #345 — a unique leaf match is not proof of identity.
///
/// #315's join picks a full path when exactly one Envelope-Index mailbox path
/// equals the AppleScript leaf or ends in `"/" + leaf`. That is decided purely
/// by string shape. If the account's real Drafts mailbox is not in the index
/// yet (fresh account, lagging sync) while an ordinary `Projects/Drafts`
/// folder is, the ordinary folder wins uncontested and is returned as
/// `drafts_path` — wire-indistinguishable from a correct answer, with the
/// documented fail-safe never firing because nothing failed.
///
/// The issue's fallback suggestion — "omit when the only candidate is nested" —
/// cannot be used: Gmail's REAL drafts mailbox is `[Gmail]/草稿`, nested, and is
/// the single most common configuration. Its primary suggestion (cross-check
/// against role data in the index) is also closed: per
/// `.claude/rules/r-must-direct-db.md` the `mailboxes` table holds only
/// `url / total_count / unread_count` — there is no special-mailbox role column.
///
/// So corroboration has to come from data already in hand. It does: the five
/// special leaves are resolved TOGETHER, and a genuine provider container holds
/// SEVERAL of them. `[Gmail]` is the parent of drafts, sent, junk and trash;
/// `Projects` is the parent of exactly one. Convergence is the signal.
final class SpecialMailboxCorroborationTests: XCTestCase {

    private let gmail = ["INBOX", "[Gmail]/草稿", "[Gmail]/寄件備份",
                         "[Gmail]/垃圾郵件", "[Gmail]/垃圾桶", "[Gmail]/所有郵件"]

    private func leaves(_ pairs: [(String, String)]) -> [(key: String, leaf: String)] {
        pairs.map { (key: $0.0, leaf: $0.1) }
    }

    // MARK: - the reported defect

    func testLoneNestedLookalikeIsOmittedRatherThanReturnedAsTheSpecialMailbox() {
        // The real Drafts is absent from the index; only an ordinary folder
        // shares the leaf. Exactly one candidate — the old join returned it.
        let paths = ["INBOX", "Projects/Drafts", "Projects/Notes", "Archive"]
        let joined = joinSpecialMailboxPaths(leaves: leaves([("drafts", "Drafts")]),
                                             mailboxPaths: paths)
        XCTAssertNil(joined["drafts"],
            "Projects/Drafts is one folder that happens to end in the leaf; nothing "
            + "corroborates it as THE drafts mailbox, so _path must be omitted")
    }

    func testGmailNestedSpecialMailboxesStillResolve() {
        // The case the issue's own fallback suggestion would have broken.
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("drafts", "草稿"), ("sent", "寄件備份"),
                            ("junk", "垃圾郵件"), ("trash", "垃圾桶")]),
            mailboxPaths: gmail)
        XCTAssertEqual(joined["drafts"], "[Gmail]/草稿")
        XCTAssertEqual(joined["sent"], "[Gmail]/寄件備份")
        XCTAssertEqual(joined["junk"], "[Gmail]/垃圾郵件")
        XCTAssertEqual(joined["trash"], "[Gmail]/垃圾桶")
    }

    /// Position is NOT evidence. "Prefer the top-level candidate" is tempting
    /// and wrong: on Gmail the real trash is `[Gmail]/垃圾桶`, so a top-level
    /// folder of the same name would win and produce the very same class of
    /// confident-wrong answer. With nothing to corroborate either reading, the
    /// honest answer stays omission (#315).
    func testTwoReadingsWithNoCorroborationStillOmit() {
        let paths = ["INBOX", "Drafts", "Projects/Drafts"]
        let joined = joinSpecialMailboxPaths(leaves: leaves([("drafts", "Drafts")]),
                                             mailboxPaths: paths)
        XCTAssertNil(joined["drafts"])
    }

    /// …but container evidence CAN break that tie, which the old join could
    /// never do: with `[Gmail]` corroborated by two other special mailboxes,
    /// the nested reading is the supported one.
    func testContainerEvidenceBreaksTheTieTowardTheNestedReading() {
        let paths = ["垃圾桶", "[Gmail]/垃圾桶", "[Gmail]/草稿", "[Gmail]/寄件備份"]
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("trash", "垃圾桶"), ("drafts", "草稿"), ("sent", "寄件備份")]),
            mailboxPaths: paths)
        XCTAssertEqual(joined["trash"], "[Gmail]/垃圾桶",
            "two siblings resolve under [Gmail], so that is the special container")
    }

    func testSingleNestedSpecialIsOmittedWhenNoSiblingCorroboratesItsParent() {
        // Only ONE special mailbox resolves under [Gmail]; the rest are missing
        // from the index. One occurrence is not convergence.
        let paths = ["INBOX", "[Gmail]/草稿"]
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("drafts", "草稿"), ("sent", "寄件備份")]),
            mailboxPaths: paths)
        XCTAssertNil(joined["drafts"],
            "conservative by design: with nothing to corroborate the container, omission "
            + "is the contract — the leaf itself is still returned to the caller")
    }

    func testTwoSpecialsSharingAParentCorroborateEachOther() {
        let paths = ["INBOX", "[Gmail]/草稿", "[Gmail]/寄件備份"]
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("drafts", "草稿"), ("sent", "寄件備份")]),
            mailboxPaths: paths)
        XCTAssertEqual(joined["drafts"], "[Gmail]/草稿")
        XCTAssertEqual(joined["sent"], "[Gmail]/寄件備份")
    }

    func testAmbiguousLeafStillOmits() {
        let paths = ["A/Drafts", "B/Drafts"]
        let joined = joinSpecialMailboxPaths(leaves: leaves([("drafts", "Drafts")]),
                                             mailboxPaths: paths)
        XCTAssertNil(joined["drafts"], "#315's ambiguity omission must survive")
    }

    func testUnknownLeafAndEmptyIndexOmit() {
        XCTAssertNil(joinSpecialMailboxPaths(leaves: leaves([("drafts", "Nope")]),
                                             mailboxPaths: gmail)["drafts"])
        XCTAssertNil(joinSpecialMailboxPaths(leaves: leaves([("drafts", "草稿")]),
                                             mailboxPaths: [])["drafts"])
        XCTAssertNil(joinSpecialMailboxPaths(leaves: leaves([("drafts", "")]),
                                             mailboxPaths: gmail)["drafts"])
    }

    func testFullyQualifiedLeafStillMatchesItself() {
        // #315 behaviour: some accounts report the leaf already qualified.
        let joined = joinSpecialMailboxPaths(leaves: leaves([("drafts", "[Gmail]/草稿")]),
                                             mailboxPaths: gmail)
        XCTAssertEqual(joined["drafts"], "[Gmail]/草稿")
    }

    func testMixedTopLevelAndNestedAccountResolvesBoth() {
        // INBOX top-level, the rest under [Gmail] — a real IMAP shape.
        let paths = ["INBOX", "[Gmail]/草稿", "[Gmail]/寄件備份"]
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("inbox", "INBOX"), ("drafts", "草稿"), ("sent", "寄件備份")]),
            mailboxPaths: paths)
        XCTAssertEqual(joined["inbox"], "INBOX")
        XCTAssertEqual(joined["drafts"], "[Gmail]/草稿")
    }
}
