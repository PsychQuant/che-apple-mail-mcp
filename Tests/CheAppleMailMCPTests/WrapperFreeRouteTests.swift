import XCTest
@testable import CheAppleMailMCP

/// #241 — regression-lock for the #237/#229 disclosure WIRING. The pure
/// helpers (`mailtoIneligibilityReason`, `legacyPathDisclosure`, …) were
/// already pinned, but the control flow that calls them lived inline in a
/// singleton actor and had zero non-live coverage: deleting the wiring kept
/// the whole suite green. `routeWrapperFreeCompose` extracts that control
/// flow behind injectable closures so these tests can drive all branches.
final class WrapperFreeRouteTests: XCTestCase {

    private enum Boom: Error, LocalizedError {
        case gui(String)
        var errorDescription: String? {
            if case .gui(let m) = self { return m }
            return "boom"
        }
    }

    /// Route call with spy closures; returns (result, warnsIneligible,
    /// warnsFailed, cleanCalls, legacyCalls).
    private func drive(
        reason: String?,
        clean: @escaping () throws -> String,
        legacy: @escaping () throws -> String = { "Legacy OK" }
    ) throws -> (result: String, ineligibleWarns: [String], failedWarns: [String],
                 cleanCalls: Int, legacyCalls: Int) {
        var ineligibleWarns: [String] = []
        var failedWarns: [String] = []
        var cleanCalls = 0
        var legacyCalls = 0
        let result = try routeWrapperFreeCompose(
            ineligibilityReason: reason,
            cleanPath: { cleanCalls += 1; return try clean() },
            legacyPath: { legacyCalls += 1; return try legacy() },
            disclosure: { legacyPathDisclosure(reason: $0) },
            warnIneligible: { ineligibleWarns.append($0) },
            warnTriedAndFailed: { failedWarns.append($0.localizedDescription) },
            fallbackReason: { "mailto GUI path failed: \(clampedErrorEcho($0.localizedDescription))" })
        return (result, ineligibleWarns, failedWarns, cleanCalls, legacyCalls)
    }

    func testEligible_cleanSucceeds_noSuffix_noWarns_legacyNeverRuns() throws {
        let r = try drive(reason: nil, clean: { "Draft created successfully" })
        XCTAssertEqual(r.result, "Draft created successfully",
                       "clean-path result must carry NO legacy disclosure suffix")
        XCTAssertFalse(r.result.contains("[legacy path"))
        XCTAssertTrue(r.ineligibleWarns.isEmpty)
        XCTAssertTrue(r.failedWarns.isEmpty)
        XCTAssertEqual(r.cleanCalls, 1)
        XCTAssertEqual(r.legacyCalls, 0)
    }

    func testEligible_cleanThrows_warnsOnce_legacyResultCarriesClampedReason() throws {
        let r = try drive(reason: nil, clean: { throw Boom.gui("window vanished\nline2") })
        XCTAssertEqual(r.failedWarns.count, 1, "tried-and-failed warn fires exactly once")
        XCTAssertTrue(r.ineligibleWarns.isEmpty, "ineligible warn must NOT fire on the tried branch")
        XCTAssertEqual(r.legacyCalls, 1)
        XCTAssertTrue(r.result.hasPrefix("Legacy OK"))
        XCTAssertTrue(r.result.contains("Reason: mailto GUI path failed: window vanished line2."),
                      "suffix must name the reason with the newline-folded (clamped) error echo: \(r.result)")
        XCTAssertFalse(r.result.contains("\n"), "clamped echo keeps the suffix single-line")
    }

    func testIneligible_warnsOnce_cleanNeverRuns_suffixNamesReason() throws {
        let reason = "custom from_address forces the legacy path until #219"
        let r = try drive(reason: reason, clean: { XCTFail("clean path must not run"); return "" })
        XCTAssertEqual(r.ineligibleWarns, [reason], "ineligible warn fires exactly once with the named reason")
        XCTAssertTrue(r.failedWarns.isEmpty)
        XCTAssertEqual(r.cleanCalls, 0)
        XCTAssertEqual(r.legacyCalls, 1)
        XCTAssertTrue(r.result.contains("Reason: \(reason)."),
                      "suffix must carry the ineligibility reason verbatim: \(r.result)")
    }

    func testLegacyThrow_propagates_fromBothBranches() {
        XCTAssertThrowsError(try drive(reason: "some reason",
                                       clean: { "" },
                                       legacy: { throw Boom.gui("legacy died") }))
        XCTAssertThrowsError(try drive(reason: nil,
                                       clean: { throw Boom.gui("clean died") },
                                       legacy: { throw Boom.gui("legacy died") }))
    }

    func testClampIntegration_longMultilineErrorBounded() throws {
        let longError = String(repeating: "x", count: 500) + "\r\n" + String(repeating: "y", count: 500)
        let r = try drive(reason: nil, clean: { throw Boom.gui(longError) })
        let suffix = r.result.dropFirst("Legacy OK".count)
        // legacyPathDisclosure's fixed boilerplate is ~330 chars; the clamped
        // echo adds at most ~200 more. 1000-char input must not reach 600.
        XCTAssertLessThan(suffix.count, 600,
                          "clamped echo caps the disclosure suffix length: \(suffix.count) chars")
        XCTAssertFalse(suffix.contains("\n"))
        XCTAssertFalse(suffix.contains("\r"))
    }

    func testWiring_allFourCallSitesRouteThroughTheRouter() throws {
        // The actual #241 target: the WIRING must not be deletable while the
        // suite stays green. Pin all four compose-family call sites onto the
        // router (compose_email, create_draft, reply_email, forward_email).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let count = source.components(separatedBy: "try routeWrapperFreeCompose(").count - 1
        XCTAssertEqual(count, 4,
                       "expected compose/createDraft/reply/forward to route via routeWrapperFreeCompose; found \(count)")
        XCTAssertFalse(source.contains("var legacyReason"),
                       "inline wiring must be gone — replaced by the router (#241)")
        XCTAssertFalse(source.contains("var legacyReplyReason"))
        XCTAssertFalse(source.contains("var legacyForwardReason"))
    }
}
