import XCTest
@testable import CheAppleMailMCP

/// #315 — `<type>_path` is now derived by joining the AppleScript-identified
/// LEAF against the account's Envelope-Index mailbox paths, replacing the
/// container walk that could not work: enumerating `every mailbox of <unified
/// container>` yields references whose `container` is not a mailbox on first
/// probe, so the walk succeeded VACUOUSLY — emitting the leaf as the "full
/// path" for genuinely nested mailboxes, indistinguishable on the wire from a
/// correct top-level result (4 of 5 types wrong on every one of 7 live
/// accounts; the documented omit-on-failure fallback never fired because
/// nothing ever failed).
final class SpecialMailboxPathJoinTests: XCTestCase {

    private let gmailPaths = [
        "INBOX",
        "[Gmail]/全部郵件", "[Gmail]/寄件備份", "[Gmail]/草稿",
        "[Gmail]/垃圾郵件", "[Gmail]/垃圾桶", "[Gmail]/已加星號",
    ]

    // The issue's measured table: 4 of 5 leaves are nested, inbox is top-level.
    func testGmailLeaves_resolveToFullNestedPaths() {
        XCTAssertEqual(joinSpecialMailboxPath(leaf: "草稿", mailboxPaths: gmailPaths), "[Gmail]/草稿")
        XCTAssertEqual(joinSpecialMailboxPath(leaf: "寄件備份", mailboxPaths: gmailPaths), "[Gmail]/寄件備份")
        XCTAssertEqual(joinSpecialMailboxPath(leaf: "垃圾郵件", mailboxPaths: gmailPaths), "[Gmail]/垃圾郵件")
        XCTAssertEqual(joinSpecialMailboxPath(leaf: "垃圾桶", mailboxPaths: gmailPaths), "[Gmail]/垃圾桶")
    }

    func testTopLevelLeaf_pathEqualsLeaf() {
        XCTAssertEqual(joinSpecialMailboxPath(leaf: "INBOX", mailboxPaths: gmailPaths), "INBOX")
    }

    /// Ambiguity → nil, never a guess. Two mailboxes sharing a leaf make the
    /// join undecidable; the honest answer is to omit `_path` so the consumer
    /// falls back to leaf comparison — the observable signal #268 promised.
    func testAmbiguousLeaf_returnsNil() {
        let paths = ["垃圾桶", "專案/垃圾桶"]
        XCTAssertNil(joinSpecialMailboxPath(leaf: "垃圾桶", mailboxPaths: paths),
                     "two candidates for one leaf must omit the path, not pick one")
    }

    func testUnknownLeaf_returnsNil() {
        XCTAssertNil(joinSpecialMailboxPath(leaf: "NoSuchLeaf", mailboxPaths: gmailPaths))
        XCTAssertNil(joinSpecialMailboxPath(leaf: "草稿", mailboxPaths: []),
                     "no index data (EWS / no FDA) → omit, never fabricate")
    }

    /// A leaf must match only at a path boundary — `垃圾桶` must not match a
    /// mailbox named `大垃圾桶`.
    func testLeafMatchesOnlyAtBoundary() {
        let paths = ["[Gmail]/大垃圾桶"]
        XCTAssertNil(joinSpecialMailboxPath(leaf: "垃圾桶", mailboxPaths: paths))
    }

    /// A leaf that IS a full nested path already present passes through — the
    /// AppleScript side hands us leaves, but be tolerant if a provider reports
    /// a name containing no nesting ambiguity.
    func testExactFullPathLeaf_passesThrough() {
        XCTAssertEqual(joinSpecialMailboxPath(leaf: "[Gmail]/草稿", mailboxPaths: gmailPaths),
                       "[Gmail]/草稿")
    }
}
