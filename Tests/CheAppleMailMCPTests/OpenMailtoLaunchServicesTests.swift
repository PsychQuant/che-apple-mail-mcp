import XCTest
@testable import CheAppleMailMCP

/// #287 — `open_mailto` goes through LaunchServices (NSWorkspace), not
/// AppleScript: zero Automation TCC, inherently cite-block-free (#175).
/// The openURL seam substitutes for NSWorkspace so no real window opens.
final class OpenMailtoLaunchServicesTests: XCTestCase {

    func testOpenMailto_validURL_handsOffViaLaunchServices() async throws {
        // The seam must receive the parsed URL; NO AppleScript may run (a
        // scriptRunner XCTFail seam proves the -1743-prone path is gone).
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        nonisolated(unsafe) var openedURL: URL?
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("open_mailto must not run AppleScript (#287)"); return "" },
            refusal: nil,
            openURL: { url in openedURL = url; return true })
        let r = try await MailController.shared.openMailtoURL(
            url: "mailto:a@example.com?subject=Hello")
        XCTAssertEqual(openedURL?.absoluteString, "mailto:a@example.com?subject=Hello")
        XCTAssertTrue(r.contains("LaunchServices"), "result must disclose the hand-off mechanism")
        XCTAssertTrue(r.contains("default mail client"), "result must disclose the default-client caveat")
    }

    func testOpenMailto_nonMailtoURL_rejected() async throws {
        // Scheme guard: the old AppleScript path forwarded ANY string; the
        // LaunchServices path must refuse non-mailto URLs (an https: URL here
        // would silently open a browser).
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        nonisolated(unsafe) var called = false
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("no AppleScript"); return "" },
            refusal: nil,
            openURL: { _ in called = true; return true })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.openMailtoURL(url: "https://example.com"))
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.openMailtoURL(url: "not a url at all \u{0}"))
        XCTAssertFalse(called, "the seam must never fire for a rejected URL")
    }

    func testOpenMailto_handlerMissing_failsLoud() async throws {
        // NSWorkspace.open returning false (no mailto: handler) must surface
        // an actionable error, not a fake success.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("no AppleScript"); return "" },
            refusal: nil,
            openURL: { _ in false })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.openMailtoURL(url: "mailto:a@example.com"))
    }

    func testOpenMailtoToolDescription_advertisesLadder() {
        // The schema description must carry the cite-block-avoidance ladder +
        // the zero-TCC claim (#287 documentation surface, consumer-facing).
        let tool = CheAppleMailMCPServer.defineTools().first { $0.name == "open_mailto" }
        let desc = tool?.description ?? ""
        XCTAssertTrue(desc.contains("ZERO Automation TCC"), "must advertise the zero-TCC property")
        XCTAssertTrue(desc.contains("-1743"), "must name the failure code it escapes")
        XCTAssertTrue(desc.contains("cite-block-free"), "must state the cite-block property")
        XCTAssertTrue(desc.contains("(c) legacy AppleScript injection"), "must spell out the full ladder")
    }
}
