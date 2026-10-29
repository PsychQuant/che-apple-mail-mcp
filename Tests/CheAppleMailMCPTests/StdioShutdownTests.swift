import XCTest
import Foundation
@testable import CheAppleMailMCP

/// Link the actual app objects into an async-main probe. Only its database path
/// and existing script runner seam differ from production; SDK/stdio are real.
final class StdioShutdownTests: XCTestCase {
    private static var probeDirectory: URL?

    override class func tearDown() {
        if let directory = probeDirectory { try? FileManager.default.removeItem(at: directory) }
        probeDirectory = nil
        super.tearDown()
    }

    private struct LinkInputs {
        let objects: [String], compiler: String, target: String, sdk: String, modules: String
    }

    /// The app's object files (minus its `main`) and the compiler that built them,
    /// for both build layouts SwiftPM has used here. Neither found is an error,
    /// never a skip: a probe that silently stops running proves nothing.
    private static func linkInputs(products: URL) throws -> LinkInputs {
        let fm = FileManager.default
        let native = products.appendingPathComponent("CheAppleMailMCP.product/Objects.LinkFileList")
        if fm.fileExists(atPath: native.path) {
            // Native build system: newline-separated list; compiler and SDK from
            // description.json, the exact ones that produced these modules
            // (xcrun can select a different installed toolchain, e.g. 6.3 vs 6.2).
            let all = try String(contentsOf: native).split(separator: "\n").map(String.init)
            let objects = all.filter { !$0.contains("CheAppleMailMCP.build/main.swift.o") }
            XCTAssertEqual(all.count - objects.count, 1, "exactly one main object is dropped")
            let descriptionData = try Data(contentsOf: products.appendingPathComponent("description.json"))
            let description = try XCTUnwrap(try JSONSerialization.jsonObject(with: descriptionData) as? [String: Any])
            let commands = try XCTUnwrap(description["swiftCommands"] as? [String: [String: Any]])
            let command = try XCTUnwrap(commands.values.first { $0["moduleName"] as? String == "CheAppleMailMCP" })
            let arguments = try XCTUnwrap(command["otherArguments"] as? [String])
            let targetIndex = try XCTUnwrap(arguments.firstIndex(of: "-target"))
            let sdkIndex = try XCTUnwrap(arguments.firstIndex(of: "-sdk"))
            return LinkInputs(objects: objects, compiler: try XCTUnwrap(command["executable"] as? String),
                              target: arguments[targetIndex + 1], sdk: arguments[sdkIndex + 1],
                              modules: products.appendingPathComponent("Modules").path)
        }
        // Swift Build: Products/<config> sits next to Intermediates.noindex. The
        // testable variant's list holds the app objects (the probe uses
        // @testable import); the dependency objects come from the plain
        // executable's list, which links them out of Products/<config>.
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let build = products.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Intermediates.noindex/CheAppleMailMCP.build")
            .appendingPathComponent(products.lastPathComponent)
        func words(_ url: URL) throws -> [String] {
            try String(contentsOf: url).split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        }
        let testableDir = try XCTUnwrap(try fm.contentsOfDirectory(atPath: build.path)
            .first { $0.hasPrefix("CheAppleMailMCP--") && $0.hasSuffix("-testable-t.build") },
            "no testable build of CheAppleMailMCP under \(build.path)")
        let objectsDir = build.appendingPathComponent(testableDir).appendingPathComponent("Objects-normal/\(arch)")
        let listName = try XCTUnwrap(try fm.contentsOfDirectory(atPath: objectsDir.path)
            .first { $0.hasSuffix(".LinkFileList") }, "no link list in \(objectsDir.path)")
        let app = try words(objectsDir.appendingPathComponent(listName))
        let objects = app.filter { !$0.hasSuffix("/main.o") }
        XCTAssertEqual(app.count - objects.count, 1, "exactly one main object is dropped")
        let plain = build.appendingPathComponent("CheAppleMailMCP-p.build/Objects-normal/\(arch)/CheAppleMailMCP.LinkFileList")
        let dependencies = try words(plain).filter { $0.hasPrefix(products.path + "/") }
        XCTAssertFalse(dependencies.isEmpty, "the executable links its dependencies from \(products.path)")
        func xcrun(_ arguments: [String]) throws -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, !out.isEmpty else {
                throw NSError(domain: "StdioShutdownProbe", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "xcrun \(arguments.joined(separator: " ")) failed"])
            }
            return out
        }
        // No description.json here: a toolchain mismatch shows up as a module
        // import error in compiler.log, which fails the test with that text.
        return LinkInputs(objects: objects + dependencies, compiler: try xcrun(["--find", "swiftc"]),
                          target: "\(arch)-apple-macos13.0", sdk: try xcrun(["--show-sdk-path"]),
                          modules: products.path)
    }

    private func probe() throws -> URL {
        if let directory = Self.probeDirectory { return directory.appendingPathComponent("probe") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stdio329-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            let inputs = try Self.linkInputs(products: products)
            let objectsURL = directory.appendingPathComponent("Objects.LinkFileList")
            try (inputs.objects.joined(separator: "\n") + "\n").write(to: objectsURL, atomically: true, encoding: .utf8)
            let source = directory.appendingPathComponent("Probe.swift")
            try #"""
            import Foundation
            @testable import CheAppleMailMCP

            @main enum Probe {
                static func main() async throws {
                    let blocked = CommandLine.arguments[1] == "blocked"
                    await MailController.shared.setTestSeams(scriptRunner: { _ in
                        FileHandle.standardError.write(Data("PROBE_SYNC_BEGIN\n".utf8))
                        if blocked { Thread.sleep(forTimeInterval: 6) }
                        FileHandle.standardError.write(Data("PROBE_SYNC_END\n".utf8))
                        return "fixture"
                    }, refusal: { nil })
                    let server = try await CheAppleMailMCPServer(databasePath: CommandLine.arguments[2])
                    try await server.run()
                    FileHandle.standardError.write(Data("PROBE_SERVER_RETURNED\n".utf8))
                }
            }
            """#.write(to: source, atomically: true, encoding: .utf8)
            let compilerLog = directory.appendingPathComponent("compiler.log")
            FileManager.default.createFile(atPath: compilerLog.path, contents: nil)
            let output = try FileHandle(forWritingTo: compilerLog)
            defer { try? output.close() }
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: inputs.compiler)
            compiler.arguments = ["-parse-as-library", "-target", inputs.target, "-sdk", inputs.sdk,
                                  "-I", inputs.modules, source.path,
                                  "@" + objectsURL.path, "-lsqlite3", "-o", directory.appendingPathComponent("probe").path]
            compiler.standardOutput = output
            compiler.standardError = output
            try compiler.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while compiler.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if compiler.isRunning { kill(compiler.processIdentifier, SIGKILL) }
            compiler.waitUntilExit()
            guard compiler.terminationStatus == 0 else {
                throw NSError(domain: "StdioShutdownProbe", code: Int(compiler.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: try String(contentsOf: compilerLog)])
            }
            Self.probeDirectory = directory
            return directory.appendingPathComponent("probe")
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func exercise(blocked: Bool, strict: Bool, handshake: Bool = false) throws {
        let executable = try probe()
        let directory = executable.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stderrURL = directory.appendingPathComponent("stderr"), stdoutURL = directory.appendingPathComponent("stdout")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        let stderr = try FileHandle(forWritingTo: stderrURL), stdout = try FileHandle(forWritingTo: stdoutURL)
        defer { try? stderr.close(); try? stdout.close() }
        let process = Process(), stdin = Pipe()
        process.executableURL = executable
        process.arguments = [blocked ? "blocked" : "idle", directory.appendingPathComponent("absent-index").path]
        var environment = ProcessInfo.processInfo.environment
        if strict { environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] = "1" }
        else { environment.removeValue(forKey: "LIBDISPATCH_COOPERATIVE_POOL_STRICT") }
        process.environment = environment
        process.standardInput = stdin
        process.standardError = stderr
        process.standardOutput = stdout
        try process.run()
        defer {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < readyDeadline {
            if (try String(contentsOf: stderrURL)).contains("PROBE_SYNC_BEGIN") { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let ready = try String(contentsOf: stderrURL)
        XCTAssertTrue(ready.contains("PROBE_SYNC_BEGIN"), "startup fixture never began: \(ready)")
        if blocked { XCTAssertFalse(ready.contains("PROBE_SYNC_END")) }
        if handshake {
            let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fixture","version":"1"}}}"# + "\n"
            try stdin.fileHandleForWriting.write(contentsOf: Data(request.utf8))
            let responseDeadline = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < responseDeadline {
                if (try Data(contentsOf: stdoutURL)).contains(0x0a) { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            let response = try Data(contentsOf: stdoutURL)
            let newline = try XCTUnwrap(response.firstIndex(of: 0x0a), "initialize did not produce a complete JSON-RPC frame")
            let object = try JSONSerialization.jsonObject(with: Data(response[..<newline])) as? [String: Any]
            XCTAssertEqual(object?["jsonrpc"] as? String, "2.0")
            XCTAssertEqual(object?["id"] as? Int, 1)
            XCTAssertNil(object?["error"])
            XCTAssertNotNil(object?["result"])
            XCTAssertFalse((try String(contentsOf: stderrURL)).contains("PROBE_SYNC_END"),
                           "handshake must not wait for the six-second script")
        }
        let eof = ProcessInfo.processInfo.systemUptime
        try stdin.fileHandleForWriting.close()
        while process.isRunning && ProcessInfo.processInfo.systemUptime - eof < 2 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let finalTrace = try String(contentsOf: stderrURL)
        XCTAssertFalse(process.isRunning, "EOF waited on Mail work: \(finalTrace)")
        if !process.isRunning {
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, 0)
            let trace = try String(contentsOf: stderrURL)
            XCTAssertTrue(trace.contains("PROBE_SERVER_RETURNED"))
            if blocked { XCTAssertFalse(trace.contains("PROBE_SYNC_END"), "must exit before startup work finishes") }
        }
    }

    func testEOFWithBlockedStartupAndStrictCooperativePool() throws {
        try exercise(blocked: true, strict: true)
    }

    func testHandshakeWithBlockedStartupAndStrictCooperativePool() throws {
        try exercise(blocked: true, strict: true, handshake: true)
    }

    func testEOFWithBlockedStartupAndOrdinaryPool() throws {
        try exercise(blocked: true, strict: false)
    }

    func testEOFWithIdleStartup() throws {
        try exercise(blocked: false, strict: true)
    }

    func testMailActorStillSerializesConcurrentCalls() async throws {
        let recorder = ScriptConcurrencyRecorder()
        await MailController.shared.setTestSeams(scriptRunner: { _ in
            recorder.enter()
            defer { recorder.leave() }
            Thread.sleep(forTimeInterval: 0.005)
            return "fixture"
        }, refusal: { nil })
        do {
            try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<12 { group.addTask { try await MailController.shared.checkForNewMail() } }
                for try await response in group { XCTAssertEqual(response, "fixture") }
            }
        } catch {
            await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        XCTAssertEqual(recorder.summary().calls, 12)
        XCTAssertEqual(recorder.summary().maximum, 1)
    }
}

private final class ScriptConcurrencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0, maximum = 0, calls = 0
    func enter() { lock.lock(); defer { lock.unlock() }; active += 1; calls += 1; maximum = max(maximum, active) }
    func leave() { lock.lock(); defer { lock.unlock() }; active -= 1 }
    func summary() -> (calls: Int, maximum: Int) {
        lock.lock(); defer { lock.unlock() }; return (calls, maximum)
    }
}
