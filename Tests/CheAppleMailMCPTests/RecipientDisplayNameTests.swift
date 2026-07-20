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

    func testParseRecipient_multipleAnglePairs_rejectedNotReinterpreted() {
        // #251 verify REQUIRED (Codex HIGH + DA): "Alice <alice@e.com> <bob@e.net>"
        // must NOT silently become a send to bob. An unquoted name containing
        // angle brackets is malformed (RFC 5322: <> are specials, forbidden in
        // unquoted atoms) → treat as bare so validation rejects on atCount.
        let r = parseRecipient("Alice <alice@example.com> <bob@example.net>")
        XCTAssertNil(r.name, "a name containing angles must not parse as a mailbox form")
        XCTAssertEqual(r.address, "Alice <alice@example.com> <bob@example.net>")
    }

    func testParseRecipient_quotedNameWithAngles_stillAccepted() {
        // Quoted display names may legally contain specials.
        let r = parseRecipient("\"A <b>\" <c@d.e>")
        XCTAssertEqual(r.name, "A <b>")
        XCTAssertEqual(r.address, "c@d.e")
    }

    func testParseRecipient_bareAngle_normalizedToBareAddress() {
        // #251 verify bundled: "<a@b.c>" is an addr-spec in angles — normalize
        // to the bare address instead of passing the brackets downstream.
        let r = parseRecipient("<a@b.c>")
        XCTAssertNil(r.name)
        XCTAssertEqual(r.address, "a@b.c")
    }

    func testValidation_multiAngleInput_rejectedAtBoundary() async throws {
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            ineligibility: nil)
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["Alice <alice@example.com> <bob@example.net>"], subject: "s", body: "b"))
    }

    func testParseRecipient_malformedAngle_treatedAsBare() {
        // No closing bracket → not a mailbox form; pass through as-is so the
        // address validation rejects it with a clear message.
        let r = parseRecipient("Ming <ming@example.com")
        XCTAssertNil(r.name)
        XCTAssertEqual(r.address, "Ming <ming@example.com")
    }

    // MARK: #265 — single-@ malformed multi-angle rejected at the boundary

    func testValidation_singleAtMultiAngle_rejectedAtBoundary() async throws {
        // #265: `Alice <not-an-email> <bob@x>` parses to (nil, whole); the whole
        // string has exactly one '@' so the atCount check passed before this fix.
        // A name==nil fallback that still carries a matched <...> pair is a
        // malformed mailbox form → reject (would otherwise land whole in the
        // script as {address:"Alice <not-an-email> <bob@x>"}).
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            ineligibility: nil)
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["Alice <not-an-email> <bob@example.net>"], subject: "s", body: "b"))
    }

    func testValidation_bareAngleTrailingText_rejectedAtBoundary() async throws {
        // `<bob@x> extra` has no `>` suffix → (nil, whole); whole carries a
        // matched <...> pair → malformed, reject.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            ineligibility: nil)
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["<bob@example.net> extra"], subject: "s", body: "b"))
    }

    func testValidation_legitBareAndBareAngle_stillPass() async throws {
        // Guard against the #265 rejection over-firing: a clean bare addr-spec
        // (no angles) and a bare-angle form (normalized to the inner addr-spec,
        // angles stripped) must both still pass — neither carries a matched
        // <...> pair after parseRecipient.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email sent successfully" }, ineligibility: nil)
        let r1 = try await MailController.shared.composeEmail(
            to: ["plain@example.com"], subject: "s", body: "b")
        XCTAssertTrue(r1.hasPrefix("Email sent successfully"))
        let r2 = try await MailController.shared.composeEmail(
            to: ["<a@b.co>"], subject: "s", body: "b")
        XCTAssertTrue(r2.hasPrefix("Email sent successfully"))
    }

    // MARK: #270 — unpaired stray angles rejected; quoted-local-part angles legal

    func testValidation_unpairedLeadingAngle_rejectedAtBoundary() async throws {
        // #270: `<a@x` — no `>` suffix → parseRecipient returns (nil, "<a@x");
        // the #265 guard required a MATCHED pair (contains both < and >) so a
        // single stray `<` slipped through atCount==1 and landed in the script.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            ineligibility: nil)
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["<a@example.net"], subject: "s", body: "b"))
    }

    func testValidation_unpairedTrailingAngle_rejectedAtBoundary() async throws {
        // #270: `a@x>` — has `>` suffix but no `<` → (nil, "a@x>") with the
        // stray `>` kept; same single-bracket bypass as above.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            ineligibility: nil)
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["a@example.net>"], subject: "s", body: "b"))
    }

    func testValidation_quotedLocalPartAngle_stillPasses() async throws {
        // #270 over-reject guard: `"a<b"@x` is a legal RFC 5322 quoted
        // local-part — the angle lives INSIDE the quoted string and must not
        // trip the unquoted-angle scan (a naive contains-OR gate would).
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email sent successfully" }, ineligibility: nil)
        let r1 = try await MailController.shared.composeEmail(
            to: ["\"a<b\"@example.net"], subject: "s", body: "b")
        XCTAssertTrue(r1.hasPrefix("Email sent successfully"))
        let r2 = try await MailController.shared.composeEmail(
            to: ["\"a>b\"@example.net"], subject: "s", body: "b")
        XCTAssertTrue(r2.hasPrefix("Email sent successfully"))
    }

    func testValidation_quotedMatchedAnglePair_nowLegal() async throws {
        // #270 deliberate behavior change: `"a<b>"@x` (a MATCHED pair entirely
        // inside a quoted local-part) was rejected by the #265 paired-contains
        // guard (documented as unsupported). The quote-aware scan makes it
        // legal again — RFC 5322 allows specials inside quoted strings.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email sent successfully" }, ineligibility: nil)
        let r = try await MailController.shared.composeEmail(
            to: ["\"a<b>\"@example.net"], subject: "s", body: "b")
        XCTAssertTrue(r.hasPrefix("Email sent successfully"))
    }

    func testContainsUnquotedAngle_scanSemantics() {
        // #270 helper-level coverage (implementation driven by the boundary
        // tests above; these pin the scan semantics incl. escape edges).
        XCTAssertTrue(containsUnquotedAngle("<a@x"))
        XCTAssertTrue(containsUnquotedAngle("a@x>"))
        XCTAssertTrue(containsUnquotedAngle("x <a@b> <c@d>"))
        XCTAssertFalse(containsUnquotedAngle("plain@example.com"))
        XCTAssertFalse(containsUnquotedAngle("\"a<b\"@x"))
        XCTAssertFalse(containsUnquotedAngle("\"a<b>\"@x"))
        // Quoted-pair: the escaped quote does NOT close the quoted string, so
        // the following angle is still inside quotes.
        XCTAssertFalse(containsUnquotedAngle("\"a\\\"<b\"@x"))
        // Escaped backslash DOES close on the next quote — the angle after the
        // closing quote is unquoted.
        XCTAssertTrue(containsUnquotedAngle("\"a\\\\\"<b@x"))
        // #270 verify R1 (Codex): an unterminated quote is NOT an RFC 5322
        // quoted-string — angles inside it get no exemption. The old
        // assertion pinned the bypass (`"a<b@x` → false); flipped.
        XCTAssertTrue(containsUnquotedAngle("\"a<b@x"))
        // #265 regression case: unterminated quote + PAIRED angles — the old
        // paired-contains guard rejected this; the R1 scan must too.
        XCTAssertTrue(containsUnquotedAngle("\"a<b>@x"))
        XCTAssertTrue(containsUnquotedAngle("\"<a@x"))
        // A quoted-string cannot appear in the DOMAIN (after an unquoted @) —
        // quotes there are literal, so their angles are unquoted.
        XCTAssertTrue(containsUnquotedAngle("a@\"<x>\""))
        // Unterminated quote with NO angle inside stays exempt-neutral (no
        // angle to report; the atCount checks handle the rest).
        XCTAssertFalse(containsUnquotedAngle("\"a@x"))
        XCTAssertFalse(containsUnquotedAngle(""))
        // #270 verify R2 (Codex): an ESCAPED angle inside a still-open quote
        // must also be recorded — `\<` consumed by the escaped branch without
        // setting the flag re-opened the unterminated-quote bypass, including
        // the paired `"a\<b\>@x` shape the old #265 guard rejected.
        XCTAssertTrue(containsUnquotedAngle("\"a\\<b@example.net"))
        XCTAssertTrue(containsUnquotedAngle("\"a\\<b\\>@example.net"))
        // Properly CLOSED quote with escaped angles stays legal (closing
        // quote resets the record).
        XCTAssertFalse(containsUnquotedAngle("\"a\\<b\\>\"@example.net"))
    }

    func testValidation_untermQuoteEscapedAngles_rejectedAtBoundary() async throws {
        // #270 verify R2 (Codex): boundary-level lock for the escaped-angle
        // unterminated-quote bypass.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            ineligibility: nil)
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["\"a\\<b\\>@example.net"], subject: "s", body: "b"))
    }

    func testValidation_untermQuotePairedAngles_rejectedAtBoundary() async throws {
        // #270 verify R1 (Codex blocking): `"a<b>@x` — old #265 guard rejected
        // (contains < and >); the R0 quote scan swallowed both angles into the
        // unterminated quote and passed it. Must reject at the boundary.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            ineligibility: nil)
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["\"a<b>@example.net"], subject: "s", body: "b"))
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["\"a<b@example.net"], subject: "s", body: "b"))
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["a@\"<example.net>\""], subject: "s", body: "b"))
    }

    // MARK: #280 — name != nil path also re-scans the extracted addr-spec

    func testParseRecipient_displayNameEmbeddedAngleInAddr_extractsRawAddr() {
        // parseRecipient extracts from the LAST `<` to the trailing `>`, so the
        // earlier `>` stays embedded in the addr-spec. The parser behavior is
        // unchanged (#280 is a VALIDATOR gap, not a parser one) — pin the trace.
        let r = parseRecipient("Name <a>b@x>")
        XCTAssertEqual(r.name, "Name")
        XCTAssertEqual(r.address, "a>b@x", "the earlier '>' survives inside the extracted addr-spec")
    }

    func testValidation_displayNameEmbeddedAngleInAddr_rejectedAtBoundary() async throws {
        // #280 (residual of #270): `Name <a>b@x>` DID parse a display name
        // (name != nil), so the #270 angle guard — gated on `name == nil` —
        // never ran, and the extracted addr `a>b@x` (single `@`) slipped through
        // atCount==1 with the stray `>` intact. The scan is now unconditional:
        // an extracted addr-spec that carries an unquoted angle is malformed
        // regardless of whether a display name parsed.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            ineligibility: nil)
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["Name <a>b@example.net>"], subject: "s", body: "b"))
    }

    func testValidation_displayNameCleanAddr_stillPasses() async throws {
        // #280 over-reject guard: making the angle scan unconditional must NOT
        // reject the legitimate mailbox form — a display name over a clean
        // addr-spec (no unquoted angles) still passes to the legacy path.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email sent successfully" }, ineligibility: nil)
        let r = try await MailController.shared.composeEmail(
            to: ["王小明 <ming@example.com>"], subject: "s", body: "b")
        XCTAssertTrue(r.hasPrefix("Email sent successfully"))
    }

    func testValidation_displayNameQuotedAngleAddr_stillPasses() async throws {
        // #280 verify (test-adequacy lens): the quote-aware exemption reached
        // via the name != nil / parseRecipient-extracted-address branch. With
        // only one literal '<' in the raw string (the wrapper's own), the
        // parser extracts name="王小明", addr=`"a>b"@example.net` — a legal
        // quoted local-part whose '>' sits INSIDE the quotes. The unconditional
        // scan must stay quote-aware on this branch too; without this test a
        // refactor scoping the quote-state machine per branch could silently
        // over-reject legitimate quoted-local-part display-name recipients.
        // (The mirror shape `Name <"a<b"@x>` is NOT reachable here: its inner
        // '<' becomes the lastIndex split point, collapsing to the name==nil
        // path already covered by the #270 tests.)
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email sent successfully" }, ineligibility: nil)
        let r = try await MailController.shared.composeEmail(
            to: ["王小明 <\"a>b\"@example.net>"], subject: "s", body: "b")
        XCTAssertTrue(r.hasPrefix("Email sent successfully"))
    }

    func testValidation_quotedNameQuotedAngleLeadingAddr_failsLoud() async throws {
        // #280 verify (over-reject lens) — DELIBERATE behavior pin, not a bug
        // lock. `"Foo" <"<a>"@x>` is a legal RFC 5322 mailbox, but a
        // pre-existing parseRecipient defect (lastIndex-of-'<' split; the
        // quoted local-part STARTS with '<' so the split lands inside it)
        // garbles the extraction to name=`Foo" <`, addr=`a>"@x` — losing the
        // local-part's leading `"<`. The OLD gated scan silently ACCEPTED the
        // garbled addr and would have composed to the wrong address; the
        // unconditional scan rejects it loudly (fail loud, no mis-send). This
        // pins the reject until the parser split bug is fixed — at which point
        // the addr extracts cleanly as `"<a>"@x`, the quote-aware scan exempts
        // it, and this test should flip to a pass expectation (#286).
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            ineligibility: nil)
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["\"Foo\" <\"<a>\"@x.example>"], subject: "s", body: "b"))
    }

    func testContainsUnquotedAngle_graphemeMaskedAngle_stillDetected() {
        // #280 verify (Codex, cross-model): `>` followed by U+FE0F (variation
        // selector) fuses into ONE extended grapheme cluster under Swift
        // Character iteration — the cluster != ">" so a Character-level scan
        // missed it (pre-existing since #270, both paths). The scan now walks
        // unicodeScalars, where U+003E is seen on its own regardless of any
        // combining scalar that follows.
        XCTAssertTrue(containsUnquotedAngle("a>\u{FE0F}b@x"))
        XCTAssertTrue(containsUnquotedAngle("<\u{FE0F}a@x"))
        // Combining scalars elsewhere must not confuse the structural scan.
        XCTAssertFalse(containsUnquotedAngle("cafe\u{301}@example.net"))
        XCTAssertFalse(containsUnquotedAngle("\"a<\u{FE0F}b\"@x"),
                       "angle inside a properly closed quote stays exempt, with or without a trailing combining scalar")
    }

    func testValidation_graphemeMaskedAngle_rejectedAtBoundary() async throws {
        // #280 verify (Codex): boundary lock for the scalar-level scan — the
        // masked stray '>' must reject, not land in the AppleScript address.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            ineligibility: nil)
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["Name <a>\u{FE0F}b@example.net>"], subject: "s", body: "b"))
    }

    func testValidation_cfwsCommentAngle_deliberatelyRejected() async throws {
        // #280 verify (Codex) — DELIBERATE lite-validator boundary pin. RFC
        // 5322 grammar permits a CFWS comment after the domain dot-atom, and
        // ctext may contain '>' — so `Name <user@example.net(>)>` is
        // grammar-legal. The lite validator has NEVER supported CFWS comments
        // (a comment carrying '@' always failed atCount; the BARE form
        // `user@example.net(>)` has been rejected by the #270 scan since it
        // shipped). The unconditional scan makes the display-name variant
        // consistent with that bare-path precedent instead of silently
        // exempting it. Comment-aware scanning is full-parser territory —
        // out of lite-validator scope (#270 diagnosis Residue).
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            ineligibility: nil)
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["Name <user@example.net(>)>"], subject: "s", body: "b"))
    }

    // MARK: #266 — RFC 5322 quoted-pair decoding inside quoted display names

    func testParseRecipient_quotedPair_quoteDecoded() {
        // Quoted-string whose value is a single `"`: source form `"\""`.
        // After stripping outer quotes the inner `\"` must decode to `"`,
        // not survive as backslash+quote.
        let r = parseRecipient("\"\\\"\" <q@x.co>")
        XCTAssertEqual(r.name, "\"", "quoted-pair \\\" must decode to a bare quote")
        XCTAssertEqual(r.address, "q@x.co")
    }

    func testParseRecipient_quotedPair_backslashDecoded() {
        // Quoted-string `"a\\b"` (escaped backslash) → value `a\b`.
        let r = parseRecipient("\"a\\\\b\" <q@x.co>")
        XCTAssertEqual(r.name, "a\\b", "quoted-pair \\\\ must decode to a single backslash")
        XCTAssertEqual(r.address, "q@x.co")
    }

    // #266 verify (Codex/DA): lock the highest-risk point — the decoded name
    // fed through appleScriptEscape — at the byte level, not just parseRecipient.
    // appleScriptEscape doubles `\` FIRST then escapes `"`, so a decoded lone
    // backslash is always re-doubled before any following quote: balanced literal.
    func testRecipientFragment_quotedPairDecoded_escapedToBalancedLiteral() {
        let quote = recipientFragment(["\"\\\"\" <q@x.co>"], kind: "to")
        XCTAssertTrue(quote.contains("name:\"\\\"\""),
                      "decoded bare quote must appear as the escaped literal name:\"\\\"\": \(quote)")
        let backslash = recipientFragment(["\"a\\\\b\" <q@x.co>"], kind: "to")
        XCTAssertTrue(backslash.contains("name:\"a\\\\b\""),
                      "decoded a\\b must re-escape to name:\"a\\\\b\": \(backslash)")
        let loneBackslash = recipientFragment(["\"\\\\\" <q@x.co>"], kind: "to")
        XCTAssertTrue(loneBackslash.contains("name:\"\\\\\""),
                      "decoded lone backslash must re-double to name:\"\\\\\": \(loneBackslash)")
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
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
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
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, ineligibility: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Draft created successfully" },
            ineligibility: nil)
        // Previously atCount==2 rejected this legal RFC 5322 mailbox outright.
        let result = try await MailController.shared.createDraft(
            to: ["ming@lab <ming@example.com>"], subject: "s", body: "b")
        XCTAssertTrue(result.hasPrefix("Draft created successfully"))
    }
}
