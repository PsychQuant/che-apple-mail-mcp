import XCTest
import Foundation
@testable import CheAppleMailMCP

/// #299 verify gap-closer (Lens C P1-3): the pure helpers were fully tested, but
/// nothing asserted that a RESOLVED selector actually reaches the AppleScript
/// layer. A handler that computed `addressing` and then passed the caller's raw
/// values would have satisfied every other test in this change.
///
/// These drive the real `MailController.getEmail` through the #254 script-runner
/// seam (no live Mail) and inspect the generated AppleScript source, so the
/// selector's journey from the derived pair into the emitted script is pinned.
final class DerivedAddressingThreadingTests: XCTestCase {

    /// Capture the script text the controller would have executed.
    private func capturedScript(
        mailbox: String, accountName: String, accountId: String?
    ) async throws -> String {
        final class Box: @unchecked Sendable { var script = "" }
        let box = Box()
        await MailController.shared.setTestSeams(
            scriptRunner: { source in
                box.script = source
                // Minimal well-formed reply; getEmail parses a delimited record.
                return ""
            },
            refusal: { nil })
        defer {
            let sem = DispatchSemaphore(value: 0)
            Task { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil); sem.signal() }
            sem.wait()
        }
        _ = try? await MailController.shared.getEmail(
            id: "149482", mailbox: mailbox, accountName: accountName,
            accountId: accountId, format: "text")
        return box.script
    }

    /// The derived pair (account UUID + the account's real localized mailbox
    /// name) must appear in the emitted AppleScript — this is the whole point of
    /// #299: addressing a message the caller could not name.
    func testDerivedPairReachesTheGeneratedScript() async throws {
        let script = try await capturedScript(
            mailbox: "收件匣", accountName: "", accountId: "ABCE3A85-06BE-43BC-9B84-2CA6F325612F")
        XCTAssertTrue(script.contains("account id \"ABCE3A85-06BE-43BC-9B84-2CA6F325612F\""),
                      "the derived account UUID must select the account; got:\n\(script)")
        XCTAssertTrue(script.contains("收件匣"),
                      "the derived localized mailbox name must reach the script; got:\n\(script)")
        XCTAssertTrue(script.contains("whose id is 149482"),
                      "the rowId must anchor the message lookup; got:\n\(script)")
        XCTAssertFalse(script.contains("account \"\""),
                       "an empty display-name selector must never be emitted; got:\n\(script)")
    }

    /// A nested derived path must ride the #174 container chain, not become a
    /// single mailbox whose name contains a slash (which can never match).
    func testNestedDerivedPathBecomesAContainerChain() async throws {
        let script = try await capturedScript(
            mailbox: "[Gmail]/全部郵件", accountName: "",
            accountId: "E51B96AC-9499-4FCC-9638-18F2A300EBFE")
        XCTAssertTrue(script.contains("mailbox \"全部郵件\" of mailbox \"[Gmail]\""),
                      "a nested path must resolve through the container chain (#174); got:\n\(script)")
        XCTAssertFalse(script.contains("whose name is \"[Gmail]/全部郵件\""),
                       "the slash must not survive into a single mailbox name; got:\n\(script)")
    }

    /// The explicit-pair path still emits the legacy display-name selector —
    /// pre-#299 behavior, byte-for-byte.
    func testExplicitDisplayNamePathUnchanged() async throws {
        let script = try await capturedScript(
            mailbox: "INBOX", accountName: "Google", accountId: nil)
        XCTAssertTrue(script.contains("account \"Google\""),
                      "an explicit account_name must still select by display name; got:\n\(script)")
        XCTAssertFalse(script.contains("account id"),
                       "no UUID selector may be invented when the caller named the account; got:\n\(script)")
    }
}
