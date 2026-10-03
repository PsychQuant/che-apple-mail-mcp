import XCTest
@testable import CheAppleMailMCP

/// #465 — task 3.4 (detailed shaping, sensitivity notice, optional redaction)
/// plus the exact field set of brief events.
final class DetailedOutputTests: XCTestCase {

    private func run(_ lines: [Data], _ query: MailLogQuery) -> [String: Any] {
        MailLogService(source: FakeLogSource(lines: lines), timeZone: Synthetic.taipei).run(query)
    }

    func testBriefEventHasExactlyTheDocumentedFields() {
        let r = run([Synthetic.line(offset: 0, activity: 9545744)], Synthetic.query())
        let event = Synthetic.results(r)[0]
        XCTAssertEqual(Set(event.keys), ["time", "subsystem", "category", "event", "kind", "args", "activity", "account"])
        XCTAssertEqual(event["event"] as? String, "%@ Received %lu new local message actions")
        XCTAssertEqual(event["kind"] as? String, "structured")
        XCTAssertEqual(event["args"] as? [Int], [1])
        XCTAssertEqual(event["activity"] as? Int, 9545744)
        XCTAssertEqual(event["account"] as? String, "A")
        XCTAssertEqual(r["contains_sensitive"] as? Bool, false)
    }

    func testBriefNullArgumentIsEncodedAsNull() {
        let r = run([Synthetic.line(offset: 0, category: "EDLocalActionPersistence",
                                    format: "Created %{public}@ action %lld for %lu messages",
                                    message: "Created append action 11198 for <private> messages")], Synthetic.query())
        let args = Synthetic.results(r)[0]["args"] as? [Any]
        XCTAssertEqual(args?.count, 2)
        XCTAssertEqual(args?[0] as? Int, 11198)
        XCTAssertTrue(args?[1] is NSNull)
    }

    func testUploadReceiptIsKnownAndCarriesNoContent() {
        let r = run([Synthetic.line(offset: 0, category: "IMAPConnection", format: "%{public}@",
                                    message: "[Fixture.Server] <connection id:[Mailbox name=Fixture]> Read: 7 OK [APPENDUID (\n    1695,\n    902\n)]")], Synthetic.query())
        let event = Synthetic.results(r)[0]
        XCTAssertEqual(event["kind"] as? String, "known")
        XCTAssertEqual(event["event"] as? String, "imap.append_uid_received")
        XCTAssertEqual((event["args"] as? [Any])?.count, 0)
        let json = Synthetic.serialized(r)
        XCTAssertFalse(json.contains("1695"), "no part of the receipt text may appear in brief output")
        XCTAssertFalse(json.contains("Append completed"))
    }

    func testAccountsAreAliasedPerResponseAndCounted() {
        let lines = [
            Synthetic.line(offset: 0, message: "[first@example.invalid - Inbox] <Sync> Received 1 new local message actions"),
            Synthetic.line(offset: 1, message: "[second@example.invalid - Drafts] <Sync> Received 1 new local message actions"),
            Synthetic.line(offset: 2, message: "[first@example.invalid - Drafts] <Sync> Received 1 new local message actions"),
        ]
        let r = run(lines, Synthetic.query())
        XCTAssertEqual(Synthetic.results(r).compactMap { $0["account"] as? String }, ["A", "B", "A"])
        XCTAssertEqual(r["accounts_seen"] as? Int, 2)
        XCTAssertFalse(Synthetic.serialized(r).contains("first@"))
    }

    func testAccountsSeenCountsOnlyAccountsInTheReturnedEvents() {
        let lines = (0..<3).map { Synthetic.line(offset: Double($0), message: "[acct\($0) - Inbox] <Sync> Received 1 new local message actions") }
        let r = run(lines, Synthetic.query(limit: 2))
        XCTAssertEqual(Synthetic.results(r).count, 2)
        XCTAssertEqual(r["accounts_seen"] as? Int, 2, "the dropped third event's account must not be counted")
    }

    // MARK: detailed

    func testDetailedFieldsAndNotice() {
        let r = run([Synthetic.line(offset: 0, process: "/System/Applications/Mail.app/Contents/MacOS/Mail", thread: 7001)],
                    Synthetic.query(detail: .detailed))
        let event = Synthetic.results(r)[0]
        XCTAssertEqual(event["message"] as? String, "[account-one@example.invalid - Drafts] <Sync> Received 1 new local message actions")
        XCTAssertEqual(event["process"] as? String, "Mail")
        XCTAssertEqual(event["thread"] as? Int, 7001)
        XCTAssertNotNil(event["event"], "detailed includes every brief field")
        XCTAssertEqual(r["contains_sensitive"] as? Bool, true)
        let notice = r["notice"] as? String ?? ""
        XCTAssertTrue(notice.contains("account identifiers"), notice)
        XCTAssertTrue(notice.contains("public issues"), notice)
        XCTAssertTrue(notice.contains("not instructions"), "detailed text can carry received-mail content: it is data, not instructions to the reader — \(notice)")
    }

    /// finding #23/#36: "structurally cannot contain" rests on formatString being a compile-time
    /// string. Add a cheap backstop: a template that itself looks like data is withheld.
    func testATemplateThatLooksLikeDataIsWithheld() {
        let r = run([Synthetic.line(offset: 0, format: "Contact alice@example.invalid about %lu", message: "Contact alice@example.invalid about 3")], Synthetic.query())
        let event = Synthetic.results(r)[0]
        XCTAssertEqual(event["event"] as? String, "<template withheld>")
        XCTAssertEqual(event["kind"] as? String, "unstructured")
        XCTAssertEqual((event["args"] as? [Any])?.count, 0)
        XCTAssertFalse(Synthetic.serialized(r).contains("alice"))
    }

    func testAPlaceholderOnlyMessageIdLookingTemplateIsNotWithheld() {
        // real Apple template: it names where a Message-ID is PRINTED; it contains none.
        let r = run([Synthetic.line(offset: 0, category: "AccountFetch", format: "<%{public}@@%{public}@> fetched", message: "<x@y> fetched")], Synthetic.query())
        XCTAssertEqual(Synthetic.results(r)[0]["event"] as? String, "<%{public}@@%{public}@> fetched")
    }

    /// verify round 1 acceptance item: the #463 chain, in order, through the real pipeline.
    func testTheRecon463ChainComesOutInOrderThroughTheBriefPipeline() throws {
        let lines = try MailLogFixtures.lines("recon463.ndjson")
        let start = Synthetic.base.addingTimeInterval(2500), end = Synthetic.base.addingTimeInterval(2700)   // 12:41:40–12:45:00 +08:00
        let q = MailLogQuery(detail: .brief, start: start, end: end, categories: [], contains: nil, redactIdentifiers: false, limit: 200)
        let r = MailLogService(source: FakeLogSource(lines: lines), timeZone: Synthetic.taipei).run(q)
        let events = Synthetic.results(r)
        func index(_ pred: ([String: Any]) -> Bool) -> Int? { events.firstIndex(where: pred) }
        let created = index { ($0["event"] as? String ?? "").hasPrefix("Created %{public}@ action") }
        let processing = index { ($0["event"] as? String ?? "").hasPrefix("_transferActionForRow") }
        let notified = index { ($0["event"] as? String ?? "").contains("new local message actions") }
        let receipt = index { $0["kind"] as? String == "known" }
        XCTAssertNotNil(created); XCTAssertNotNil(processing); XCTAssertNotNil(notified); XCTAssertNotNil(receipt)
        XCTAssertTrue(created! < processing! && processing! < notified! && notified! < receipt!, "save → queue → engine notified → upload receipt")
        XCTAssertEqual(events[receipt!]["event"] as? String, "imap.append_uid_received")
        XCTAssertEqual(events[created!]["args"] as? [Int], [11198, 1, 0, 1, 0])
    }

    func testDetailedWithNoEventsStillFlagsSensitivity() {
        let r = run([], Synthetic.query(detail: .detailed))
        XCTAssertEqual(r["contains_sensitive"] as? Bool, true)
        let notice = r["notice"] as? String ?? ""
        XCTAssertTrue(notice.contains("absence of log lines"))
    }

    func testRedactionAppliedAndDeclaredBestEffort() {
        let msg = "from alice.fixture@example.invalid and again alice.fixture@example.invalid id 7F3A9C52-1B4E-4C8D-9A21-0E5D6F7A8B9C"
        let r = run([Synthetic.line(offset: 0, message: msg)], Synthetic.query(detail: .detailed, redact: true))
        XCTAssertEqual(Synthetic.results(r)[0]["message"] as? String, "from <email-1> and again <email-1> id <uuid-1>")
        let redaction = r["redaction"] as? [String: Any]
        XCTAssertEqual(redaction?["applied"] as? Bool, true)
        XCTAssertEqual(redaction?["patterns"] as? [String], ["email", "uuid", "message-id"])
        XCTAssertTrue((redaction?["note"] as? String ?? "").contains("best-effort"))
        XCTAssertTrue((redaction?["note"] as? String ?? "").contains("not a privacy guarantee"))
    }

    func testRedactionOffByDefault() {
        let msg = "from alice.fixture@example.invalid"
        let r = run([Synthetic.line(offset: 0, message: msg)], Synthetic.query(detail: .detailed))
        XCTAssertEqual(Synthetic.results(r)[0]["message"] as? String, msg)
        XCTAssertNil(r["redaction"])
    }

    /// The cut never ends inside a token: with words it ends at the last whitespace before 8,192 bytes; an
    /// unbroken token that crosses the cap is dropped whole (round 5, findings 1/5/8/16 — the round-4 rule gave
    /// up after 1,024 bytes and returned the start of the token).
    func testVeryLongMessageIsTruncatedAndFlagged() {
        let words = String(repeating: "word ", count: 4000)                 // 20,000 bytes
        let w = Synthetic.results(run([Synthetic.line(offset: 0, message: words)], Synthetic.query(detail: .detailed)))[0]
        XCTAssertEqual((w["message"] as? String)?.utf8.count, 8190, "1,638 whole words: the cut ends at a whitespace")
        XCTAssertEqual(w["message_truncated"] as? Bool, true)
        let token = Synthetic.results(run([Synthetic.line(offset: 0, message: String(repeating: "m", count: 20_000))], Synthetic.query(detail: .detailed)))[0]
        XCTAssertEqual(token["message"] as? String, "", "no safe cut point: nothing of the token is returned")
        XCTAssertEqual(token["message_truncated"] as? Bool, true)
    }

    func testShortMessageHasNoTruncationFlag() {
        let r = run([Synthetic.line(offset: 0)], Synthetic.query(detail: .detailed))
        XCTAssertNil(Synthetic.results(r)[0]["message_truncated"])
    }

    /// Verify round 2, finding 24: with redaction on, `contains` still matched the raw text, so a
    /// caller could probe for exactly what the redaction hides ("alice@" → hit or miss).
    func testWithRedactionOn_containsSeesOnlyTheMaskedText() {
        let line = Synthetic.line(offset: 0, message: "sent by alice@example.invalid to the queue")
        func hits(_ needle: String, redact: Bool) -> Int {
            Synthetic.results(run([line], Synthetic.query(detail: .detailed, contains: needle, redact: redact))).count
        }
        XCTAssertEqual(hits("alice", redact: false), 1)
        XCTAssertEqual(hits("alice", redact: true), 0, "the hidden address must not be probeable")
        XCTAssertEqual(hits("<email>", redact: true), 1, "the masked form is what can be searched")
        XCTAssertEqual(hits("queue", redact: true), 1)
    }

    /// Verify round 3, findings 13/17: `contains` matched the whole message although only its first
    /// 8,192 bytes are returned — an oracle on text the caller never sees — and truncating BEFORE
    /// masking could cut an address in half and leave the half unmasked.
    func testContainsSeesOnlyTheReturnedTextAndABoundaryAddressStaysMasked() {
        let beyond = Synthetic.line(offset: 0, message: String(repeating: "x", count: 9000) + " needle")
        XCTAssertEqual(Synthetic.results(run([beyond], Synthetic.query(detail: .detailed, contains: "needle"))).count, 0)
        let straddling = Synthetic.line(offset: 0, message: String(repeating: "y", count: 8180) + " alice@example.invalid end")
        let r = run([straddling], Synthetic.query(detail: .detailed, redact: true))
        let message = Synthetic.results(r).first?["message"] as? String ?? ""
        XCTAssertFalse(message.contains("alice"), "no fragment of the masked address may survive the cut")
    }

    /// Verify round 3, findings 15/18: brief mode parsed messages of any size (the reader allows 4 MiB
    /// lines). The longest real message measured is 32,803 bytes; anything over 64 KiB is not parsed.
    func testAnOversizedMessageIsNotParsedInBrief() {
        let huge = "[acct - box] Received " + String(repeating: "1", count: 100_000) + " new local message actions"
        // (100,000 bytes is over every bound; the bounds themselves are pinned in testBriefParsingIsBoundedInEveryDimension)
        let t0 = Date()
        let r = run([Synthetic.line(offset: 0, message: huge)], Synthetic.query())
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
        XCTAssertEqual(Synthetic.results(r).first?["kind"] as? String, "unstructured")
    }

    /// Verify round 4, findings 1/3/5/6/9: the filter masked with `<email>` and cut at 8,192 bytes;
    /// the response masked with the longer `<email-N>` and cut again — two different spans, so the
    /// filter could match text that was not returned. Both now come from ONE span of the original.
    func testTheFilterAndTheReturnedTextCoverTheSameSpan() {
        // Five 18-byte addresses mask to 7 bytes un-numbered and 9 bytes numbered: the two cuts used to sit
        // 10 bytes apart, so a needle inside that gap matched without being returned (filler 8136–8145).
        for filler in 8120...8200 {
            let message = (0..<5).map { "u\($0)@example.invalid" }.joined(separator: " ") + " "
                + String(repeating: "x", count: filler) + " needle tail"
            let line = Synthetic.line(offset: 0, message: message)
            let shown = Synthetic.results(run([line], Synthetic.query(detail: .detailed, redact: true))).first?["message"] as? String ?? ""
            let hit = !Synthetic.results(run([line], Synthetic.query(detail: .detailed, contains: "needle", redact: true))).isEmpty
            XCTAssertEqual(hit, shown.contains("needle"), "filler \(filler): the filter must see exactly the returned text")
        }
    }

    /// Verify round 4, findings 2/4/12: masking ran on a 16,384-byte prefix that could itself end inside an
    /// address; when masking shrank the text, the fragment landed in the returned part unmasked. The cut is
    /// now made on the original, before masking, and never ends inside a token.
    func testACutNeverLeavesAnUnmaskedFragment() {
        // Both boundaries: the returned cut (8,192) and the old 16,384-byte working cut. Long addresses mask to
        // short placeholders, so the text after masking is far shorter than the original before the cut.
        for (count, boundary) in [(140, 8192), (290, 16_384)] {
            let head = (0..<count).map { "someone.with.a.very.long.local.part.\($0)@example.invalid" }.joined(separator: " ") + " "
            for straddle in 1..<12 {
                let pad = boundary - head.utf8.count - straddle
                guard pad > 0 else { continue }
                let message = head + String(repeating: "z", count: pad) + " alice@example.invalid trailing words"
                let shown = Synthetic.results(run([Synthetic.line(offset: 0, message: message)], Synthetic.query(detail: .detailed, redact: true)))
                    .first?["message"] as? String ?? ""
                XCTAssertFalse(shown.contains("alic"), "boundary \(boundary), straddle \(straddle): no piece of an address may come back")
            }
        }
    }

    /// Verify round 4, finding 17: identifiers past the returned span took mask numbers, so a gap in the
    /// numbering of a later event revealed that hidden text held an identifier.
    func testMaskNumbersCountOnlyTheReturnedSpan() {
        let first = Synthetic.line(offset: 0, message: "a@example.invalid " + String(repeating: "x", count: 9000) + " hidden@example.invalid")
        let second = Synthetic.line(offset: 1, message: "b@example.invalid arrived")
        let results = Synthetic.results(run([first, second], Synthetic.query(detail: .detailed, redact: true)))
        XCTAssertEqual(results.last?["message"] as? String, "<email-2> arrived")
    }

    /// Verify round 4, findings 7/13/18: subsystem and process were unbounded, and the worst case across
    /// fields was never shown to fit. Every text field is capped, and if one event still does not fit, its
    /// message is shortened rather than the response exceeding the cap.
    func testTheWorstCaseAcrossEveryFieldStillFitsTheCap() throws {
        let object: [String: Any] = [
            "timestamp": "2026-10-02 12:00:00.000000+0800", "subsystem": "com.apple.mail" + String(repeating: "s", count: 4000),
            "category": String(repeating: "\u{02}", count: 120),
            "formatString": String(repeating: "\u{03}", count: 1000) + String(repeating: " %lu", count: 6),
            "eventMessage": String(repeating: "\u{01}", count: 20_000), "processImagePath": "/x/" + String(repeating: "p", count: 4000),
            "threadID": 1, "activityIdentifier": 1,
        ]
        let line = try JSONSerialization.data(withJSONObject: object)
        let r = run([line], Synthetic.query(detail: .detailed))
        XCTAssertLessThanOrEqual(Synthetic.serialized(r).utf8.count, MailLogService.responseByteCap)
        XCTAssertEqual(Synthetic.results(r).count, 1)
        let event = Synthetic.results(r)[0]
        XCTAssertEqual(event["subsystem"] as? String, "<subsystem withheld>")
        XCTAssertEqual(event["process"] as? String, "<process withheld>")
        let dense = Synthetic.line(offset: 0, message: String(repeating: "<a@b> ", count: 1400))
        // Round 7, finding 5: masks that lengthen the text, mixed with characters that escape to six bytes.
        let mixed = Synthetic.line(offset: 0, message: String(repeating: "<a@b>\u{01}\u{01} ", count: 1000))
        XCTAssertLessThanOrEqual(Synthetic.serialized(run([mixed], Synthetic.query(detail: .detailed, redact: true))).utf8.count, 61_440)
        XCTAssertLessThanOrEqual(Synthetic.serialized(run([dense], Synthetic.query(detail: .detailed, redact: true))).utf8.count,
                                 MailLogService.responseByteCap)
    }

    /// Verify round 4, finding 8: the withholding rules were exercised only for size, never for their value.
    func testBriefWithholdsAnOverlongCategoryAndTemplate() {
        let r = run([Synthetic.line(offset: 0, category: String(repeating: "c", count: 129), format: String(repeating: "t", count: 1025))],
                    Synthetic.query())
        let event = Synthetic.results(r).first
        XCTAssertEqual(event?["category"] as? String, "<category withheld>")
        XCTAssertEqual(event?["event"] as? String, "<template withheld>")
    }

    /// Verify round 4, findings 14/19 (bound raised back to 64 KiB in round 5, finding 23): brief parsing is bounded by bytes, by placeholder count, and the
    /// account bracket is read only from the start of the message.
    func testBriefParsingIsBoundedInEveryDimension() {
        let big = Synthetic.line(offset: 0, message: "[acct - box] Received " + String(repeating: "1", count: 70_000) + " new local message actions")
        XCTAssertEqual(Synthetic.results(run([big], Synthetic.query())).first?["kind"] as? String, "unstructured", "over 64 KiB")
        let manyPlaceholders = String(repeating: "%lu ", count: 70) + "done"
        let many = Synthetic.line(offset: 0, format: manyPlaceholders, message: String(repeating: "1 ", count: 70) + "done")
        XCTAssertEqual(Synthetic.results(run([many], Synthetic.query())).first?["kind"] as? String, "unstructured", "over 64 placeholders")
        let lateBracket = Synthetic.line(offset: 0, message: "[acct - " + String(repeating: "x", count: 2000) + "] Received 1 new local message actions")
        XCTAssertTrue(Synthetic.results(run([lateBracket], Synthetic.query())).first?["account"] is NSNull, "the bracket must close within 1 KiB")
    }

    /// Round 5: identifiers inside a long run with no whitespace — comma-separated addresses, an over-long
    /// local part, a long Message-ID — must not leave a fragment either. Safe cut points are whitespace, just
    /// before `<` and just after `>`: none of the three identifier shapes can span one of them.
    func testNoFragmentEvenInsideALongRunWithoutWhitespace() {
        let cases = [
            " " + (0..<600).map { "user\($0)@example.invalid" }.joined(separator: ","),
            " " + String(repeating: "a", count: 9000) + "@example.invalid trailing",
            "start <" + String(repeating: "m", count: 9000) + "@example.invalid> after",
            "x <a@b.example> " + String(repeating: "q", count: 8000) + "<late@host.example>more",
        ]
        let expected = [
            " ",                                                   // the whole comma-separated run crosses the cap: dropped
            " ",                                                   // one 9,000-byte local part: dropped
            "start ",                                              // cut just before the `<` of the long Message-ID
            "x <message-id-1> " + String(repeating: "q", count: 8000) + "<message-id-2>more",   // fits: nothing cut
        ]
        for (i, message) in cases.enumerated() {
            let shown = Synthetic.results(run([Synthetic.line(offset: 0, message: message)], Synthetic.query(detail: .detailed, redact: true)))
                .first?["message"] as? String
            XCTAssertEqual(shown, expected[i], "case \(i)")
        }
        // The property the cut relies on: no match of the three shapes contains a cut-point character inside it —
        // whitespace (including VT, NEL and other `\s` members), `<` after its first character, `>` before its last.
        let uuid = #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#
        for pattern in [IdentifierRedactor.emailPattern, #"<[^<>\s@]+@[^<>\s]+>"#, uuid] {
            let r = try! NSRegularExpression(pattern: pattern)
            for ws in [" ", "\t", "\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{A0}", "\u{2028}", "\u{3000}"] {
                for sample in ["a\(ws)b@c.example", "<a\(ws)b@c>", "a<b@c.example", "<a@b>c@d.example>", "123e4567-e89b\(ws)12d3-a456-426614174000"] {
                    for m in r.matches(in: sample, range: NSRange(sample.startIndex..., in: sample)) {
                        let hit = (sample as NSString).substring(with: m.range)
                        XCTAssertFalse(hit.contains(ws), "\(pattern) matched across \(ws.debugDescription) in \(sample.debugDescription)")
                        XCTAssertFalse(hit.dropFirst().contains("<") || hit.dropLast().contains(">"), "\(pattern): \(hit.debugDescription)")
                    }
                }
            }
        }
    }

    /// Round 5, findings 4/12/13/15/17/20/21: the message-shortening fallback was unreachable and, had it run,
    /// would have let `contains` match withheld text. It is gone; the per-field caps alone keep one event under
    /// the cap. This builds the worst case for EVERY field at once — a fully escaped 8,192-byte message, a
    /// 1,022-byte template of control characters with 64 integer slots of 20 digits, and 128 escaped bytes
    /// each of subsystem, category and process — in both details.
    func testTheWorstCaseForEveryFieldAtOnceFitsWithoutShortening() throws {
        let control = "\u{01}"
        let template = String(repeating: control, count: 700) + "%@" + String(repeating: " %lld", count: 63)      // 64 placeholders
        let message = String(repeating: control, count: 8191) + " " + String(repeating: " -9223372036854775807", count: 63)
        let object: [String: Any] = [
            "timestamp": "2026-10-02 12:00:00.000000+0800", "subsystem": "com.apple.mail" + String(repeating: control, count: 114),
            "category": String(repeating: control, count: 128), "formatString": template, "eventMessage": message,
            "processImagePath": "/x/" + String(repeating: control, count: 128), "threadID": Int.max, "activityIdentifier": Int.max,
        ]
        let line = try JSONSerialization.data(withJSONObject: object)
        for query in [Synthetic.query(detail: .detailed), Synthetic.query(detail: .detailed, redact: true), Synthetic.query()] {
            let r = run([line], query)
            let bytes = Synthetic.serialized(r).utf8.count
            // The spec states this number (round 6, finding 9): one event never serializes past 61,440 bytes.
            XCTAssertLessThanOrEqual(bytes, 61_440, "\(query.detail) redact=\(query.redactIdentifiers): \(bytes) bytes")
            let event = Synthetic.results(r).first
            XCTAssertEqual((event?["args"] as? [Any])?.count, 63)
            if query.detail == .detailed {
                XCTAssertEqual((event?["message"] as? String)?.utf8.count, 8192, "the message is the full cut span, not shortened")
            }
        }
    }

    /// Verify round 6, findings 1/17: each safe cut point has a case that fails without its rule — `<` just past
    /// the cap (the prefix itself is then safe), `<` right after non-whitespace, `>` right before a long token —
    /// and U+200B, which `CharacterSet` calls whitespace but the Message-ID pattern's `\s` does not (measured).
    func testEachSafeCutPointIsNeeded() {
        func shown(_ message: String) -> String? {
            Synthetic.results(run([Synthetic.line(offset: 0, message: message)], Synthetic.query(detail: .detailed, redact: true)))
                .first?["message"] as? String
        }
        let q = String(repeating: "q", count: 8186)
        XCTAssertEqual(shown("start " + q + "<a@b.example>" + String(repeating: "z", count: 100)), "start " + q,
                       "`<` is the next character after the cap: the whole prefix is a safe cut")
        let q7 = String(repeating: "q", count: 7000)
        XCTAssertEqual(shown("x " + q7 + "<" + String(repeating: "m", count: 3000) + "@host.example>"), "x " + q7,
                       "cut just before `<`, not back at the earlier space")
        let q1 = String(repeating: "q", count: 100)
        XCTAssertEqual(shown("x " + q1 + "<a@b.example>" + String(repeating: "r", count: 9000)), "x " + q1 + "<message-id-1>",
                       "cut just after `>`")
        XCTAssertEqual(shown("x <abc\u{200B}" + String(repeating: "m", count: 9000) + "@host.example>"), "x ",
                       "U+200B can sit inside a Message-ID, so it is not a cut point")
        // Round 7, finding 2: whitespace right AFTER the cap makes the whole prefix a safe cut.
        let q8 = String(repeating: "q", count: 8190)
        XCTAssertEqual(shown("x " + q8 + " tail words"), "x " + q8, "the character after the cap is whitespace")
    }

    /// Verify round 6, finding 8: the parse bound holds in either detail, at its exact edge.
    func testTheParseBoundHoldsInEitherDetailAtItsEdge() {
        let tail = "] Received 1 new local message actions"
        func line(bytes: Int) -> Data {
            let pad = bytes - "[acct - ".utf8.count - tail.utf8.count
            return Synthetic.line(offset: 0, message: "[acct - " + String(repeating: "x", count: pad) + tail)
        }
        for query in [Synthetic.query(), Synthetic.query(detail: .detailed)] {
            XCTAssertEqual(Synthetic.results(run([line(bytes: 65_536)], query)).first?["kind"] as? String, "structured", "\(query.detail) at the bound")
            XCTAssertEqual(Synthetic.results(run([line(bytes: 65_537)], query)).first?["kind"] as? String, "unstructured", "\(query.detail) past it")
        }
    }
}
