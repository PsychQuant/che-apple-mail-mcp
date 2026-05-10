import XCTest
@testable import CheAppleMailMCP

/// Regression tests for #73 — `MailController.extractHTMLBody` AppleScript
/// fallback path was decoding only `quoted-printable`, not `base64`. Common
/// on Android Gmail / Outlook Mobile messages, where SQLite-cache miss
/// would surface raw base64 to the caller.
///
/// These tests exercise the parser as a pure function — no AppleScript /
/// Mail.app involvement. The method was promoted from `private` to
/// internal access so the test bundle can call it via `@testable import`.
final class MailControllerHtmlExtractionTests: XCTestCase {

    private let boundary = "test-boundary-9F3"

    // Builds a multipart/alternative MIME source with given HTML payload
    // and Content-Transfer-Encoding. \r\n line endings to match RFC 822.
    private func multipart(htmlBody: String, encoding: String) -> String {
        return [
            "Content-Type: multipart/alternative; boundary=\"\(boundary)\"",
            "",
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 7bit",
            "",
            "plain fallback ignored",
            "--\(boundary)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: \(encoding)",
            "",
            htmlBody,
            "--\(boundary)--",
            ""
        ].joined(separator: "\r\n")
    }

    // MARK: - quoted-printable (legacy path, regression)

    func testExtractHTMLBody_quotedPrintable_decodesEqualsSequences() async {
        let mime = multipart(
            htmlBody: "<p>caf=C3=A9 r=C3=A9sum=C3=A9</p>",
            encoding: "quoted-printable"
        )
        let result = await MailController.shared.extractHTMLBody(from: mime)
        XCTAssertTrue(result.contains("café résumé"),
                      "quoted-printable =XX hex sequences must be decoded; got: \(result)")
    }

    // MARK: - base64 (#73 NEW)

    func testExtractHTMLBody_base64_decodesPayload() async {
        let plain = "<html><body><h1>Hello from Android Gmail</h1></body></html>"
        let encoded = Data(plain.utf8).base64EncodedString()
        let mime = multipart(htmlBody: encoded, encoding: "base64")

        let result = await MailController.shared.extractHTMLBody(from: mime)

        XCTAssertEqual(result, plain,
                       "base64-encoded HTML must round-trip to its original; got: \(result)")
        XCTAssertFalse(result.contains(encoded),
                       "raw base64 must not leak into output: \(result)")
    }

    func testExtractHTMLBody_base64WithLineWrapping_stillDecodes() async {
        let plain = String(repeating: "<p>line</p>", count: 50)
        var encoded = Data(plain.utf8).base64EncodedString()
        // RFC 2045 §6.8 limits base64 lines to 76 chars; insert breaks.
        var wrapped = ""
        var idx = encoded.startIndex
        while idx < encoded.endIndex {
            let end = encoded.index(idx, offsetBy: min(76, encoded.distance(from: idx, to: encoded.endIndex)))
            wrapped += encoded[idx..<end] + "\r\n"
            idx = end
        }
        encoded = wrapped.trimmingCharacters(in: .whitespacesAndNewlines)

        let mime = multipart(htmlBody: encoded, encoding: "base64")
        let result = await MailController.shared.extractHTMLBody(from: mime)

        XCTAssertEqual(result, plain,
                       "wrapped base64 (76-char lines) must still round-trip; got first 80: \(String(result.prefix(80)))")
    }

    // MARK: - 7bit passthrough

    func testExtractHTMLBody_7bit_returnsAsIs() async {
        let plain = "<p>plain ASCII passthrough</p>"
        let mime = multipart(htmlBody: plain, encoding: "7bit")
        let result = await MailController.shared.extractHTMLBody(from: mime)
        XCTAssertTrue(result.contains(plain), "7bit body must passthrough; got: \(result)")
    }

    // MARK: - Graceful degrade on malformed base64

    func testExtractHTMLBody_malformedBase64_doesNotCrashAndReturnsRawHtml() async {
        // Intentionally invalid base64 (no = padding, contains `<` which
        // is not in the alphabet). Decoder returns nil; we should fall
        // through and return the raw lines rather than crashing.
        let bad = "<this is definitely not valid base64>"
        let mime = multipart(htmlBody: bad, encoding: "base64")
        let result = await MailController.shared.extractHTMLBody(from: mime)
        XCTAssertTrue(result.contains(bad),
                      "malformed base64 must degrade to raw passthrough, not crash; got: \(result)")
    }
}
