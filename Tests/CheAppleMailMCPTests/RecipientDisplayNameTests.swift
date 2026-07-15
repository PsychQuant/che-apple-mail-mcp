import XCTest
@testable import CheAppleMailMCP

/// #251 — `to`/`cc`/`bcc` accept RFC 5322 mailbox form `Name <email>`.
/// Names are honored natively on the legacy AppleScript path ({name, address}
/// recipient properties); the mailto URL carries addr-spec only (RFC 6068),
/// so display-name recipients are a named mailto-ineligibility → legacy +
/// disclosure — exactly the custom-from_address trade-off, symmetric.
final class RecipientDisplayNameTests: XCTestCase {

    // MARK: parser

    func testParseRecipient_bareAddress() {
        let r = parseRecipient("ming@example.com")
        XCTAssertNil(r.name)
        XCTAssertEqual(r.address, "ming@example.com")
    }

    func testParseRecipient_nameAndAddress() {
        let r = parseRecipient("王小明 <ming@example.com>")
        XCTAssertEqual(r.name, "王小明")
        XCTAssertEqual(r.address, "ming@example.com")
    }

    func testParseRecipient_quotedName() {
        let r = parseRecipient("\"Wang, Xiaoming\" <ming@example.com>")
        XCTAssertEqual(r.name, "Wang, Xiaoming")
        XCTAssertEqual(r.address, "ming@example.com")
    }

    func testParseRecipient_nameContainingAt_addressStillExtracted() {
        // The old whole-string validation mis-rejected this legal form
        // (atCount == 2). The parser must isolate the addr-spec.
        let r = parseRecipient("ming@lab <ming@example.com>")
        XCTAssertEqual(r.name, "ming@lab")
        XCTAssertEqual(r.address, "ming@example.com")
    }

    func testParseRecipient_whitespaceTolerant() {
        let r = parseRecipient("  Ming  <ming@example.com>  ")
        XCTAssertEqual(r.name, "Ming")
        XCTAssertEqual(r.address, "ming@example.com")
    }

    func testParseRecipient_malformedAngle_treatedAsBare() {
        // No closing bracket → not a mailbox form; pass through as-is so the
        // address validation rejects it with a clear message.
        let r = parseRecipient("Ming <ming@example.com")
        XCTAssertNil(r.name)
        XCTAssertEqual(r.address, "Ming <ming@example.com")
    }

    func testAnyRecipientHasDisplayName() {
        XCTAssertFalse(anyRecipientHasDisplayName(["a@b.c", "d@e.f"]))
        XCTAssertTrue(anyRecipientHasDisplayName(["a@b.c", "王 <d@e.f>"]))
        XCTAssertFalse(anyRecipientHasDisplayName(nil))
        XCTAssertFalse(anyRecipientHasDisplayName([]))
    }

    // MARK: legacy fragment carries the name natively

    func testRecipientFragment_withName_emitsNameProperty() {
        let fragment = recipientFragment(["王小明 <ming@example.com>"], kind: "to")
        XCTAssertTrue(fragment.contains("name:\"王小明\""),
                      "display name must become the recipient's native name property: \(fragment)")
        XCTAssertTrue(fragment.contains("address:\"ming@example.com\""),
                      "the address property must carry the BARE addr-spec: \(fragment)")
        XCTAssertFalse(fragment.contains("address:\"王小明"),
                       "the full mailbox string must never be passed as the address")
    }

    func testRecipientFragment_bare_unchanged() {
        let fragment = recipientFragment(["ming@example.com"], kind: "cc")
        XCTAssertTrue(fragment.contains("{address:\"ming@example.com\"}"),
                      "bare recipients keep the historical single-property form: \(fragment)")
        XCTAssertFalse(fragment.contains("name:"))
    }

    func testRecipientFragment_nameEscaped() {
        let fragment = recipientFragment(["Wang \"Ming\" <ming@example.com>"], kind: "to")
        XCTAssertFalse(fragment.contains("name:\"Wang \"Ming\"\""),
                       "embedded quotes in the name must be AppleScript-escaped: \(fragment)")
    }

    // MARK: mailto ineligibility dimension

    func testIneligibility_displayNameRecipient_namedReason() {
        let reason = mailtoIneligibilityReason(
            format: .plain, accessibilityTrusted: true, disabledByEnv: false,
            hasCustomSender: false, hasSubject: true,
            attachmentsGuiSafe: true,
            recipientsAddrSpecOnly: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("display-name"), reason!)
        XCTAssertTrue(reason!.contains("RFC 6068"), reason!)
    }

    func testIneligibility_bareRecipients_stillEligible() {
        XCTAssertNil(mailtoIneligibilityReason(
            format: .plain, accessibilityTrusted: true, disabledByEnv: false,
            hasCustomSender: false, hasSubject: true,
            attachmentsGuiSafe: true,
            recipientsAddrSpecOnly: true))
    }

    // MARK: production site via the #254 seams

    func testComposeEmail_displayNameRecipient_routesLegacy_withNativeName() async throws {
        defer { Task { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) } }
        var scripts: [String] = []
        await MailController.shared.setTestSeams(
            scriptRunner: { script in scripts.append(script); return "Email sent successfully" },
            ineligibility: nil)   // real probe — display-name recipient must trip it
        let result = try await MailController.shared.composeEmail(
            to: ["王小明 <ming@example.com>"], subject: "s", body: "b")
        XCTAssertTrue(result.hasPrefix("Email sent successfully"))
        XCTAssertTrue(result.contains("[legacy path"),
                      "display-name recipients must route to the legacy path with disclosure: \(result)")
        let legacyScript = try XCTUnwrap(scripts.last)
        XCTAssertTrue(legacyScript.contains("name:\"王小明\""),
                      "the legacy script must set the recipient's native name: \(legacyScript.prefix(300))")
        XCTAssertFalse(scripts.contains { $0.contains("mailto ") },
                       "the mailto GUI path must never be attempted with display-name recipients")
    }

    func testValidation_nameWithAt_noLongerMisRejected() async throws {
        defer { Task { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) } }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Draft created successfully" },
            ineligibility: nil)
        // Previously atCount==2 rejected this legal RFC 5322 mailbox outright.
        let result = try await MailController.shared.createDraft(
            to: ["ming@lab <ming@example.com>"], subject: "s", body: "b")
        XCTAssertTrue(result.hasPrefix("Draft created successfully"))
    }
}
