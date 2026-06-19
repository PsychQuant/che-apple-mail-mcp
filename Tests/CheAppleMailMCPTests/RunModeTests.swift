import XCTest
@testable import CheAppleMailMCP

/// #213 — `--setup` / `--check-fda` must divert before the stdio server starts,
/// and crucially the no-flag default must stay `.server` so the MCP path is
/// untouched. These pin the dispatch contract.
final class RunModeTests: XCTestCase {

    func testNoFlagsDefaultsToServer() {
        XCTAssertEqual(RunMode.parse(["/usr/bin/CheAppleMailMCP"]), .server)
        XCTAssertEqual(RunMode.parse([]), .server)
    }

    func testSetupFlagSelectsSetup() {
        XCTAssertEqual(RunMode.parse(["bin", "--setup"]), .setup)
    }

    func testCheckFdaFlagSelectsCheckFDA() {
        XCTAssertEqual(RunMode.parse(["bin", "--check-fda"]), .checkFDA)
    }

    func testSetupWinsOverCheckFda() {
        // If both are present the GUI (richer) wins — deterministic, not argv-order dependent.
        XCTAssertEqual(RunMode.parse(["bin", "--check-fda", "--setup"]), .setup)
        XCTAssertEqual(RunMode.parse(["bin", "--setup", "--check-fda"]), .setup)
    }

    func testUnknownFlagsAreIgnoredAndStayServer() {
        // An unrecognized flag must NOT divert — the stdio MCP path is the default.
        XCTAssertEqual(RunMode.parse(["bin", "--verbose", "--whatever"]), .server)
    }
}
