import Darwin
import XCTest
@testable import CheAppleMailMCP

final class ClassificationTrashScriptTests: XCTestCase {
    private func message() -> ClassificationMessage {
        let source = "Message-ID: <a@example.invalid>\nFrom: sender@example.invalid\nSubject: 主旨\nList-Id: News <news.example.invalid>\n\nprivate body"
        return .init(id: "12", accountID: "ACCOUNT-UUID", mailboxComponents: ["[Gmail]", "INBOX"],
              mailboxURL: "imap://ACCOUNT-UUID/%5BGmail%5D/INBOX", messageID: "<a@example.invalid>",
              sender: "sender@example.invalid", subject: "主旨", listID: "News <news.example.invalid>",
              isDraft: false, isFlagged: false, contentDigest: classificationDigest(Data(source.utf8)), nativeSource: source)
    }
    private func directory() -> URL {
        let pointer = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func test_native_script_compiles_and_guards_before_move_without_delete() throws {
        let script = try buildClassificationTrashScript(message())
        let move = try XCTUnwrap(script.range(of: "move msg to trashBox"))
        for text in ["nativeMID", "flagged status", "classifierListID(source", "trashCount is not 1", "draftMatches", "get container of checkedBox"] {
            XCTAssertLessThan(try XCTUnwrap(script.range(of: text)).lowerBound, move.lowerBound)
        }
        XCTAssertTrue(script.contains("nativeMID is not \"<a@example.invalid>\" and nativeMID is not \"a@example.invalid\""))
        XCTAssertNil(script.range(of: #"\bdelete\b|\bempty\b"#, options: .regularExpression))
        let root = directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("guard.applescript")
        try script.write(to: source, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", root.appendingPathComponent("guard.scpt").path, source.path]
        let errors = Pipe(); process.standardError = errors
        try process.run(); process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, message)
    }

    func test_malformed_identity_refuses_and_quoted_inputs_stay_literals() throws {
        var msg = message(); msg.id = "12 or id is 13"
        XCTAssertThrowsError(try buildClassificationTrashScript(msg))
        msg = message(); msg.subject = "quoted \"subject\""
        let script = try buildClassificationTrashScript(msg)
        XCTAssertTrue(script.contains("quoted \\\"subject\\\""))
    }

    func test_native_list_id_parser_executes_only_foundation_on_synthetic_headers() throws {
        let complete = try buildClassificationTrashScript(message())
        let boundary = try XCTUnwrap(complete.range(of: "\ntell application \"Mail\""))
        let handlers = String(complete[..<boundary.lowerBound])
        let fixtures = [
            ("List-Id: News <NEWS.EXAMPLE.INVALID>\r\nSubject: title\r\n\r\nbody", "news.example.invalid"),
            ("List-Id: News\n <news.example.invalid>\n\nbody", "news.example.invalid"),
            ("Subject: title\n\nList-Id: body.example.invalid", ""),
            ("List-Id: first.example.invalid\nList-Id: second.example.invalid\n\nbody", "missing value"),
            ("List-Id: News <news.example.invalid> trailing\n\nbody", "missing value")
        ]
        for (source, expected) in fixtures {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", handlers + "\nreturn my classifierListID(\"" + appleScriptEscape(source) + "\")"]
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output; process.standardError = errors
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
    }

    func test_native_whole_source_guard_compares_normalized_bytes() throws {
        let script = try buildClassificationTrashScript(message())
        let boundary = try XCTUnwrap(script.range(of: "\ntell application \"Mail\""))
        let handlers = String(script[..<boundary.lowerBound])
        let expected = "Message-ID: <a@example.invalid>\n\nbody A"
        for (actual, matches) in [(expected, "true"), (expected.replacingOccurrences(of: "\n", with: "\r\n"), "true"),
                                  ("Message-ID: <a@example.invalid>\n\nbody B", "false")] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", handlers + "\nreturn my classifierSourceEquals(\"" + appleScriptEscape(actual) + "\", \"" + Data(expected.utf8).base64EncodedString() + "\")"]
            let output = Pipe(); process.standardOutput = output
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), matches)
        }
        let check = try XCTUnwrap(script.range(of: "if not (my classifierSourceEquals(source of msg"))
        let move = try XCTUnwrap(script.range(of: "move msg to trashBox"))
        XCTAssertLessThan(check.lowerBound, move.lowerBound)
        var changed = message(); changed.nativeSource = "different source"
        XCTAssertThrowsError(try buildClassificationTrashScript(changed))
    }

    func test_expired_native_guard_returns_before_mail_block() throws {
        let script = try buildClassificationTrashScript(message(), deadline: Date(timeIntervalSince1970: 1))
        let boundary = try XCTUnwrap(script.range(of: "\ntell application \"Mail\""))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", String(script[..<boundary.lowerBound]) + "\nreturn \"should not run\""]
        let output = Pipe(); process.standardOutput = output
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "CLASSIFY_REFUSED")
    }

    func test_controller_uses_guarded_non_gui_path_and_strict_receipt() async throws {
        let controller = MailController.shared
        let store = ClassificationPolicyStore(directory: directory())
        let policy = try store.configure(.empty)
        let digest = try policy.fingerprint()
        let msg = message()
        await controller.setTestSeams(scriptRunner: { script in
            XCTAssertTrue(script.contains("move msg to trashBox"))
            XCTAssertFalse(script.contains("System Events"))
            return "CLASSIFY_MOVED"
        }, refusal: nil)
        do {
            let receipt = try await controller.moveClassifiedMessage(msg, policyDigest: digest,
                deadline: Date().addingTimeInterval(30), store: store)
            XCTAssertEqual(receipt, .moved)
            await controller.setTestSeams(scriptRunner: { _ in XCTFail("stale policy must not invoke script"); return "CLASSIFY_MOVED" }, refusal: nil)
            let stale = try await controller.moveClassifiedMessage(msg, policyDigest: "stale",
                deadline: Date().addingTimeInterval(30), store: store)
            XCTAssertEqual(stale, .refused)
            await controller.setTestSeams(scriptRunner: { _ in "arbitrary output" }, refusal: nil)
            do {
                _ = try await controller.moveClassifiedMessage(msg, policyDigest: digest,
                    deadline: Date().addingTimeInterval(30), store: store)
                XCTFail("unknown output is not a success receipt")
            } catch {}
            await controller.setTestSeams(scriptRunner: nil, refusal: nil)
        } catch {
            await controller.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
    }
}
