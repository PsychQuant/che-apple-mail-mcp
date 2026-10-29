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
            XCTAssertEqual(stale, .notDispatched, "a policy change is found before anything reaches osascript")
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

    /// Every check before the move sits in one try that answers REFUSED, and
    /// each role-loop account lookup has its own try; the move itself is
    /// outside any try (#356 verify).
    func test_read_only_checks_refuse_on_error_and_the_move_is_outside_try() throws {
        let lines = try buildClassificationTrashScript(message()).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("--") }
        var stack: [String] = []
        var accountLookups = 0, sawMove = false
        for (index, line) in lines.enumerated() {
            if line.contains("account of") {
                accountLookups += 1
                XCTAssertEqual(stack.last, "try", "account lookup outside its own try: \(line)")
            }
            if line == "move msg to trashBox" {
                sawMove = true
                XCTAssertFalse(stack.contains("try"), "the move must not be inside a try")
            }
            if line == "on error" {
                // Either refuse at once, or (the Trash role loop) mark the
                // destination unknown, which refuses after the loop.
                XCTAssertTrue(["return \"CLASSIFY_REFUSED\"", "set trashUnreadable to true"].contains(lines[index + 1]), lines[index + 1])
            }
            if line.hasPrefix("end ") {
                _ = stack.popLast()
            } else if line == "try" {
                stack.append("try")
            } else if line.hasPrefix("tell ") || line.hasPrefix("repeat") || line.hasPrefix("considering")
                        || (line.hasPrefix("on ") && line != "on error") || (line.hasPrefix("if ") && line.hasSuffix(" then")) {
                stack.append(String(line.prefix(while: { $0 != " " })))
            }
            if line == "tell application \"Mail\"" { XCTAssertEqual(lines[index + 1], "try") }
        }
        XCTAssertTrue(sawMove)
        XCTAssertEqual(accountLookups, 2)
        XCTAssertTrue(lines.contains("if draftAccount is missing value or draftAccount is \"ACCOUNT-UUID\" then"),
                      "a drafts box whose account cannot be read is still checked")
        // A Trash child whose account cannot be read makes the destination
        // ambiguous: refuse rather than count only the readable one.
        XCTAssertTrue(lines.contains("set trashUnreadable to true"))
        XCTAssertTrue(lines.contains("if trashUnreadable or trashCount is not 1 then return \"CLASSIFY_REFUSED\""))
        XCTAssertTrue(stack.isEmpty)
    }

    /// Through the real runner: a child that never reads the script is not a
    /// dispatch, a child that read it and failed is, and a receipt is parsed.
    func test_real_runner_separates_undelivered_from_unknown() async throws {
        let root = directory()
        let store = ClassificationPolicyStore(directory: root)
        let digest = try store.load().fingerprint()
        var big = message()
        let source = "Message-ID: <a@example.invalid>\nFrom: sender@example.invalid\nSubject: 主旨\nList-Id: News <news.example.invalid>\n\n"
            + String(repeating: "x", count: 1 << 20)
        big.nativeSource = source
        big.contentDigest = classificationDigest(Data(source.utf8))
        let controller = MailController.shared
        addTeardownBlock { await controller.setTestSeams(scriptRunner: nil, refusal: nil) }
        func run(_ shell: String, _ msg: ClassificationMessage) async throws -> ClassificationMoveReceipt {
            await controller.setTestSeams(scriptRunner: nil, refusal: nil, scriptTimeout: 1, automationGranted: true,
                                          subprocessCommand: (URL(fileURLWithPath: "/bin/sh"), ["-c", shell]))
            return try await controller.moveClassifiedMessage(msg, policyDigest: digest, deadline: Date().addingTimeInterval(60), store: store)
        }
        let undelivered = try await run("exec /bin/sleep 30", big)
        XCTAssertEqual(undelivered, .notDispatched)
        do {
            _ = try await run("cat >/dev/null; exit 3", message())
            XCTFail("a script that was delivered and failed has an unknown outcome")
        } catch {}
        let moved = try await run("cat >/dev/null; echo CLASSIFY_MOVED", message())
        XCTAssertEqual(moved, .moved)
        let stale = try await controller.moveClassifiedMessage(message(), policyDigest: "other", deadline: Date().addingTimeInterval(60), store: store)
        XCTAssertEqual(stale, .notDispatched, "a policy change is found before anything reaches osascript")
        await controller.setTestSeams(scriptRunner: nil, refusal: nil)
    }

    /// The script's own deadline is at most two seconds before the subprocess
    /// timeout, so it refuses before its move rather than being killed during
    /// it; and the move builds its script with that deadline (#356 verify).
    func test_script_deadline_precedes_the_subprocess_kill() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let far = now.addingTimeInterval(50), near = now.addingTimeInterval(5)
        XCTAssertEqual(ClassificationPlanEngine.nativeScriptDeadline(batchDeadline: far, now: now),
                       now.addingTimeInterval(ClassificationPlanEngine.nativeItemTimeout - 2))
        XCTAssertEqual(ClassificationPlanEngine.nativeScriptDeadline(batchDeadline: near, now: now), near)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift"), encoding: .utf8)
        let move = try XCTUnwrap(source.range(of: "func moveClassifiedMessage("))
        XCTAssertTrue(source[move.lowerBound...].prefix(1500)
            .contains("deadline: ClassificationPlanEngine.nativeScriptDeadline(batchDeadline: deadline, now: Date())"))
    }
}
