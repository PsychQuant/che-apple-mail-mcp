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
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            refusal: { nil })
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
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            refusal: { nil })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["Alice <not-an-email> <bob@example.net>"], subject: "s", body: "b"))
    }

    func testValidation_bareAngleTrailingText_rejectedAtBoundary() async throws {
        // `<bob@x> extra` has no `>` suffix → (nil, whole); whole carries a
        // matched <...> pair → malformed, reject.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            refusal: { nil })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["<bob@example.net> extra"], subject: "s", body: "b"))
    }

    func testValidation_legitBareAndBareAngle_stillPass() async throws {
        // Guard against the #265 rejection over-firing: a clean bare addr-spec
        // (no angles) and a bare-angle form (normalized to the inner addr-spec,
        // angles stripped) must both still pass — neither carries a matched
        // <...> pair after parseRecipient.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email sent successfully" }, refusal: { nil })
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
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            refusal: { nil })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["<a@example.net"], subject: "s", body: "b"))
    }

    func testValidation_unpairedTrailingAngle_rejectedAtBoundary() async throws {
        // #270: `a@x>` — has `>` suffix but no `<` → (nil, "a@x>") with the
        // stray `>` kept; same single-bracket bypass as above.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            refusal: { nil })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["a@example.net>"], subject: "s", body: "b"))
    }

    func testValidation_quotedLocalPartAngle_stillPasses() async throws {
        // #270 over-reject guard: `"a<b"@x` is a legal RFC 5322 quoted
        // local-part — the angle lives INSIDE the quoted string and must not
        // trip the unquoted-angle scan (a naive contains-OR gate would).
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email sent successfully" }, refusal: { nil })
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
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email sent successfully" }, refusal: { nil })
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
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            refusal: { nil })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["\"a\\<b\\>@example.net"], subject: "s", body: "b"))
    }

    func testValidation_untermQuotePairedAngles_rejectedAtBoundary() async throws {
        // #270 verify R1 (Codex blocking): `"a<b>@x` — old #265 guard rejected
        // (contains < and >); the R0 quote scan swallowed both angles into the
        // unterminated quote and passed it. Must reject at the boundary.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            refusal: { nil })
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
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            refusal: { nil })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["Name <a>b@example.net>"], subject: "s", body: "b"))
    }

    func testValidation_displayNameCleanAddr_stillPasses() async throws {
        // #280 over-reject guard: making the angle scan unconditional must NOT
        // reject the legitimate mailbox form — a display name over a clean
        // addr-spec (no unquoted angles) still passes to the legacy path.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Draft created successfully" }, refusal: { nil })
        // #304: driven through create_draft — a display-name `to` rides the
        // clean path on drafts (#277). What is under test is the ADDRESS
        // PARSER, not the tool; compose_email now refuses display-name sends.
        let r = try await MailController.shared.createDraft(
            to: ["王小明 <ming@example.com>"], subject: "s", body: "b")
        XCTAssertTrue(r.hasPrefix("Draft created successfully"))
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
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Draft created successfully" }, refusal: { nil })
        let r = try await MailController.shared.createDraft(
            to: ["王小明 <\"a>b\"@example.net>"], subject: "s", body: "b")
        XCTAssertTrue(r.hasPrefix("Draft created successfully"))
    }

    func testValidation_quotedNameQuotedAngleLeadingAddr_nowLegal() async throws {
        // #286 FIX — flipped from the #280-era fail-loud pin. `"Foo" <"<a>"@x>`
        // is a legal RFC 5322 mailbox (quoted display name + quoted local-part
        // whose content is `<a>`). The old lastIndex-of-'<' split landed INSIDE
        // the quoted local-part and garbled the extraction (name=`Foo" <`,
        // addr=`a>"@x`); the quote-aware split now finds the real addr opener,
        // the extraction is clean, and the #280 quote-aware angle scan exempts
        // the quoted angles — so the mailbox composes normally.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Draft created successfully" }, refusal: { nil })
        let r = try await MailController.shared.createDraft(
            to: ["\"Foo\" <\"<a>\"@x.example>"], subject: "s", body: "b")
        XCTAssertTrue(r.hasPrefix("Draft created successfully"))
    }

    // MARK: #286 — quote-aware parseRecipient split

    func testParseRecipient_quotedLeadingAngleLocalPart_extractsCleanly() {
        // The defining #286 shape: quoted local-part STARTS with '<'. The split
        // must pick the addr opener (the last UNQUOTED '<'), not the '<'
        // inside the quoted string.
        let r = parseRecipient("\"Foo\" <\"<a>\"@x.example>")
        XCTAssertEqual(r.name, "Foo")
        XCTAssertEqual(r.address, "\"<a>\"@x.example")
    }

    func testParseRecipient_quotedNameWithAngles_splitUnchanged() {
        // Regression: quoted display name containing angles — the '<' inside
        // the NAME's quotes must not become the split point either.
        let r = parseRecipient("\"A <b>\" <c@d.e>")
        XCTAssertEqual(r.name, "A <b>")
        XCTAssertEqual(r.address, "c@d.e")
    }

    func testParseRecipient_untermQuoteBeforeAngle_treatedAsBare() {
        // #286 deliberate behavior change (fail-loud direction): `"Foo <a@x>`
        // has an UNTERMINATED quote, so its '<' is never unquoted — no split,
        // returns bare. (The old split extracted name=`"Foo`, an unbalanced-
        // quote name, and silently accepted it.) The bare form then rejects at
        // the validator: an unterminated quote holding angles gets no
        // exemption (#270 R1 scan semantics).
        let r = parseRecipient("\"Foo <a@x.example>")
        XCTAssertNil(r.name)
        XCTAssertEqual(r.address, "\"Foo <a@x.example>")
    }

    func testValidation_untermQuoteBeforeAngle_rejectedAtBoundary() async throws {
        // Boundary lock for the deliberate change above.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            refusal: { nil })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["\"Foo <a@x.example>"], subject: "s", body: "b"))
    }

    func testParseRecipient_unbalancedQuoteInComment_treatedAsBare_deliberate() {
        // #286 verify (Codex) — DELIBERATE boundary pin, not a fix. RFC 5322
        // permits `"` as ctext inside a CFWS comment, so `Name (") <a@x>` is
        // grammar-legal and the OLD split happened to accept it (the comment
        // passed through as literal display-name text). The lite parser does
        // NOT understand comments (#280 pinned that boundary for angles-in-
        // comments); a quote inside one reads as a quoted-string opener, and
        // an ODD number of quotes before '<' is exactly the unterminated-
        // quote class this issue already pins as bare→reject (fail-loud, no
        // mis-send). Comment-aware scanning stays full-parser territory. An
        // EVEN number of quotes inside comments still splits fine
        // (`Acme ("The Best") <s@a.com>` below).
        let r = parseRecipient("Name (\") <a@x.example>")
        XCTAssertNil(r.name)
        XCTAssertEqual(r.address, "Name (\") <a@x.example>")
        // Balanced quotes inside a comment stay unaffected.
        let ok = parseRecipient("Acme (\"The Best\") <sales@acme.example>")
        XCTAssertEqual(ok.name, "Acme (\"The Best\")")
        XCTAssertEqual(ok.address, "sales@acme.example")
    }

    func testParseRecipient_graphemeMaskedAngleOpener_treatedAsBare() {
        // '<' fused with U+FE0F is one grapheme cluster != "<" — the
        // Character-level split treats it as literal text (no split), and the
        // whole string falls through to the validator whose SCALAR-level scan
        // (#280) rejects the masked angle. Fail-safe, pinned.
        let r = parseRecipient("a<\u{FE0F}b@x.example>")
        XCTAssertNil(r.name)
        XCTAssertEqual(r.address, "a<\u{FE0F}b@x.example>")
        XCTAssertTrue(containsUnquotedAngle(r.address), "validator scalar scan must catch the masked angle")
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
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            refusal: { nil })
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
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            refusal: { nil })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["Name <user@example.net(>)>"], subject: "s", body: "b"))
    }

    // MARK: #289 — atCount counts scalars, not grapheme clusters

    func testValidation_graphemeMaskedAt_rejectedAtBoundary() async throws {
        // #289 (sibling of #280's angle fix): `@` fused with U+FE0F is one
        // grapheme cluster != "@" under Character counting — `a@\u{FE0F}b@c`
        // counted atCount==1 and passed with the masked `@` intact. Scalar
        // counting sees both U+0040 scalars → atCount==2 → reject.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            refusal: { nil })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["a@\u{FE0F}b@example.net"], subject: "s", body: "b"))
    }

    func testValidation_graphemeMaskedLeadingAt_rejectedAtBoundary() async throws {
        // #289 verify (Codex): `@\u{FE0F}example.net` — the sole `@` is FIRST
        // and fused with U+FE0F. Old Character atCount rejected it by accident
        // (fusion → count 0); scalar atCount counts it (1), so the boundary
        // check must ALSO be scalar-level or the shape flips to accept with an
        // empty local part.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in XCTFail("must reject before any script"); return "" },
            refusal: { nil })
        await XCTAssertThrowsErrorAsync(
            try await MailController.shared.composeEmail(
                to: ["@\u{FE0F}example.net"], subject: "s", body: "b"))
    }

    func testValidation_trailingMaskDomain_acceptedAsMailLevelGarbage() async throws {
        // #289 documented residual: `user@\u{FE0F}` — the `@` scalar is non-
        // terminal (FE0F follows), so the FE0F-only domain passes the lite
        // boundary checks and lands as Mail-level-invalid garbage (benign, no
        // mis-send — same class as `a@-`). The OLD rejection here was an
        // accident of the grapheme-fusion bug itself; domain grammar
        // validation is out of lite-validator scope. Pinned deliberately.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email sent successfully" }, refusal: { nil })
        let r = try await MailController.shared.composeEmail(
            to: ["user@\u{FE0F}"], subject: "s", body: "b")
        XCTAssertTrue(r.hasPrefix("Email sent successfully"))
    }

    func testValidation_combiningScalarsElsewhere_stillPass() async throws {
        // Over-reject guard: combining scalars NOT adjacent to '@' must not
        // perturb the count — café (e + U+0301) has exactly one @ scalar.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Email sent successfully" }, refusal: { nil })
        let r = try await MailController.shared.composeEmail(
            to: ["cafe\u{301}@example.net"], subject: "s", body: "b")
        XCTAssertTrue(r.hasPrefix("Email sent successfully"))
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

    // MARK: pre-flight refusal dimension (#304 — was a routing dimension)

    func testRefusal_displayNameCcBcc_namedWithRecipe() {
        let refusal = composeRefusal(
            format: .plain, accessibilityTrusted: true,
            hasCustomSender: false, hasSubject: true,
            attachmentsGuiSafe: true,
            recipientsAddrSpecOnly: false)
        XCTAssertEqual(refusal, .displayNameRecipient)
        let message = refusal!.message
        XCTAssertTrue(message.contains("display name"), message)
        XCTAssertTrue(message.contains("RFC 6068"), message)
        XCTAssertTrue(message.contains("bare addresses"), "must state the recipe: \(message)")
    }

    func testRefusal_bareRecipients_proceed() {
        XCTAssertNil(composeRefusal(
            format: .plain, accessibilityTrusted: true,
            hasCustomSender: false, hasSubject: true,
            attachmentsGuiSafe: true,
            recipientsAddrSpecOnly: true))
    }

    // MARK: production site via the #254 seams

    func testComposeEmail_displayNameRecipient_refusesOnSend() async throws {
        // #304 CAPABILITY CHANGE, recorded deliberately: sending to
        // `Name <addr>` used to work by routing to the legacy builder, which
        // set the recipient's name natively — at the cost of the body being
        // wrapped in <blockquote type="cite">. The clean path has always
        // refused a display-name SEND (the GUI fill is draft-only, #277:
        // a fill that failed would dispatch with missing recipients), so with
        // the legacy builder gone the send now fails instead of degrading.
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        var scripts: [String] = []
        await MailController.shared.setTestSeams(
            scriptRunner: { script in scripts.append(script); return "Email sent successfully" },
            refusal: nil)   // real probe — the display-name recipient must trip it
        do {
            _ = try await MailController.shared.composeEmail(
                to: ["王小明 <ming@example.com>"], subject: "s", body: "b")
            XCTFail("a display-name recipient on a SEND must be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("display name"), "\(error)")
            XCTAssertTrue("\(error)".contains("create_draft"),
                          "the refusal must point at the path that still supports it: \(error)")
        }
        XCTAssertTrue(scripts.isEmpty, "nothing may be sent: \(scripts.count) script(s) ran")
    }

    func testValidation_nameWithAt_noLongerMisRejected() async throws {
        addTeardownBlock { await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil) }
        await MailController.shared.setTestSeams(
            scriptRunner: { _ in "Draft created successfully" },
            refusal: { nil })
        // Previously atCount==2 rejected this legal RFC 5322 mailbox outright.
        let result = try await MailController.shared.createDraft(
            to: ["ming@lab <ming@example.com>"], subject: "s", body: "b")
        XCTAssertTrue(result.hasPrefix("Draft created successfully"))
    }
}
