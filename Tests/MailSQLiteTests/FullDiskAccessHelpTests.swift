import XCTest
@testable import MailSQLite

/// #211 — the FDA-denied failure must be loud + actionable, not the old
/// silent / "grant it to the terminal application" wording. These tests pin
/// the actionable content so a future edit can't quietly regress it.
final class FullDiskAccessHelpTests: XCTestCase {

    func testGuidanceContainsSettingsDeepLink() {
        let msg = FullDiskAccessHelp.guidance(reason: "Test reason.")
        XCTAssertTrue(
            msg.contains("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
            "guidance must deep-link to the Full Disk Access settings pane; got: \(msg)"
        )
    }

    func testGuidanceNamesTheExactBinaryPath() {
        let msg = FullDiskAccessHelp.guidance(reason: "Test reason.")
        XCTAssertTrue(
            msg.contains(FullDiskAccessHelp.binaryPath()),
            "guidance must name the exact binary path to add; got: \(msg)"
        )
    }

    func testGuidanceDropsWrongTerminalApplicationWording() {
        // An MCP server is launched by Claude Code, not a terminal — the old
        // "terminal application" wording sent users to grant FDA to the wrong app.
        let msg = FullDiskAccessHelp.guidance(reason: "x")
        XCTAssertFalse(
            msg.lowercased().contains("terminal application"),
            "guidance must not tell the user to grant FDA to 'the terminal application'"
        )
    }

    func testBinaryPathIsNonEmpty() {
        XCTAssertFalse(FullDiskAccessHelp.binaryPath().isEmpty)
    }

    func testUnavailableSuffixIsActionable() {
        let s = FullDiskAccessHelp.unavailableSuffix()
        XCTAssertTrue(s.contains("Privacy_AllFiles"), "suffix must carry the deep-link; got: \(s)")
        XCTAssertTrue(s.contains("Full Disk Access"), "suffix must name Full Disk Access; got: \(s)")
    }

    func testEnvelopeIndexReaderMissingDatabaseThrowsActionableMessage() {
        // A non-existent DB path is the FDA-denied / wrong-path failure surface.
        // Pass a non-nil accountMapping so init does not touch the real account map.
        XCTAssertThrowsError(
            try EnvelopeIndexReader(databasePath: "/nonexistent/Mail/Envelope Index",
                                    accountMapping: [:])
        ) { error in
            let desc = (error as? MailSQLiteError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(desc.contains("Privacy_AllFiles"),
                          "missing-DB error must be actionable (deep-link); got: \(desc)")
            XCTAssertFalse(desc.lowercased().contains("terminal application"),
                           "missing-DB error must not say 'terminal application'; got: \(desc)")
        }
    }
}
