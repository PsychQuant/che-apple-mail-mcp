import XCTest
@testable import MailSQLite

/// #211 made the FDA-denied failure loud but pinned the wrong target (the MCP
/// binary). macOS TCC grants Full Disk Access to the **responsible process** —
/// for a Claude-Code-spawned server in a terminal that is the terminal app, not
/// the binary (#214, root-caused via `launchctl procinfo`). #214 verify also
/// proved there is no reliable in-process API to resolve the exact responsible
/// app (`responsibility_get_pid_responsible_for_pid` returns self for terminal-
/// and CLI-launched processes), so the message names the likely candidates
/// (terminal first, binary as direct-launch fallback) in a single deterministic
/// block. These tests pin that contract so a future edit can't regress it back
/// to "grant the binary".
final class FullDiskAccessHelpTests: XCTestCase {

    func testGuidanceContainsSettingsDeepLink() {
        let msg = FullDiskAccessHelp.guidance(reason: "Test reason.")
        XCTAssertTrue(
            msg.contains("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
            "guidance must deep-link to the Full Disk Access settings pane; got: \(msg)"
        )
    }

    func testGuidanceNamesTheResponsibleProcessMechanism() {
        // The core #214 fix: the message must explain that TCC grants FDA to the
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

    func testGuidanceNamesBothTerminalAndBinaryDeterministically() {
        // Single deterministic message (no SPI branch): it must always carry both
        // the responsible-process/terminal target AND the binary direct-launch
        // fallback AND the deep-link — so a regression to either-only is caught.
        let msg = FullDiskAccessHelp.guidance(reason: "Test reason.")
        XCTAssertTrue(msg.contains("Privacy_AllFiles"), "must keep deep-link; got: \(msg)")
        XCTAssertTrue(msg.lowercased().contains("responsible process"),
                      "must name the responsible-process mechanism; got: \(msg)")
        XCTAssertTrue(msg.lowercased().contains("terminal"),
                      "must name the terminal as the launching app; got: \(msg)")
        XCTAssertTrue(msg.contains(FullDiskAccessHelp.binaryPath()),
                      "must name the binary as the direct-launch fallback; got: \(msg)")
    }

    func testBinaryPathIsNonEmpty() {
        XCTAssertFalse(FullDiskAccessHelp.binaryPath().isEmpty)
    }

    func testUnavailableSuffixIsActionableResponsibleProcessFirstAndKeepsBinary() {
        let s = FullDiskAccessHelp.unavailableSuffix()
        XCTAssertTrue(s.contains("Privacy_AllFiles"), "suffix must carry the deep-link; got: \(s)")
        XCTAssertTrue(s.contains("Full Disk Access"), "suffix must name Full Disk Access; got: \(s)")
        XCTAssertTrue(
            s.lowercased().contains("app running this server"),
            "suffix must point at the app running this server (responsible process); got: \(s)"
        )
        XCTAssertTrue(
            s.contains(FullDiskAccessHelp.binaryPath()),
            "suffix must keep the binary path for the direct-launch / Claude Desktop case; got: \(s)"
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
