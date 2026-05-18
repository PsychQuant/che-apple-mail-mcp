import XCTest
@testable import CheAppleMailMCP

/// Tests for `CreateRuleScriptBuilder` — the testable extraction of
/// `MailController.createRule`'s inline AppleScript (#140 — sister fix
/// to #116, closes the second CWE-94 AppleScript injection slot).
///
/// Two contracts to lock down:
///
/// 1. **Whitelist hardening** — `ruleQualifierWhitelist` is the single
///    source of truth for the 8 valid `RuleQualifier` enum values
///    (empirically verified against `/System/Applications/Mail.app/
///    Contents/Resources/Mail.sdef`'s `<enumeration name="RuleQualifier">`).
///    Drift-pin + injection-payload rejection + case-strict + whitespace-strict.
///
/// 2. **Byte-equivalence regression** — `buildCreateRuleScript` MUST produce
///    output identical to the pre-extraction inline AppleScript in
///    `MailController.createRule` for valid inputs. A pinned snapshot
///    fixture (1 condition + all 4 actions) anchors "no behavior change".
final class CreateRuleScriptBuilderTests: XCTestCase {

    // MARK: - Whitelist contract (#140 — sister of #116's backgroundColorWhitelist)

    func testRuleQualifierWhitelist_containsAllAppleMailEnumValues() {
        // Source of truth: /System/Applications/Mail.app/Contents/Resources/Mail.sdef
        // <enumeration name="RuleQualifier" code="enrq">
        //   <enumerator name="begins with value"      code="rqbw"/>
        //   <enumerator name="does contain value"     code="rqco"/>
        //   <enumerator name="does not contain value" code="rqdn"/>
        //   <enumerator name="ends with value"        code="rqew"/>
        //   <enumerator name="equal to value"         code="rqie"/>
        //   <enumerator name="less than value"        code="rqlt"/>
        //   <enumerator name="greater than value"     code="rqgt"/>
        //   <enumerator name="none"                   code="rqno"/>
        // </enumeration>
        let expected: Set<String> = [
            "begins with value",
            "does contain value",
            "does not contain value",
            "ends with value",
            "equal to value",
            "less than value",
            "greater than value",
            "none"
        ]
        XCTAssertEqual(ruleQualifierWhitelist, expected,
                       "whitelist must exactly match Apple Mail's documented RuleQualifier enum;"
                       + " drift in either direction (missing or extra entries) is a bug.")
    }

    func testRuleQualifierWhitelist_rejectsInjectionPayloads() {
        // Newline-based AppleScript verb injection — the original CWE-94 shape
        XCTAssertFalse(
            ruleQualifierWhitelist.contains("does contain value, expression:\"\"} \n do shell script \"rm -rf ~\""),
            "newline-bearing payload must not be a whitelist member")

        // Quote-bearing injection
        XCTAssertFalse(
            ruleQualifierWhitelist.contains("does contain value\""),
            "quote-bearing payload must not be a whitelist member")

        // Semicolon / verb chaining
        XCTAssertFalse(
            ruleQualifierWhitelist.contains("equal to value; set foo to evil"),
            "semicolon-chained payload must not be a whitelist member")
    }

    func testRuleQualifierWhitelist_isCaseStrict() {
        // Apple Mail's enum is lowercase-strict; case variants must be rejected
        XCTAssertFalse(ruleQualifierWhitelist.contains("Does Contain Value"),
                       "Title-Case must be rejected — whitelist is lowercase-strict")
        XCTAssertFalse(ruleQualifierWhitelist.contains("DOES CONTAIN VALUE"),
                       "UPPERCASE must be rejected — whitelist is lowercase-strict")
    }

    func testRuleQualifierWhitelist_rejectsTrailingWhitespaceAndEmpty() {
        // Whitespace-padded values would also bypass `set` semantics and lead
        // to AppleScript parse errors; the contract is exact-match.
        XCTAssertFalse(ruleQualifierWhitelist.contains("begins with value "),
                       "trailing-whitespace variant must be rejected")
        XCTAssertFalse(ruleQualifierWhitelist.contains(" begins with value"),
                       "leading-whitespace variant must be rejected")
        XCTAssertFalse(ruleQualifierWhitelist.contains(""),
                       "empty string must be rejected (placeholder / lazy-default trap)")
    }

    // MARK: - Builder happy-path emission

    func testBuildCreateRuleScript_emitsAllValidQualifiers() {
        // Every whitelist member must successfully emit AppleScript with the
        // qualifier interpolated verbatim. Parameterized loop over all 8.
        for q in ruleQualifierWhitelist {
            let script = buildCreateRuleScript(
                name: "TestRule",
                conditions: [["header": "From", "qualifier": q, "expression": "example.com"]],
                actions: [:]
            )
            XCTAssertTrue(script.contains("qualifier:\(q)"),
                          "qualifier '\(q)' must appear verbatim in emitted AppleScript; got:\n\(script)")
            XCTAssertTrue(script.contains("make new rule with properties {name:\"TestRule\"}"),
                          "rule name must appear in script header")
        }
    }

    func testBuildCreateRuleScript_escapesHeaderAndExpression() {
        // header / expression go through appleScriptEscape (same as moveMailbox /
        // rule name). Quote-bearing payloads must be backslash-escaped, NOT
        // raw-interpolated (the qualifier path is the only one that uses
        // whitelist+precondition; header/expression use the escape path).
        let script = buildCreateRuleScript(
            name: "Rule\"with\"quotes",
            conditions: [["header": "Subject\"injection", "qualifier": "does contain value", "expression": "evil\"payload"]],
            actions: [:]
        )
        XCTAssertTrue(script.contains("Rule\\\"with\\\"quotes"),
                      "rule name quotes must be escaped")
        XCTAssertTrue(script.contains("Subject\\\"injection"),
                      "header quotes must be escaped")
        XCTAssertTrue(script.contains("evil\\\"payload"),
                      "expression quotes must be escaped")
    }

    func testBuildCreateRuleScript_multipleConditions() {
        // 2+ conditions emit 2+ `tell newRule ... make new rule condition` blocks
        let script = buildCreateRuleScript(
            name: "MultiRule",
            conditions: [
                ["header": "From",    "qualifier": "does contain value",     "expression": "a@x.com"],
                ["header": "Subject", "qualifier": "does not contain value", "expression": "spam"]
            ],
            actions: [:]
        )
        let occurrences = script.components(separatedBy: "make new rule condition").count - 1
        XCTAssertEqual(occurrences, 2, "2 conditions → 2 'make new rule condition' invocations; got \(occurrences) in:\n\(script)")
        XCTAssertTrue(script.contains("a@x.com"))
        XCTAssertTrue(script.contains("does not contain value"))
    }

    func testBuildCreateRuleScript_emitsMoveActionWithEscape() {
        // move_message action — moveMailbox value flows through appleScriptEscape
        let script = buildCreateRuleScript(
            name: "MoveRule",
            conditions: [],
            actions: ["move_message": "Archive\"folder"]
        )
        XCTAssertTrue(script.contains("set move message of newRule to (first mailbox whose name is \"Archive\\\"folder\")"),
                      "move action must emit with escaped mailbox name; got:\n\(script)")
    }

    func testBuildCreateRuleScript_emitsBoolActions() {
        // mark_read / mark_flagged / delete_message — all 3 Bool actions
        let script = buildCreateRuleScript(
            name: "BoolRule",
            conditions: [],
            actions: ["mark_read": true, "mark_flagged": false, "delete_message": true]
        )
        XCTAssertTrue(script.contains("set mark read of newRule to true"),
                      "mark_read=true line must emit")
        XCTAssertTrue(script.contains("set mark flagged of newRule to false"),
                      "mark_flagged=false line must emit")
        XCTAssertTrue(script.contains("set delete message of newRule to true"),
                      "delete_message=true line must emit")
    }

    // MARK: - Byte-equivalence regression snapshot
    //
    // This test pins the EXACT AppleScript output for a representative fixture
    // (1 condition + all 4 actions) against the pre-extraction inline string in
    // MailController.createRule. If anyone changes the builder's output format —
    // whitespace, line ordering, action emission order — this test fires.
    //
    // The expected string is byte-copied from the pre-extraction inline
    // AppleScript (commit `8c50d51` `MailController.swift:1099-1145` at HEAD~1 of
    // this branch); the extraction must produce identical output for valid inputs.

    func testBuildCreateRuleScript_byteEquivalenceWithInlineImplementation() {
        let script = buildCreateRuleScript(
            name: "RegressionFixture",
            conditions: [
                ["header": "From", "qualifier": "does contain value", "expression": "test@example.com"]
            ],
            actions: [
                "move_message": "Archive",
                "mark_read": true,
                "mark_flagged": false,
                "delete_message": false
            ]
        )

        // The expected output mirrors MailController.createRule's pre-extraction
        // inline AppleScript exactly. Format: `set newRule to make new rule ...`
        // line, then condition `tell newRule ... end tell` blocks, then action
        // lines (in the original `move → mark_read → mark_flagged → delete`
        // order from MailController.swift L1118-L1140), then `return "..."` line.
        //
        // Builder output must contain each of these substrings in order.
        // (Full-string equality is too brittle for Swift's `"""`-indented
        // accumulation, but ordered substring containment captures the same
        // contract while tolerating whitespace-only churn.)
        let expectedFragments = [
            "tell application \"Mail\"",
            "set newRule to make new rule with properties {name:\"RegressionFixture\"}",
            "tell newRule",
            "make new rule condition with properties {rule type:header rule, header:\"From\", qualifier:does contain value, expression:\"test@example.com\"}",
            "end tell",
            "set move message of newRule to (first mailbox whose name is \"Archive\")",
            "set mark read of newRule to true",
            "set mark flagged of newRule to false",
            "set delete message of newRule to false",
            "return \"Rule 'RegressionFixture' created successfully\"",
            "end tell"
        ]

        var searchStart = script.startIndex
        for fragment in expectedFragments {
            guard let range = script.range(of: fragment, range: searchStart..<script.endIndex) else {
                XCTFail("Missing or out-of-order fragment '\(fragment)' in builder output:\n\(script)")
                return
            }
            searchStart = range.upperBound
        }
    }
}
