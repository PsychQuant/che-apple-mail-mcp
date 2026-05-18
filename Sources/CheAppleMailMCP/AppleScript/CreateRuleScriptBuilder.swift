import Foundation

/// AppleScript builder for `create_rule` (#140 — sister fix to #116).
///
/// Extracts `MailController.createRule`'s inline AppleScript into a testable
/// free function. The extraction is purely refactor + security hardening:
///
/// 1. **Whitelist** — `ruleQualifierWhitelist` pins the 8 valid `RuleQualifier`
///    enum values from Apple Mail's AppleScript dictionary. The pre-extraction
///    `MailController.createRule` raw-interpolated `qualifier` into AppleScript
///    at the `make new rule condition with properties {... qualifier:\(qualifier), ...}`
///    line, allowing newline-bearing / quote-bearing / semicolon-chained
///    payloads to inject arbitrary AppleScript (CWE-94 Code Injection;
///    downstream CWE-78 via `do shell script`). Independently surfaced by
///    Security + Devil's Advocate + Codex during `/idd-verify` of #116.
///
/// 2. **Defense-in-depth** — `Server.swift`'s `create_rule` handler validates
///    membership against `ruleQualifierWhitelist` before delegating, returning
///    a user-facing `MailError.invalidParameter` for non-whitelisted input;
///    the `precondition` below catches programmer-error if any internal caller
///    bypasses the handler gate. Crash beats silent injection.
///
/// 3. **Byte-equivalence** — for valid inputs the output is byte-identical to
///    the pre-extraction inline AppleScript in `MailController.createRule`
///    (preserves the `appleScriptEscape` for header / expression / name /
///    moveMailbox slots; preserves the action emission order: move →
///    mark_read → mark_flagged → delete_message → return). Pinned by
///    `CreateRuleScriptBuilderTests.testBuildCreateRuleScript_byteEquivalenceWithInlineImplementation`.
///
/// Source of truth for the whitelist:
/// `/System/Applications/Mail.app/Contents/Resources/Mail.sdef`
/// `<enumeration name="RuleQualifier" code="enrq">` — 8 enumerators.
///
/// > **Note**: `appleScriptEscape` (shared free function) and the private
/// > `MailController.escapeForAppleScript` have identical implementations
/// > (5-stage `replacingOccurrences` chain); dedup tracked at #110. This
/// > builder uses `appleScriptEscape` consistent with the #104 PR-B/C/D
/// > extraction pattern.

/// Canonical whitelist of Apple Mail `RuleQualifier` enum values. Single
/// source of truth used by both `Server.swift`'s `create_rule` handler
/// (user-facing reject with `MailError.invalidParameter`) and
/// `buildCreateRuleScript` below (defense-in-depth `precondition`).
///
/// Membership is lowercase-strict and exact-match — no case-folding, no
/// trim. Drift between this constant and Apple Mail's `Mail.sdef` enum is
/// a bug; `CreateRuleScriptBuilderTests
/// .testRuleQualifierWhitelist_containsAllAppleMailEnumValues` pins it.
let ruleQualifierWhitelist: Set<String> = [
    "begins with value",
    "does contain value",
    "does not contain value",
    "ends with value",
    "equal to value",
    "less than value",
    "greater than value",
    "none"
]

/// Build the AppleScript for `create_rule`.
///
/// - Parameters:
///   - name: Rule name. Escaped via `appleScriptEscape`.
///   - conditions: Array of `[header, qualifier, expression]` dictionaries.
///     Conditions with any missing key are skipped (preserves pre-extraction
///     behavior at `MailController.createRule` L1106-1115).
///   - actions: Dictionary of `[move_message: String]` and/or
///     `[mark_read|mark_flagged|delete_message: Bool]` entries. Action emission
///     order matches the pre-extraction `MailController.createRule`
///     (L1118-1140): `move → mark_read → mark_flagged → delete_message`.
///
/// - Returns: AppleScript suitable for `runScript`.
///
/// - Important: This function `precondition`-fires on any non-whitelisted
///   `qualifier` value. The user-facing reject path lives in
///   `Server.swift`'s `create_rule` handler — by the time control reaches
///   this builder, the handler MUST have validated against
///   `ruleQualifierWhitelist`. The `precondition` here is defense-in-depth
///   (programmer-error catch), not the primary contract.
func buildCreateRuleScript(name: String, conditions: [[String: String]], actions: [String: Any]) -> String {
    var script = """
    tell application "Mail"
        set newRule to make new rule with properties {name:"\(appleScriptEscape(name))"}
    """

    // Add conditions
    for condition in conditions {
        if let header = condition["header"],
           let qualifier = condition["qualifier"],
           let expression = condition["expression"] {
            precondition(ruleQualifierWhitelist.contains(qualifier),
                         "buildCreateRuleScript called with non-whitelisted qualifier '\(qualifier)' — "
                         + "Server.swift handler must guard via ruleQualifierWhitelist before delegating (#140)")
            script += "\n" + """
                tell newRule
                    make new rule condition with properties {rule type:header rule, header:"\(appleScriptEscape(header))", qualifier:\(qualifier), expression:"\(appleScriptEscape(expression))"}
                end tell
            """
        }
    }

    // Add actions — emission order preserved from pre-extraction
    // MailController.createRule (L1118-1140): move → mark_read → mark_flagged
    // → delete_message. The order is part of the byte-equivalence contract.
    if let moveMailbox = actions["move_message"] as? String {
        script += "\n" + """
            set move message of newRule to (first mailbox whose name is "\(appleScriptEscape(moveMailbox))")
        """
    }

    if let markRead = actions["mark_read"] as? Bool {
        script += "\n" + """
            set mark read of newRule to \(markRead)
        """
    }

    if let markFlagged = actions["mark_flagged"] as? Bool {
        script += "\n" + """
            set mark flagged of newRule to \(markFlagged)
        """
    }

    if let deleteMessage = actions["delete_message"] as? Bool {
        script += "\n" + """
            set delete message of newRule to \(deleteMessage)
        """
    }

    script += "\n" + """
        return "Rule '\(appleScriptEscape(name))' created successfully"
    end tell
    """

    return script
}
