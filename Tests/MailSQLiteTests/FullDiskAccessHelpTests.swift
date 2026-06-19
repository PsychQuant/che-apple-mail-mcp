import XCTest
@testable import MailSQLite

/// #211 made the FDA-denied failure loud + actionable, but pinned the wrong
/// target: it told users to grant Full Disk Access to the MCP *binary*. macOS
/// TCC checks the **responsible process** — for a Claude-Code-spawned server in
/// a terminal that is the terminal app, not the binary (#214, root-caused via
/// `launchctl procinfo`). These tests pin the corrected, responsible-process-first
/// contract so a future edit can't regress back to "grant the binary".
final class FullDiskAccessHelpTests: XCTestCase {

    func testGuidanceContainsSettingsDeepLink() {
        let msg = FullDiskAccessHelp.guidance(reason: "Test reason.")
        XCTAssertTrue(
            msg.contains("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
            "guidance must deep-link to the Full Disk Access settings pane; got: \(msg)"
        )
    }

    func testGuidanceNamesTheResponsibleProcessMechanism() {
        // The core #214 fix: the message must explain that TCC checks the
        // responsible process (the app that launched this server), not the binary.
        let msg = FullDiskAccessHelp.guidance(reason: "x").lowercased()
        XCTAssertTrue(
            msg.contains("responsible process"),
            "guidance must name the 'responsible process' mechanism; got: \(msg)"
        )
        XCTAssertTrue(
            msg.contains("terminal"),
            "guidance must point at the launching app (terminal); got: \(msg)"
        )
    }

    func testGuidanceStillNamesBinaryAsDirectLaunchFallback() {
        // The binary path stays in the message as the fallback for direct-launch
        // / Claude Desktop cases — the #211 win (Developer ID grant) is preserved,
        // just demoted below the responsible-process target.
        let msg = FullDiskAccessHelp.guidance(reason: "Test reason.")
        XCTAssertTrue(
            msg.contains(FullDiskAccessHelp.binaryPath()),
            "guidance must still name the binary path for the direct-launch case; got: \(msg)"
        )
    }

    func testBinaryPathIsNonEmpty() {
        XCTAssertFalse(FullDiskAccessHelp.binaryPath().isEmpty)
    }

    func testResponsibleProcessPathDoesNotCrash() {
        // May be nil (same-pid / SPI absent) or a path — both are valid. The
        // contract is only that resolving it never traps.
        let path = FullDiskAccessHelp.responsibleProcessPath()
        if let path = path {
            XCTAssertFalse(path.isEmpty, "a resolved responsible-process path must be non-empty")
        }
    }

    func testUnavailableSuffixIsActionableAndResponsibleProcessFirst() {
        let s = FullDiskAccessHelp.unavailableSuffix()
        XCTAssertTrue(s.contains("Privacy_AllFiles"), "suffix must carry the deep-link; got: \(s)")
        XCTAssertTrue(s.contains("Full Disk Access"), "suffix must name Full Disk Access; got: \(s)")
        XCTAssertTrue(
            s.lowercased().contains("app running this server"),
            "suffix must point at the app running this server (responsible process), not just the binary; got: \(s)"
        )
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
            XCTAssertTrue(desc.lowercased().contains("responsible process"),
                          "missing-DB error must name the responsible-process mechanism; got: \(desc)")
        }
    }
}
