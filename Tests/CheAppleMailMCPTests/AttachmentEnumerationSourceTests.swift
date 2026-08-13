import XCTest
@testable import CheAppleMailMCP

/// #365 — `list_attachments` returned `[]` for messages that demonstrably carry
/// attachments on disk, silently.
///
/// The candidate set was seeded **exclusively** from the Envelope Index, and
/// the `.emlx` was used only as a filter, so the result was a pure
/// intersection:
///
///     result = SQLite_rows ∩ emlx_parsed_names
///
/// Apple Mail does not write `attachments` rows for messages it composed and
/// sent itself, so for outgoing mail `SQLite_rows = ∅` and the intersection is
/// empty no matter what the `.emlx` holds. Confirmed against the live index —
/// rowIds 290037 / 290102 / 290338 (all sent) have **0** rows while their
/// `.emlx` files carry 1 / 2 / 2 attachments; a received message (288967) has 1.
///
/// The observable signature is the asymmetry: `save_attachment` succeeds on the
/// exact tuple `list_attachments` fails on, because retrieval parses the
/// `.emlx` directly and never consults SQLite. **Enumeration was SQLite-gated;
/// retrieval was not.**
final class AttachmentEnumerationSourceTests: XCTestCase {

    func testEmlxOnlyAttachmentsAreEnumeratedWhenSQLiteHasNoRows() {
        // The reported shape: Mail wrote no attachment rows for its own sent
        // message, but the .emlx carries two parts.
        let result = crossValidateAttachments(
            sqliteAttachments: [],
            realNames: ["report.pdf", "data.csv"],
            savability: ["report.pdf": true, "data.csv": true])
        XCTAssertEqual(Set(result.compactMap { $0["name"] as? String }), ["report.pdf", "data.csv"],
            "the .emlx is ground truth for what the message CONTAINS; SQLite is a cache "
            + "that Mail never populates for its own sent mail")
    }

    func testSQLiteRowsStillWinTheirMetadataWhenBothAgree() {
        let result = crossValidateAttachments(
            sqliteAttachments: [["name": "report.pdf", "attachment_id": "3"]],
            realNames: ["report.pdf"],
            savability: ["report.pdf": true])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["attachment_id"] as? String, "3",
            "the SQLite part id must survive — save_attachment's name-free part-dir "
            + "probe depends on it (#183)")
        XCTAssertEqual(result[0]["savable"] as? Bool, true)
    }

    /// #24's original defect must stay fixed: SQLite keeps rows after Mail
    /// strips the binary, and those stale names must NOT be reported.
    func testStaleSQLiteRowAbsentFromTheEmlxIsStillDropped() {
        let result = crossValidateAttachments(
            sqliteAttachments: [["name": "stripped.pdf", "attachment_id": "2"]],
            realNames: [],
            savability: [:])
        XCTAssertTrue(result.isEmpty,
            "a name the .emlx does not contain is stale cache, not an attachment (#24)")
    }

    func testUnionOfBothSourcesIsReturned() {
        let result = crossValidateAttachments(
            sqliteAttachments: [["name": "known.pdf", "attachment_id": "2"],
                                ["name": "stale.doc", "attachment_id": "9"]],
            realNames: ["known.pdf", "unindexed.csv"],
            savability: ["known.pdf": true, "unindexed.csv": false],
            unsavableReasons: ["unindexed.csv": "not_downloaded"])
        let names = Set(result.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["known.pdf", "unindexed.csv"],
            "present-on-disk wins; stale.doc is dropped and unindexed.csv is added")
        let csv = result.first { $0["name"] as? String == "unindexed.csv" }
        XCTAssertEqual(csv?["savable"] as? Bool, false)
        XCTAssertEqual(csv?["savable_reason"] as? String, "not_downloaded",
            "an emlx-sourced entry carries the same savability contract as a SQLite one")
    }

    func testEmlxSourcedEntryHasNoFabricatedAttachmentId() throws {
        let result = crossValidateAttachments(
            sqliteAttachments: [], realNames: ["only.pdf"], savability: ["only.pdf": true])
        let entry = try XCTUnwrap(result.first, "the emlx-sourced entry must be present")
        XCTAssertNil(entry["attachment_id"],
            "there is no SQLite row, so there is no part id — inventing one would send "
            + "save_attachment's part-dir probe after a directory that does not exist")
    }

    func testOrderIsDeterministic() {
        let a = crossValidateAttachments(sqliteAttachments: [], realNames: ["b.txt", "a.txt", "c.txt"])
        let b = crossValidateAttachments(sqliteAttachments: [], realNames: ["c.txt", "b.txt", "a.txt"])
        XCTAssertEqual(a.compactMap { $0["name"] as? String },
                       b.compactMap { $0["name"] as? String },
            "Set iteration order is not stable across runs; the output must be")
    }
}
