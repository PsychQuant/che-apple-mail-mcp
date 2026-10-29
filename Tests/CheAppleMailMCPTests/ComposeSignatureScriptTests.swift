import Foundation
import XCTest
@testable import CheAppleMailMCP

final class ComposeSignatureScriptTests: XCTestCase {
    private func script(_ signature: ComposeSignatureSelection, send: Bool = false) -> String {
        buildMailtoComposeScript(url: "mailto:a%40example.invalid?subject=Title&body=body", subject: "Title",
                                 attachments: ["/tmp/file.txt"], send: send, fromAddress: "from@example.invalid", signature: signature)
    }
    func test_signature_phase_follows_sender_and_precedes_attachments_dispatch() throws {
        let source = script(.init(mode: .named, name: "Professional"))
        let sender = try XCTUnwrap(source.range(of: "set _senderReadback"))
        let signature = try XCTUnwrap(source.range(of: "set _signatureSelected"))
        let attachment = try XCTUnwrap(source.range(of: "keystroke \"a\" using {command down, shift down}"))
        let dispatch = try XCTUnwrap(source.range(of: "keystroke \"s\" using command down"))
        XCTAssertLessThan(sender.lowerBound, signature.lowerBound)
        XCTAssertLessThan(signature.lowerBound, attachment.lowerBound)
        XCTAssertLessThan(attachment.lowerBound, dispatch.lowerBound)
        XCTAssertTrue(source.contains("AXIdentifier\" of _candidate) is \"popup_signature\""))
        XCTAssertLessThan(try XCTUnwrap(source.range(of: "click _noneItem")).lowerBound,
                          try XCTUnwrap(source.range(of: "click _signaturePicked")).lowerBound)
        XCTAssertTrue(source.contains("_noneLabel is not \"None\" and _noneLabel is not \"無\""))
        XCTAssertTrue(source.contains("AXMenuItemMarkChar"))
        XCTAssertFalse(source.contains("set content"))
        XCTAssertFalse(source.contains("set html content"))
    }

    func test_default_does_not_change_signature_and_invalid_selection_never_opens() {
        let source = script(.mailDefault)
        XCTAssertFalse(source.contains("click _noneItem"))
        // The calls carry arguments; match the call, not a full argument list
        // that never appears (#322 verify).
        for call in ["my openedSignatureMenu(_signaturePopup", "my verifySignatureMenuChoice(_signaturePopup"] {
            XCTAssertFalse(source.contains(call), call)
            XCTAssertTrue(script(.init(mode: .none)).contains(call), "control: \(call)")
        }
        XCTAssertTrue(source.contains("_signatureVerified"))
        let invalid = script(.init(mode: .named, name: ""))
        XCTAssertFalse(invalid.contains("mailto"))
    }

    func test_signature_helper_serializes_unicode_without_executing_gui() throws {
        let source = "use framework \"Foundation\"\nuse scripting additions\n" + composeSignatureHandlers
            + "\nreturn my signatureReceipt(\"named\", \"簽名 ] [bcc-field-revealed]\", true, true)"
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        var result = "Draft created" + String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
        let receipt = try ComposeSignatureReceipt.extract(from: &result, requested: .init(mode: .named, name: "簽名 ] [bcc-field-revealed]"))
        XCTAssertEqual(receipt?.selection, "簽名 ] [bcc-field-revealed]")
        XCTAssertEqual(result, "Draft created")
    }

    func test_marked_choice_distinguishes_native_none_named_none_and_management_footer() throws {
        let helpers = "use framework \"Foundation\"\nuse scripting additions\n" + composeSignatureHandlers
        let labels = "{\"None\", \"\", \"None\", \"\", \"Edit Signatures…\"}"
        let enabled = "{true, false, true, false, true}"
        let fixtures = [
            ("{\"\", \"\", \"✓\", \"\", \"\"}", "none", "", "0"),
            ("{\"✓\", \"\", \"\", \"\", \"\"}", "none", "", "1"),
            ("{\"\", \"\", \"✓\", \"\", \"\"}", "named", "None", "3"),
            ("{\"✓\", \"\", \"\", \"\", \"\"}", "named", "None", "0"),
            ("{\"\", \"\", \"\", \"\", \"✓\"}", "named", "Edit Signatures…", "0")]
        for (marks, mode, name, expected) in fixtures {
            let source = helpers + "\nreturn my signatureChoiceIndex(" + labels + ", " + enabled + ", " + marks + ", \"" + mode + "\", \"" + name + "\")"
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let output = Pipe(); process.standardOutput = output
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
    }

    func test_native_missing_values_are_empty_without_erasing_literal_signature_names() throws {
        let helpers = "use framework \"Foundation\"\nuse scripting additions\n" + composeSignatureHandlers
        let enabled = "{true, false, true, false, true}"
        let fixtures = [
            ("{\"None\", missing value, \"Professional\", missing value, \"Edit Signatures…\"}",
             "{missing value, missing value, \"✓\", missing value, missing value}", "Professional", "3"),
            ("{\"None\", missing value, \"missing value\", missing value, \"Edit Signatures…\"}",
             "{missing value, missing value, \"✓\", missing value, missing value}", "missing value", "3"),
            ("{\"None\", \"missing value\", \"Professional\", missing value, \"Edit Signatures…\"}",
             "{missing value, missing value, \"✓\", missing value, missing value}", "Professional", "0"),
            ("{\"None\", missing value, \"Professional\", missing value, \"Edit Signatures…\"}",
             "{missing value, missing value, \"✓\", missing value, \"✓\"}", "Professional", "0"),
            ("{\"None\", 42, \"Professional\", missing value, \"Edit Signatures…\"}",
             "{missing value, missing value, \"✓\", missing value, missing value}", "Professional", "0"),
            ("{\"None\", missing value, \"Professional\", missing value, \"Edit Signatures…\"}",
             "{missing value, missing value, 42, missing value, missing value}", "Professional", "0")
        ]
        for (labels, marks, wanted, expected) in fixtures {
            let source = helpers + "\nreturn my signatureChoiceIndex(" + labels + ", " + enabled + ", " + marks
                + ", \"named\", \"" + wanted + "\")"
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
    }

    func test_named_matching_never_coerces_an_unlabeled_enabled_item() throws {
        let helpers = "use framework \"Foundation\"\nuse scripting additions\n" + composeSignatureHandlers
        for (label, expected) in [("missing value", "false"), ("\"missing value\"", "true")] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", helpers + "\nreturn my signatureNameMatches(" + label + ", true, \"missing value\")"]
            let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
    }

    func test_signature_verification_propagates_attribute_read_failures() throws {
        // Execute the real verification handler with only native operations
        // replaced by deterministic fixtures. A valid-looking menu must never
        // hide a failed label/mark read and reach the final selection click.
        let start = try XCTUnwrap(composeSignatureHandlers.range(of: "on verifySignatureMenuChoice("))
        let end = try XCTUnwrap(composeSignatureHandlers.range(of: "end verifySignatureMenuChoice", range: start.lowerBound..<composeSignatureHandlers.endIndex))
        let handler = String(composeSignatureHandlers[start.lowerBound..<end.upperBound])
        for failedRead in ["label", "mark"] {
            var source = handler
                .replacingOccurrences(of: "set _signatureMenuState to my openedSignatureMenu(_popup, _expectedId, _expectedTitle)", with: "set _signatureMenuState to {missing value, missing value, {}}")
                .replacingOccurrences(of: "repeat with _i from 1 to (count of menu items of _menu)", with: "repeat with _i from 1 to 1")
                .replacingOccurrences(of: "set _entry to menu item _i of _menu", with: "set _entry to missing value")
                .replacingOccurrences(of: "set _label to name of _entry", with: failedRead == "label" ? "error \"fixture attribute read failed\" number -9876" : "set _label to \"None\"")
                .replacingOccurrences(of: "set _mark to value of attribute \"AXMenuItemMarkChar\" of _entry", with: failedRead == "mark" ? "error \"fixture attribute read failed\" number -9876" : "set _mark to \"✓\"")
                .replacingOccurrences(of: "set end of _enabled to enabled of _entry", with: "set end of _enabled to true")
                .replacingOccurrences(of: "set _index to my signatureChoiceIndex(_labels, _enabled, _marks, _mode, _wanted)", with: "set _index to 1")
                .replacingOccurrences(of: "my assertComposeWindowOwner(_expectedId, _expectedTitle, true)", with: "set _ownerFixture to true")
                .replacingOccurrences(of: "my assertSignatureMenuOwner(_signatureMenuState)", with: "set _ownerFixture to true")
                .replacingOccurrences(of: "click menu item _index of _menu", with: "return \"incorrectly accepted\"")
            source += "\ntry\nmy verifySignatureMenuChoice(missing value, \"none\", \"\", 1, \"Title\")\nreturn \"incorrectly accepted\"\non error _message number _code\nreturn _code as text\nend try"
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines), "-9876", failedRead)
        }
    }

    func test_menu_property_guard_rejects_changed_process_identifier_title_and_focus() throws {
        // These fixtures prove changed-field rejection, not lifetime identity:
        // a replacement preserving every compared field is indistinguishable.
        let helpers = "use framework \"Foundation\"\nuse scripting additions\n" + composeSignatureHandlers
        let expected = "{44, \"_NS:4\", \"Title\", true, \"_NS:4\"}"
        let cases = [
            (expected, "true"),
            ("{45, \"_NS:4\", \"Title\", true, \"_NS:4\"}", "false"),
            ("{44, \"_NS:5\", \"Title\", true, \"_NS:5\"}", "false"),
            ("{44, \"_NS:4\", \"title\", true, \"_NS:4\"}", "false"),
            ("{44, \"_NS:4\", \"Title\", false, \"_NS:4\"}", "false"),
            ("{44, \"_NS:4\", \"Title\", true, \"_NS:5\"}", "false"),
            ("{44, missing value, \"Title\", true, missing value}", "false")]
        for (actual, result) in cases {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", helpers + "\nreturn my signatureAXOwnerMatches(" + actual + ", " + expected + ")"]
            let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines), result)
        }
    }

    func test_popup_discovery_does_not_accept_a_partial_identifier_scan() throws {
        let start = try XCTUnwrap(composeSignatureHandlers.range(of: "on signaturePopupFor("))
        let end = try XCTUnwrap(composeSignatureHandlers.range(of: "end signaturePopupFor", range: start.lowerBound..<composeSignatureHandlers.endIndex))
        let handler = String(composeSignatureHandlers[start.lowerBound..<end.upperBound])
            .replacingOccurrences(of: "set _total to count of pop up buttons of _window", with: "set _total to 2")
            .replacingOccurrences(of: "set _candidate to pop up button _i of _window", with: "set _candidate to _i")
            .replacingOccurrences(of: "if exists attribute \"AXIdentifier\" of _candidate then", with: "if true then")
            .replacingOccurrences(of: "if (value of attribute \"AXIdentifier\" of _candidate) is \"popup_signature\" then",
                with: "if _i is 2 and my fixtureShouldFail then error \"fixture read failed\" number -9877\nset _identifier to \"other\"\nif _i is 1 then set _identifier to \"popup_signature\"\nif _identifier is \"popup_signature\" then")
        for (fault, expected) in [("false", "1"), ("true", "missing value")] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "property fixtureShouldFail : " + fault + "\n" + handler + "\nreturn my signaturePopupFor(missing value)"]
            let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
    }

    func test_unconfirmed_menu_dismissal_blocks_native_cleanup() throws {
        let full = script(.init(mode: .none))
        let start = try XCTUnwrap(full.range(of: "on error _mErr"))
        let end = try XCTUnwrap(full.range(of: "on error _cleanupErr", range: start.upperBound..<full.endIndex))
        // Keep the entire cleanup, including anything before menu dismissal.
        // Replace native tell blocks at the boundary so this fixture cannot touch Mail.
        var lines = String(full[start.upperBound..<end.lowerBound]).components(separatedBy: "\n")
        while let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("tell application ") }) {
            var depth = 0
            var last: Int?
            for i in first..<lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("tell ") { depth += 1 }
                if line == "end tell" { depth -= 1 }
                if depth == 0 { last = i; break }
            }
            let finish = try XCTUnwrap(last)
            lines.replaceSubrange(first...finish, with: ["my fixtureNativeBoundary()"])
        }
        let cleanup = lines.joined(separator: "\n").replacingOccurrences(of: "delay 0.4", with: "delay 0")
        for (dismissed, expectedCalls) in [("false", "0"), ("true", "1")] {
            let source = """
            property nativeCalls : 0
            on dismissSignatureTracking()
                return \(dismissed)
            end dismissSignatureTracking
            on composeCleanupOwnerState(_id, _title, _front)
                return my fixtureNativeBoundary()
            end composeCleanupOwnerState
            on fixtureNativeBoundary()
                set my nativeCalls to my nativeCalls + 1
                error "stop before any native API" number -9878
            end fixtureNativeBoundary
            set _mErr to "fixture read failure"
            set _ourId to 42
            \(cleanup)
            on error
                -- Stop at the first native boundary or at the dismissal refusal.
            end try
            return my nativeCalls
            """
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines), expectedCalls)
        }
    }

    func test_native_window_identity_rejects_disappearance_rename_and_replacement() throws {
        let helpers = "use framework \"Foundation\"\nuse scripting additions\n" + composeSignatureHandlers
        let fixtures = [
            ("{42, 99}", "{\"Title\", \"Other\"}", "42", "true"),
            ("{99}", "{\"Title\"}", "99", "false"),
            ("{42, 99}", "{\"Renamed\", \"Title\"}", "99", "false"),
            ("{42}", "{\"title\"}", "42", "false"),
            ("{42, 99}", "{\"Title\", \"Other\"}", "99", "false")]
        for (ids, names, front, expected) in fixtures {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", helpers + "\nreturn my composeWindowMatches(" + ids + ", " + names + ", " + front + ", 42, \"Title\", true)"]
            let output = Pipe(); process.standardOutput = output
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
        let source = script(.init(mode: .none))
        XCTAssertTrue(source.contains("my assertComposeWindowOwner(_ourId, _t, false)"))
        XCTAssertTrue(source.contains("my assertComposeWindowOwner(_ourId, _t, true)"))
        XCTAssertTrue(source.contains("no window was discarded"))
        let dispatch = try XCTUnwrap(source.range(of: "keystroke \"s\" using command down"))
        let beforeDispatch = source[..<dispatch.lowerBound]
        let lastGuard = try XCTUnwrap(beforeDispatch.range(of: "my assertComposeWindowOwner(_ourId, _t, true)", options: .backwards))
        XCTAssertTrue(beforeDispatch[lastGuard.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func test_full_send_and_draft_scripts_compile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, selection) in [ComposeSignatureSelection.mailDefault, .init(mode: .none), .init(mode: .named, name: "None")].enumerated() {
            let file = root.appendingPathComponent("script\(index).applescript")
            try script(selection, send: index == 2).write(to: file, atomically: true, encoding: .utf8)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = ["-o", root.appendingPathComponent("script\(index).scpt").path, file.path]
            let errors = Pipe(); process.standardError = errors
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    private func handler(_ name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "on \(name)("))
        let end = try XCTUnwrap(source.range(of: "end \(name)", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// The window reference is resolved, the popup is tied to our window by
    /// its unique title before every click, and the verification closes the
    /// menu without choosing an item again (#322 verify).
    func test_popup_is_tied_to_the_owned_window_and_verification_does_not_click() throws {
        let source = script(.init(mode: .named, name: "Professional"))
        XCTAssertTrue(source.contains("set _w to contents of _cand"))
        XCTAssertFalse(source.contains("set _w to _cand\n"))
        let opened = try handler("openedSignatureMenu", in: source)
        let ownerCheck = try XCTUnwrap(opened.range(of: "my signaturePopupOwnedBy(_popup, _expectedTitle)"))
        XCTAssertLessThan(ownerCheck.lowerBound, try XCTUnwrap(opened.range(of: "click _popup")).lowerBound)
        XCTAssertTrue(try handler("assertSignatureMenuOwner", in: source).contains("my signaturePopupOwnedBy(item 2 of _state"))
        let verify = try handler("verifySignatureMenuChoice", in: source)
        XCTAssertTrue(verify.contains("perform action \"AXCancel\" of _menu"))
        XCTAssertFalse(verify.contains("click menu item"))
    }

    /// The menu state is unknown only while checking for a foreign open menu
    /// (an AX error there keeps it unknown); a refusal after that check, before
    /// the click, leaves nothing to cancel (#322 verify).
    func test_menu_state_is_unknown_only_while_checking_for_a_foreign_menu() throws {
        let opened = try handler("openedSignatureMenu", in: script(.init(mode: .none)))
        let unknown = try XCTUnwrap(opened.range(of: "set my activeSignatureMenuState to {}"))
        let foreign = try XCTUnwrap(opened.range(of: "if exists menu 1 of _popup then error"))
        let cleared = try XCTUnwrap(opened.range(of: "set my activeSignatureMenuState to missing value"))
        let ownerAssert = try XCTUnwrap(opened.range(of: "my assertComposeWindowOwner("))
        XCTAssertLessThan(unknown.lowerBound, foreign.lowerBound)
        XCTAssertLessThan(foreign.lowerBound, cleared.lowerBound)
        XCTAssertLessThan(cleared.lowerBound, ownerAssert.lowerBound)
        XCTAssertEqual(opened.components(separatedBy: "set my activeSignatureMenuState to {}").count, 2)
    }

    /// A window that is ours but not frontmost is a focus error, which goes
    /// through cleanup; only a changed identity leaves the window open.
    func test_focus_loss_is_not_an_identity_change() throws {
        let source = script(.mailDefault)
        let owner = try handler("assertComposeWindowOwner", in: source)
        XCTAssertTrue(owner.contains("error \"COMPOSEFOCUS: original compose window is not frontmost\""))
        XCTAssertTrue(owner.contains("_expectedId, _expectedTitle, false)) then error \"COMPOSEIDENTITY:"))
        XCTAssertFalse(source.contains("starts with \"COMPOSEFOCUS:\""))
    }

    /// A popup value that is missing is no reading at all.
    func test_default_readback_treats_missing_value_as_unverified() {
        let source = script(.mailDefault)
        XCTAssertTrue(source.contains("set _signatureSelected to my signatureAXText(value of _signaturePopup)"))
        XCTAssertFalse(source.contains("set _signatureSelected to value of _signaturePopup as string\n                        set _signatureVerified"))
    }

    /// A caller-supplied name is escaped wherever it enters the script.
    func test_signature_name_is_escaped_in_every_script_position() {
        let name = "Quote \" and \\ back"
        let source = script(.init(mode: .named, name: name))
        let escaped = appleScriptEscape(name)
        XCTAssertNotEqual(escaped, name)
        XCTAssertFalse(source.contains("\"" + name + "\""))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "\"" + escaped + "\"").count - 1, 4)
    }

    func test_null_signature_means_absent_and_disclosure_keeps_slashes() throws {
        XCTAssertEqual(try ComposeSignatureSelection.parse(.null), .mailDefault)
        XCTAssertEqual(try ComposeSignatureSelection.parse(.object(["mode": .string("none"), "name": .null])), .init(mode: .none))
        XCTAssertEqual(try ComposeSignatureSelection.parse(nil), .mailDefault)
        let receipt = ComposeSignatureReceipt(mode: .named, selection: "Work/Home", selectionVerified: true, selectionApplied: true)
        XCTAssertTrue(receipt.disclosure.contains("\"Work/Home\""), receipt.disclosure)
    }
}
