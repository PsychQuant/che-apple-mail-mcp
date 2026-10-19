import XCTest
@testable import CheAppleMailMCP

/// #465 — task 2.1. The first four cases are the spec's "argument extraction"
/// example table, verbatim (independent expected values).
final class TemplateExtractorTests: XCTestCase {
    private func extract(_ f: String, _ m: String) -> TemplateExtraction {
        TemplateExtractor.extract(formatString: f, message: m)
    }

    // spec example table
    func testSpecExampleRows() {
        XCTAssertEqual(extract("%@ Received %lu new local message actions",
                               "[acct - box] Received 3 new local message actions"),
                       TemplateExtraction(kind: .structured, args: [3]))
        XCTAssertEqual(extract("%@ Recalculated priorities - network: %lu, persistence: %lu",
                               "[acct - box] Recalculated priorities - network: 22, persistence: 0"),
                       TemplateExtraction(kind: .structured, args: [22, 0]))
        XCTAssertEqual(extract("Created %{public}@ action %lld for %lu messages",
                               "Created append action 11198 for <private> messages"),
                       TemplateExtraction(kind: .structured, args: [11198, nil]))
        XCTAssertEqual(extract("%{public}@", "any text at all"),
                       TemplateExtraction(kind: .unstructured, args: []))
    }

    func testMessageThatDoesNotMatchItsTemplate_isUnstructuredWithNoArgs() {
        XCTAssertEqual(extract("%@ Received %lu new local message actions", "totally different text"),
                       TemplateExtraction(kind: .unstructured, args: []))
        // integer slot holding non-digits
        XCTAssertEqual(extract("count: %lu", "count: many"),
                       TemplateExtraction(kind: .unstructured, args: []))
        // trailing garbage after the template's end
        XCTAssertEqual(extract("count: %lu", "count: 5 and more"),
                       TemplateExtraction(kind: .unstructured, args: []))
    }

    func testIntegerSpecifierVariants() {
        XCTAssertEqual(extract("a %d b %i c %u", "a -5 b 7 c 9").args, [-5, 7, 9])
        XCTAssertEqual(extract("a %ld b %llu c %zu d %hhd", "a 1 b 2 c 3 d 4").args, [1, 2, 3, 4])
        XCTAssertEqual(extract("n=%{public}lu", "n=12").args, [12])
        XCTAssertEqual(extract("w=%5d", "w=42").args, [42])
    }

    func testNonIntegerSpecifiers_neverYieldArgs() {
        // hex / pointer / float / string are not "integer arguments" for the brief output
        XCTAssertEqual(extract("id %x end", "id ff end"), TemplateExtraction(kind: .structured, args: []))
        XCTAssertEqual(extract("p %p end", "p 0x7ab1d76300 end"), TemplateExtraction(kind: .structured, args: []))
        XCTAssertEqual(extract("f %f end", "f 1.5 end"), TemplateExtraction(kind: .structured, args: []))
        // custom decoders print words, not digits: must not be read as integers
        XCTAssertEqual(extract("flag %{bool}d end", "flag YES end"), TemplateExtraction(kind: .structured, args: []))
    }

    func testLiteralPercentAndRegexMetacharactersInTheTemplate() {
        XCTAssertEqual(extract("100%% of [x] (y) %lu.*", "100% of [x] (y) 4.*").args, [4])
        XCTAssertEqual(extract("Remove draft(s) id=%lu [a|b]", "Remove draft(s) id=8 [a|b]").args, [8])
    }

    func testStringArgumentContainingDigitsIsNotMistakenForAnInteger() {
        // %@ swallows "3 apples"; only the real %lu slot is read.
        XCTAssertEqual(extract("%@ took %lu ms", "[3 apples] took 40 ms").args, [40])
    }

    func testPlaceholderOnlyTemplateIsUnstructured_evenIfTheMessageLooksNumeric() {
        XCTAssertEqual(extract("%lu", "12"), TemplateExtraction(kind: .structured, args: [12]),
                       "an integer-only template is still literal-free but fully parseable")
        XCTAssertEqual(extract("%{public}@%{public}@", "ab"), TemplateExtraction(kind: .unstructured, args: []))
    }

    func testEmptyTemplate() {
        XCTAssertEqual(extract("", ""), TemplateExtraction(kind: .unstructured, args: []))
        XCTAssertEqual(extract("", "something"), TemplateExtraction(kind: .unstructured, args: []))
    }

    func testIntegerOverflowDegradesToNilNotCrash() {
        XCTAssertEqual(extract("n=%llu", "n=18446744073709551616").args, [nil], "20 digits past Int.max: read, then nil")
        XCTAssertEqual(extract("n=%llu", "n=99999999999999999999999999"), TemplateExtraction(kind: .unstructured, args: []),
                       "more than 20 digits is not an integer argument at all (round 6)")
    }

    /// Scoundrel check: log text derives partly from mail content. A template
    /// with many `%@` against a long non-matching message must stay linear,
    /// not blow up the way a lazy-quantifier regex does.
    func testManyWildcardsAgainstLongNonMatchingMessage_staysFast() {
        let template = "%@ a %@ a %@ a %@ a %@ a %@ a %@ b"
        let message = String(repeating: "a ", count: 3000)
        let t0 = Date()
        let r = extract(template, message)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
        XCTAssertEqual(r.kind, .unstructured)
    }

    /// finding #35: the first occurrence of the next literal can sit INSIDE a `%@` argument that the
    /// remote side controls (an account or mailbox name). Taking it would let a planted number be
    /// reported as the real argument. If the literal is not unambiguous, report nothing.
    func testPlantedIntegerInsideAWildcardIsNotReportedAsAnArgument() {
        XCTAssertEqual(extract("%@ count %lu items %@", "[acct - evil count 99999 items x] count 3 items done"),
                       TemplateExtraction(kind: .unstructured, args: []))
    }

    func testUnambiguousTemplateStaysStructured() {
        XCTAssertEqual(extract("%@ count %lu items %@", "[acct - box] count 3 items done"),
                       TemplateExtraction(kind: .structured, args: [3]))
    }

    private func structured(_ args: [Int?]) -> TemplateExtraction { TemplateExtraction(kind: .structured, args: args) }
    private let unstructured = TemplateExtraction(kind: .unstructured, args: [])

    /// Verify round 2, finding 6: requiring the literal after EVERY wildcard to be unique also
    /// rejected templates that reuse their own separator. `%{public}@ %lu messages expunged` lost its
    /// integer whenever the account bracket held a space — 19 templates, about 11,000 of 382,806 real
    /// events in eight hours. The text after the LAST wildcard is matched from the END of the message,
    /// which that wildcard's text cannot reach, so it needs no uniqueness rule.
    func testTheTailAfterTheLastWildcardIsMatchedFromTheEnd() {
        XCTAssertEqual(extract("%{public}@ %lu messages expunged", "[acct - INBOX] 5 messages expunged"), structured([5]))
        XCTAssertEqual(extract("%@ / %lu / %lu", "[a - b] / 3 / 4"), structured([3, 4]))
        XCTAssertEqual(extract("%@ took %lu ms", "[a took b] took 40 ms"), structured([40]))
    }

    func testANumberPlantedInTheLastWildcardCannotReachTheTail() {
        XCTAssertEqual(extract("%{public}@ %lu messages expunged", "[acct - evil 99999 messages expunged x] 5 messages expunged"),
                       structured([5]))
        XCTAssertEqual(extract("%@ took %lu ms", "[a took 999 ms] took 40 ms"), structured([40]))
    }

    /// Between two wildcards there is no anchor: a segment that carries integers must occur exactly
    /// once there (finding #35 above); a segment without integers only has to exist.
    func testAMiddleSegmentWithoutIntegersNeedNotBeUnique() {
        XCTAssertEqual(extract("%@: %@ moved %lu", "[a: b] x: y moved 3"), structured([3]))
    }

    func testAnIntegerDirectlyBesideAWildcardHasNoBoundary() {
        XCTAssertEqual(extract("%@%lu items", "abc12 items"), unstructured, "(abc, 12) or (abc1, 2)?")
        XCTAssertEqual(extract("count %lu%@", "count 12abc"), unstructured)
    }

    /// Verify round 2, findings 3/17/20: the backstop's email shape had lost the lookbehind that made
    /// the redaction pattern linear, and `formatString` had no length bound. The longest real template
    /// measured is 351 characters; anything over 1,024 is withheld rather than scanned.
    func testTheDataShapeBackstopIsBoundedAndSharesTheRedactionPattern() {
        XCTAssertTrue(TemplateExtractor.looksLikeData(String(repeating: "a", count: 1025)))
        XCTAssertTrue(TemplateExtractor.looksLikeData("Session 123e4567-e89b-12d3-a456-426614174000 took %lu ms"),
                      "a UUID in the template is data, not a compile-time string (finding 17c)")
        XCTAssertFalse(TemplateExtractor.looksLikeData("Session %{public}@ took %lu ms"))
        let t0 = Date()
        XCTAssertFalse(TemplateExtractor.looksLikeData(String(repeating: "a", count: 1024)))
        XCTAssertFalse(TemplateExtractor.looksLikeData(String(repeating: "%{", count: 512)))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.2)
        XCTAssertEqual(TemplateExtractor.emailShapePattern, IdentifierRedactor.emailPattern,
                       "one email shape, not two that drift apart")
    }

    func testHasLiteralText() {
        XCTAssertFalse(TemplateExtractor.hasLiteralText("%{public}@"))
        XCTAssertFalse(TemplateExtractor.hasLiteralText("%@ %lu"))
        XCTAssertFalse(TemplateExtractor.hasLiteralText(""))
        XCTAssertTrue(TemplateExtractor.hasLiteralText("%@ created"))
        XCTAssertTrue(TemplateExtractor.hasLiteralText("100%%"))
    }

    /// Verify round 6, findings 4/6/14: the placeholder cap did not bound the work. A tail that starts with a
    /// literal overlapping digits (`%@1%d x`) re-scanned the digit run from every hit: 63 s on 65,536 `1`s
    /// (measured by the reviewer). Integers are at most 20 digits, the tail is searched only where it can end,
    /// and a middle segment examines a bounded number of placements.
    func testTheMatchersWorkIsBoundedOnAdversarialInput() {
        let ones = String(repeating: "1", count: 65_536)
        let cases: [(String, String)] = [
            ("%@1%d x", ones),
            ("%@11%lu x", ones),
            ("%@ count %lu items %@", String(repeating: " count 1 items", count: 4_500)),
            ("%@ %lu", String(repeating: " ", count: 65_000) + "7"),
        ]
        // Each input took 63–86 s before the bound (round 6). A monotonic clock and a 5 s ceiling keep the test
        // meaningful (one order of magnitude below the old cost) without flaking on a loaded machine (round 7, 1/13);
        // the outcomes are asserted too, so a fast WRONG answer fails as well.
        let expected: [TemplateExtraction] = [unstructured, unstructured, unstructured, structured([7])]
        for ((template, message), want) in zip(cases, expected) {
            let clock = ContinuousClock()
            var got = unstructured
            let elapsed = clock.measure { got = extract(template, message) }
            XCTAssertLessThan(elapsed, .seconds(5), "\(template) took \(elapsed)")
            XCTAssertEqual(got, want, template)
        }
    }

    func testAnIntegerLongerThanTwentyDigitsIsNotAnArgument() {
        XCTAssertEqual(extract("%@ total %lu", "[a - b] total " + String(repeating: "9", count: 21)), unstructured)
        XCTAssertEqual(extract("%@ total %lu", "[a - b] total 18446744073709551615"), structured([nil]), "20 digits: read, overflow → nil")
    }

    /// Round 7, finding 7: the middle-segment budget and the tail window edge, each reached on purpose.
    func testTheMiddleBudgetAndTheTailWindowEdge() {
        // 1,025 placements of " n=" that fail (no digit) before the one that would fit: the budget runs out first,
        // and an unproven placement reports nothing.
        let failing = String(repeating: " n=x", count: 1_025)
        XCTAssertEqual(extract("%@ n=%d x %@", "[a - b]" + failing + " n=5 x end"), unstructured)
        XCTAssertEqual(extract("%@ n=%d x %@", "[a - b] n=5 x end"), structured([5]), "within the budget it is found")
        // A tail of the longest possible length: a sign and 20 digits right after the last wildcard's text.
        XCTAssertEqual(extract("%@ v=%lld", "[a - b] v=-18446744073709551615"), structured([nil]))
        XCTAssertEqual(extract("%@ v=%lld", "[a - b] v=-1844674407370955161"), structured([-1844674407370955161]))
    }
}
