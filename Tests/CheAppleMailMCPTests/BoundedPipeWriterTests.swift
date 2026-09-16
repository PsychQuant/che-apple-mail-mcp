import Darwin
import XCTest
@testable import CheAppleMailMCP

final class BoundedPipeWriterTests: XCTestCase {
    func test_large_input_times_out_when_reader_never_drains() throws {
        let pipe = Pipe()
        let before = Date()
        XCTAssertThrowsError(try BoundedPipeWriter.write(Data(repeating: 65, count: 8 * 1024 * 1024),
            to: pipe.fileHandleForWriting.fileDescriptor, deadline: .now() + 0.1)) { error in
                guard case BoundedPipeWriteError.timedOut = error else { return XCTFail("wrong error: \(error)") }
            }
        XCTAssertLessThan(Date().timeIntervalSince(before), 1)
    }
    func test_closed_reader_returns_error_without_sigpipe_termination() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        XCTAssertThrowsError(try BoundedPipeWriter.write(Data("input".utf8),
            to: pipe.fileHandleForWriting.fileDescriptor, deadline: .now() + 1)) { error in
                guard case BoundedPipeWriteError.posix(let code) = error else { return XCTFail("wrong error") }
                XCTAssertEqual(code, EPIPE)
            }
    }
    func test_normal_write_preserves_bytes_and_cancellation_is_checked() throws {
        let pipe = Pipe()
        let bytes = Data("中文 + input".utf8)
        try BoundedPipeWriter.write(bytes, to: pipe.fileHandleForWriting.fileDescriptor, deadline: .now() + 1)
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(try pipe.fileHandleForReading.readToEnd(), bytes)
        let cancelledPipe = Pipe()
        XCTAssertThrowsError(try BoundedPipeWriter.write(bytes, to: cancelledPipe.fileHandleForWriting.fileDescriptor,
            deadline: .now() + 1, cancelled: { true })) { error in
                guard case BoundedPipeWriteError.cancelled = error else { return XCTFail("wrong error") }
            }
    }
    func test_real_runner_terminates_child_that_never_reads_large_stdin() async throws {
        let pointer = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(pointer) }
        let directory = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let controller = MailController.shared
        await controller.setTestSeams(scriptRunner: nil, refusal: nil, automationGranted: true,
            subprocessCommand: (URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "sh", pidFile.path]))
        let start = Date()
        do {
            _ = try await controller.runDraftScanScript(String(repeating: "x", count: 8 * 1024 * 1024), timeout: 0.2)
            XCTFail("unread stdin should time out")
        } catch {}
        await controller.setTestSeams(scriptRunner: nil, refusal: nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "timed-out child must have exited")
        XCTAssertEqual(errno, ESRCH)
    }

}
