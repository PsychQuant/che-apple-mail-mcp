import XCTest
@testable import CheAppleMailMCP

final class PostIdentificationCleanupTests: XCTestCase {
    func testNativeWrapperDoesNotTurnMissingTitleIntoLiteralText() throws {
        let helpers = composeCleanupIdentityHandlers
            .replacingOccurrences(of: "tell application \"Mail\"", with: "tell me")
            .replacingOccurrences(of: "repeat with _window in windows", with: "repeat with _window in {42}")
            .replacingOccurrences(of: "id of _window", with: "contents of _window")
            .replacingOccurrences(of: "name of _window", with: "missing value")
            .replacingOccurrences(of: "id of front window", with: "42")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", helpers + "\nreturn my composeCleanupOwnerState(42, \"missing value\", false)"]
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines), "unknown")
    }

    func testNativeClassifierDistinguishesAbsenceChangesAmbiguityAndFocus() throws {
        let cases = [
            ("{}, {}, missing value, 42, \"Target\", false", "absent"),
            ("{42}, {\"Target\"}, 42, 42, \"Target\", true", "owned"),
            ("{42}, {\"target\"}, 42, 42, \"Target\", false", "changed"),
            ("{42, 99}, {\"Target\", \"Target\"}, 42, 42, \"Target\", false", "ambiguous"),
            ("{42, 99}, {\"Target\", \"Other\"}, 99, 42, \"Target\", true", "wrong_front"),
            ("{42}, {}, 42, 42, \"Target\", false", "unknown"),
            ("{42, 42}, {\"Target\", \"Target\"}, 42, 42, \"Target\", false", "unknown"),
            ("{42}, {missing value}, 42, 42, \"missing value\", false", "unknown"),
            ("{42}, {\"Target\"}, \"42\", 42, \"Target\", true", "unknown"),
            ("{42}, {\"Target\"}, 42, missing value, \"Target\", false", "unknown")
        ]
        for (arguments, expected) in cases {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", composeCleanupIdentityHandlers + "\nreturn my classifyComposeCleanupOwner(" + arguments + ")"]
            let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines), expected)
        }
    }

    private func replacingTell(_ source: String, opener: String, replacement: (String) -> String) throws -> String {
        var lines = source.components(separatedBy: "\n")
        while let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == opener }) {
            var depth = 0, finish: Int?
            for i in start..<lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("tell ") { depth += 1 }
                if line == "end tell" { depth -= 1 }
                if depth == 0 { finish = i; break }
            }
            let end = try XCTUnwrap(finish)
            let block = lines[start...end].joined(separator: "\n")
            lines.replaceSubrange(start...end, with: [replacement(block)])
        }
        return lines.joined(separator: "\n")
    }

    private func executeCleanup(initial: String, afterClose: String, afterAX: String) throws -> String {
        let production = buildMailtoComposeScript(url: "mailto:a@example.invalid?subject=Target",
                                                  subject: "Target", attachments: [], send: false)
        let begin = try XCTUnwrap(production.range(of: "on error _mErr"))
        let end = try XCTUnwrap(production.range(of: "on error _cleanupErr", range: begin.upperBound..<production.endIndex))
        var body = String(production[begin.upperBound..<end.lowerBound])
        body = try replacingTell(body, opener: "tell application \"Mail\"") { block in
            block.contains("close _cw saving no") ? "my fixtureClose()" : "set _stillOpen to (my fixtureState is not \"absent\")"
        }
        body = try replacingTell(body, opener: "tell application \"System Events\"") { _ in
            "set _titleMatches to 1\nset my axCalls to my axCalls + 1\nset my fixtureState to \"\(afterAX)\""
        }
        body = body.replacingOccurrences(of: "delay 0.4", with: "delay 0")
        guard !body.contains("tell application"), !body.contains("click ") else {
            throw NSError(domain: "CleanupFixture", code: 1)
        }
        let source = """
        property fixtureState : "\(initial)"
        property closeCalls : 0
        property axCalls : 0
        -- Signature menu dismissal is an external boundary for this ownership fixture.
        on dismissSignatureTracking()
            return true
        end dismissSignatureTracking
        on composeCleanupOwnerState(expectedID, expectedTitle, requireFront)
            return my fixtureState
        end composeCleanupOwnerState
        on fixtureClose()
            if my fixtureState is "owned" then
                set my closeCalls to my closeCalls + 1
                set my fixtureState to "\(afterClose)"
            end if
        end fixtureClose
        set _mErr to "original"
        set _ourId to 42
        \(body)
        on error _fixtureError
            set _mErr to _mErr & "|FAILED:" & _fixtureError
        end try
        return (closeCalls as string) & "|" & (axCalls as string) & "|" & _mErr
        """
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return value
    }

    func testAlreadyAbsentOwnerNeverEntersAXCleanup() throws {
        XCTAssertEqual(try executeCleanup(initial: "absent", afterClose: "absent", afterAX: "absent"), "0|0|original")
    }

    func testSuccessfulNativeCloseNeverTouchesAnotherSameTitleAXWindow() throws {
        XCTAssertEqual(try executeCleanup(initial: "owned", afterClose: "absent", afterAX: "absent"), "1|0|original")
    }

    func testOwnedWindowWithRemainingSheetCanCompleteCleanup() throws {
        XCTAssertEqual(try executeCleanup(initial: "owned", afterClose: "owned", afterAX: "absent"), "1|1|original")
    }

    func testChangedOrAmbiguousNativeOwnerIsPreserved() throws {
        for state in ["changed", "ambiguous"] {
            let result = try executeCleanup(initial: state, afterClose: state, afterAX: "absent")
            XCTAssertTrue(result.hasPrefix("0|0|original — WINDOWLEFTOPEN:"), result)
        }
        let changed = try executeCleanup(initial: "owned", afterClose: "changed", afterAX: "absent")
        XCTAssertTrue(changed.hasPrefix("1|0|original — WINDOWLEFTOPEN:"), changed)
    }

    func testUnknownOwnershipReportsUnverifiedStateWithoutEffects() throws {
        let result = try executeCleanup(initial: "unknown", afterClose: "unknown", afterAX: "absent")
        XCTAssertTrue(result.hasPrefix("0|0|original — WINDOWLEFTOPEN:"), result)
        XCTAssertTrue(result.contains("state could not be verified"), result)
    }

    private func executeAX(mode: String = "normal", button: String = "Don't Save") throws -> String {
        let production = buildMailtoComposeScript(url: "mailto:a@example.invalid?subject=Target",
                                                  subject: "Target", attachments: [], send: false)
        let start = try XCTUnwrap(production.range(of: "on error _mErr"))
        let end = try XCTUnwrap(production.range(of: "on error _cleanupErr", range: start.upperBound..<production.endIndex))
        var block = ""
        _ = try replacingTell(String(production[start.upperBound..<end.lowerBound]), opener: "tell application \"System Events\"") {
            block = $0; return ""
        }
        XCTAssertFalse(block.isEmpty)
        let boxes = ["partial", "ambiguous", "near-title", "exact-first"].contains(mode) ? "{1, 2}" : "{1}"
        block = block.replacingOccurrences(of: "tell application \"System Events\"", with: "tell me")
            .replacingOccurrences(of: "tell process \"Mail\"", with: "tell me")
            .replacingOccurrences(of: "repeat with _cw2 in windows", with: "repeat with _cw2 in " + boxes)
            .replacingOccurrences(of: "(title of _cw2 as string)", with: "(my fixtureTitle(contents of _cw2))")
            .replacingOccurrences(of: "(title of _cw2)", with: "(my fixtureTitle(contents of _cw2))")
            .replacingOccurrences(of: "title of _cw2", with: "my fixtureTitle(contents of _cw2)")
            .replacingOccurrences(of: "(count of sheets of _cw2)", with: "(my fixtureSheetCount(contents of _cw2))")
            .replacingOccurrences(of: "perform action \"AXRaise\" of _cw2", with: "my fixtureRaise(contents of _cw2)")
            .replacingOccurrences(of: "set _sh to sheet 1 of _cw2", with: "set _sh to my fixtureSheet(contents of _cw2)")
            .replacingOccurrences(of: "(value of attribute \"AXIdentifier\" of _sh)", with: "\"Mail.sendMessageAlert\"")
            .replacingOccurrences(of: "buttons of _sh", with: "{_sh}")
            .replacingOccurrences(of: "(title of _b as text)", with: "(my fixtureButton(contents of _b))")
            .replacingOccurrences(of: "click _b", with: "my fixtureClick(contents of _b)")
            .replacingOccurrences(of: "delay 0.1", with: "delay 0")
        guard !block.contains("tell application"), !block.contains("perform action"), !block.contains("click _b") else {
            throw NSError(domain: "AXCleanupFixture", code: 1)
        }
        let source = """
        property mode : "\(mode)"
        property ownerState : "\(mode == "absent" ? "absent" : "owned")"
        property wrongFront : false
        property raises : 0
        property clicks : 0
        on composeCleanupOwnerState(expectedID, expectedTitle, requireFront)
            if requireFront and my wrongFront then return "wrong_front"
            return my ownerState
        end composeCleanupOwnerState
        on fixtureTitle(row)
            if my mode is "partial" and row is 2 then error "fixture AX read failed" number -9997
            if my mode is "near-title" and row is 1 then return "target"
            if my mode is "exact-first" and row is 2 then return "Other"
            return "Target"
        end fixtureTitle
        on fixtureTarget(row)
            set expectedRow to 1
            if my mode is "near-title" then set expectedRow to 2
            if row is not expectedRow then error "wrong AX action target" number -9996
        end fixtureTarget
        on fixtureSheetCount(row)
            my fixtureTarget(row)
            return 1
        end fixtureSheetCount
        on fixtureSheet(row)
            my fixtureTarget(row)
            return row
        end fixtureSheet
        on fixtureClick(row)
            my fixtureTarget(row)
            set my clicks to my clicks + 1
        end fixtureClick
        on fixtureRaise(row)
            my fixtureTarget(row)
            set my raises to my raises + 1
            if my mode is "after-raise" then set my ownerState to "changed"
            if my mode is "wrong-front" then set my wrongFront to true
        end fixtureRaise
        on fixtureButton(row)
            my fixtureTarget(row)
            if my mode is "before-click" then set my ownerState to "absent"
            return "\(button)"
        end fixtureButton
        set _ourId to 42
        set _titleMatches to 0
        set outcome to "ok"
        try
        \(block)
        on error msg number n
            set outcome to "error:" & n
        end try
        return (raises as string) & "|" & (clicks as string) & "|" & outcome
        """
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    func testAXCleanupRejectsOwnerLossAndWrongFrontAtActionBoundaries() throws {
        XCTAssertTrue(try executeAX(mode: "absent").hasPrefix("0|0|error:"))
        for mode in ["after-raise", "wrong-front", "before-click"] {
            XCTAssertTrue(try executeAX(mode: mode).hasPrefix("1|0|error:"), mode)
        }
    }

    func testAXCleanupRejectsPartialAndAmbiguousEnumeration() throws {
        XCTAssertEqual(try executeAX(mode: "partial"), "0|0|error:-9997")
        XCTAssertEqual(try executeAX(mode: "ambiguous"), "0|0|ok")
    }

    func testAXActionUsesTheSameExactTitleAsItsUniquenessCheck() throws {
        XCTAssertEqual(try executeAX(mode: "near-title"), "1|1|ok")
        XCTAssertEqual(try executeAX(mode: "exact-first"), "1|1|ok")
    }

    func testAXCleanupOnlyClicksSupportedDiscardLabels() throws {
        for label in ["不儲存", "Don't Save", "Don’t Save"] {
            XCTAssertEqual(try executeAX(button: label), "1|1|ok")
        }
        for label in ["Save", "Cancel", "Done"] {
            XCTAssertEqual(try executeAX(button: label), "1|0|ok")
        }
    }

    func testNativeCloseTargetsOnlyTheCapturedIDAndUnchangedTitle() throws {
        let production = buildMailtoComposeScript(url: "mailto:a@example.invalid?subject=Target",
                                                  subject: "Target", attachments: [], send: false)
        let start = try XCTUnwrap(production.range(of: "on error _mErr"))
        let end = try XCTUnwrap(production.range(of: "on error _cleanupErr", range: start.upperBound..<production.endIndex))
        var block = ""
        _ = try replacingTell(String(production[start.upperBound..<end.lowerBound]), opener: "tell application \"Mail\"") {
            if $0.contains("close _cw saving no") { block = $0 }
            return ""
        }
        XCTAssertFalse(block.isEmpty)
        block = block.replacingOccurrences(of: "tell application \"Mail\"", with: "tell me")
            .replacingOccurrences(of: "repeat with _cw in windows", with: "repeat with _cw in {1, 2}")
            .replacingOccurrences(of: "(id of _cw)", with: "(item (contents of _cw) of fixtureIDs)")
            .replacingOccurrences(of: "name of _cw", with: "item (contents of _cw) of fixtureNames")
            .replacingOccurrences(of: "close _cw saving no", with: "set end of closedIDs to item (contents of _cw) of fixtureIDs")
        for (ids, names, expected) in [
            ("{42, 99}", "{\"Target\", \"Target\"}", "42"),
            ("{42, 99}", "{\"Changed\", \"Target\"}", ""),
            ("{41, 99}", "{\"Target\", \"Target\"}", ""),
            ("{42, 99}", "{missing value, \"Target\"}", "")
        ] {
            let script = "set fixtureIDs to " + ids + "\nset fixtureNames to " + names
                + "\nset _ourId to 42\nset closedIDs to {}\n" + block + "\nreturn closedIDs as string"
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines), expected)
        }
    }

    func testCompleteGeneratedDraftAndSendScriptsCompile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup333-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for send in [false, true] {
            let script = buildMailtoComposeScript(url: "mailto:a@example.invalid?subject=Target",
                subject: "同名 \"quoted\"", attachments: [], send: send,
                fromAddress: "sender@example.invalid", fill: [.init(field: .bcc, recipients: ["Named <b@example.invalid>"])])
            let source = root.appendingPathComponent("source.applescript")
            try script.write(to: source, atomically: true, encoding: .utf8)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = ["-o", root.appendingPathComponent("output.scpt").path, source.path]
            let errors = Pipe(); process.standardError = errors
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }
}
