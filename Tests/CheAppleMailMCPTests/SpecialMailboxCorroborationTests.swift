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

    /// Structured entries, split the way the Envelope Index reader now supplies
    /// them (#345 verify) — never by re-splitting the lossy joined path.
    private func boxes(_ paths: [String]) -> [(path: String, components: [String])] {
        paths.map { (path: $0, components: $0.components(separatedBy: "/")) }
    }

    private func leaves(_ pairs: [(String, String)]) -> [(key: String, leaf: String)] {
        pairs.map { (key: $0.0, leaf: $0.1) }
    }

    // MARK: - the reported defect

    func testLoneNestedLookalikeIsOmittedRatherThanReturnedAsTheSpecialMailbox() {
        // The real Drafts is absent from the index; only an ordinary folder
        // shares the leaf. Exactly one candidate — the old join returned it.
        let paths = ["INBOX", "Projects/Drafts", "Projects/Notes", "Archive"]
        let joined = joinSpecialMailboxPaths(leaves: leaves([("drafts", "Drafts")]),
                                             mailboxes: boxes(paths))
        XCTAssertNil(joined["drafts"],
            "Projects/Drafts is one folder that happens to end in the leaf; nothing "
            + "corroborates it as THE drafts mailbox, so _path must be omitted")
    }

    func testGmailNestedSpecialMailboxesStillResolve() {
        // The case the issue's own fallback suggestion would have broken.
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("drafts", "草稿"), ("sent", "寄件備份"),
                            ("junk", "垃圾郵件"), ("trash", "垃圾桶")]),
            mailboxes: boxes(gmail))
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
                                             mailboxes: boxes(paths))
        XCTAssertNil(joined["drafts"])
    }

    /// …but container evidence CAN break that tie, which the old join could
    /// never do: with `[Gmail]` corroborated by two other special mailboxes,
    /// the nested reading is the supported one.
    func testContainerEvidenceBreaksTheTieTowardTheNestedReading() {
        let paths = ["垃圾桶", "[Gmail]/垃圾桶", "[Gmail]/草稿", "[Gmail]/寄件備份"]
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("trash", "垃圾桶"), ("drafts", "草稿"), ("sent", "寄件備份")]),
            mailboxes: boxes(paths))
        XCTAssertEqual(joined["trash"], "[Gmail]/垃圾桶",
            "two siblings resolve under [Gmail], so that is the special container")
    }

    func testSingleNestedSpecialIsOmittedWhenNoSiblingCorroboratesItsParent() {
        // Only ONE special mailbox resolves under [Gmail]; the rest are missing
        // from the index. One occurrence is not convergence.
        let paths = ["INBOX", "[Gmail]/草稿"]
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("drafts", "草稿"), ("sent", "寄件備份")]),
            mailboxes: boxes(paths))
        XCTAssertNil(joined["drafts"],
            "conservative by design: with nothing to corroborate the container, omission "
            + "is the contract — the leaf itself is still returned to the caller")
    }

    func testTwoSpecialsSharingAParentCorroborateEachOther() {
        let paths = ["INBOX", "[Gmail]/草稿", "[Gmail]/寄件備份"]
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("drafts", "草稿"), ("sent", "寄件備份")]),
            mailboxes: boxes(paths))
        XCTAssertEqual(joined["drafts"], "[Gmail]/草稿")
        XCTAssertEqual(joined["sent"], "[Gmail]/寄件備份")
    }

    func testAmbiguousLeafStillOmits() {
        let paths = ["A/Drafts", "B/Drafts"]
        let joined = joinSpecialMailboxPaths(leaves: leaves([("drafts", "Drafts")]),
                                             mailboxes: boxes(paths))
        XCTAssertNil(joined["drafts"], "#315's ambiguity omission must survive")
    }

    func testUnknownLeafAndEmptyIndexOmit() {
        XCTAssertNil(joinSpecialMailboxPaths(leaves: leaves([("drafts", "Nope")]),
                                             mailboxes: boxes(gmail))["drafts"])
        XCTAssertNil(joinSpecialMailboxPaths(leaves: leaves([("drafts", "草稿")]),
                                             mailboxes: boxes([]))["drafts"])
        XCTAssertNil(joinSpecialMailboxPaths(leaves: leaves([("drafts", "")]),
                                             mailboxes: boxes(gmail))["drafts"])
    }

    func testFullyQualifiedLeafStillMatchesItself() {
        // #315 behaviour: some accounts report the leaf already qualified.
        let joined = joinSpecialMailboxPaths(leaves: leaves([("drafts", "[Gmail]/草稿")]),
                                             mailboxes: boxes(gmail))
        XCTAssertEqual(joined["drafts"], "[Gmail]/草稿")
    }

    func testMixedTopLevelAndNestedAccountResolvesBoth() {
        // INBOX top-level, the rest under [Gmail] — a real IMAP shape.
        let paths = ["INBOX", "[Gmail]/草稿", "[Gmail]/寄件備份"]
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("inbox", "INBOX"), ("drafts", "草稿"), ("sent", "寄件備份")]),
            mailboxes: boxes(paths))
        XCTAssertEqual(joined["inbox"], "INBOX")
        XCTAssertEqual(joined["drafts"], "[Gmail]/草稿")
    }
}

/// #345 verify round (cross-model) — three defects in the first fix.
final class SpecialMailboxCorroborationVerifyTests: XCTestCase {

    private func boxes(_ paths: [String]) -> [(path: String, components: [String])] {
        paths.map { (path: $0, components: $0.components(separatedBy: "/")) }
    }
    private func leaves(_ pairs: [(String, String)]) -> [(key: String, leaf: String)] {
        pairs.map { (key: $0.0, leaf: $0.1) }
    }

    /// The first fix accepted a unique TOP-LEVEL match outright, on the reasoning
    /// that it "has no competing reading". That is the same uniqueness-equals-
    /// identity fallacy the issue is about, and it contradicted the fix's own
    /// stated rule that position is never evidence: with the real `[Gmail]/草稿`
    /// missing from the index and a user folder named `草稿` at the root, it
    /// returned the user folder.
    func testLoneTopLevelLookalikeIsOmittedToo() {
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("drafts", "草稿")]),
            mailboxes: boxes(["INBOX", "草稿", "專案/筆記"]))
        XCTAssertNil(joined["drafts"],
            "a top-level namesake is no more proof of identity than a nested one")
    }

    /// The root is just another container: several specials sitting at it
    /// corroborate each other, exactly as `[Gmail]` does.
    func testSeveralTopLevelSpecialsCorroborateEachOtherAtTheRoot() {
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("drafts", "Drafts"), ("sent", "Sent"), ("trash", "Trash")]),
            mailboxes: boxes(["INBOX", "Drafts", "Sent", "Trash", "Projects/Drafts"]))
        XCTAssertEqual(joined["drafts"], "Drafts")
        XCTAssertEqual(joined["sent"], "Sent")
    }

    /// RFC 3501 §5.1 pins INBOX at the root — a rule, not a guess about
    /// position — so it resolves even when it is the only special indexed.
    func testInboxAtRootResolvesAlone() {
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("inbox", "INBOX")]), mailboxes: boxes(["INBOX", "[Gmail]/草稿"]))
        XCTAssertEqual(joined["inbox"], "INBOX")
    }

    /// One folder must not corroborate ITSELF. If two roles report the same
    /// leaf, the single matching path was counted twice and became its own
    /// evidence — then got returned as both special mailboxes.
    func testOneFolderCannotVoteTwiceForItself() {
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("drafts", "Drafts"), ("sent", "Drafts")]),
            mailboxes: boxes(["INBOX", "Projects/Drafts"]))
        XCTAssertNil(joined["drafts"], "one candidate path is one vote, not two")
        XCTAssertNil(joined["sent"])
    }

    /// Hierarchy must come from components, never from the joined path:
    /// `MailboxURL.mailboxPath` decodes a `%2F` INSIDE a name into a `/`, so a
    /// TOP-LEVEL mailbox literally named `Projects/Drafts` reads as if it were
    /// nested under `Projects` (#344's lossy-path hazard, one layer up).
    ///
    /// The property that matters: it must not fabricate a `Projects` container
    /// that a genuinely nested mailbox could then be corroborated by. Here the
    /// literal-slash mailbox lives at the ROOT and the nested one under
    /// `Projects`, so they are in different containers and neither is
    /// corroborated — whereas the lossy string form put both under `Projects`
    /// and would have accepted both.
    func testLiteralSlashInANameDoesNotFabricateAContainer() {
        let mixed: [(path: String, components: [String])] = [
            ("Projects/Drafts", ["Projects/Drafts"]),   // ONE component: literal slash
            ("Projects/Sent", ["Projects", "Sent"]),    // genuinely nested
        ]
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("drafts", "Projects/Drafts"), ("sent", "Sent")]),
            mailboxes: mixed)
        XCTAssertNil(joined["drafts"],
            "the literal-slash mailbox sits at the root; the nested one is under Projects — "
            + "different containers, so neither corroborates the other")
        XCTAssertNil(joined["sent"])
    }

    /// …while genuinely nested siblings still do.
    func testGenuinelyNestedSiblingsStillCorroborate() {
        let nested: [(path: String, components: [String])] = [
            ("Projects/Drafts", ["Projects", "Drafts"]),
            ("Projects/Sent", ["Projects", "Sent"]),
        ]
        let joined = joinSpecialMailboxPaths(
            leaves: leaves([("drafts", "Drafts"), ("sent", "Sent")]), mailboxes: nested)
        XCTAssertEqual(joined["drafts"], "Projects/Drafts")
    }
}
