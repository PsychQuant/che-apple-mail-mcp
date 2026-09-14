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
        XCTAssertFalse(source.contains("my openedSignatureMenu(_signaturePopup)"))
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
}
