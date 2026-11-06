import Darwin
import XCTest

extension XCTestCase {
    /// Runs `body` with fd 2 pointed at a file and returns what landed there. A
    /// file, not a pipe, so a chatty server cannot fill a buffer and hang the test.
    func capturingStderr(during body: () async throws -> Void) async throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stderr-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let saved = dup(STDERR_FILENO)
        guard saved >= 0 else { throw NSError(domain: "StderrCapture", code: 1) }
        defer { close(saved) }
        let sink = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard sink >= 0 else { throw NSError(domain: "StderrCapture", code: 2) }
        let redirected = dup2(sink, STDERR_FILENO)
        close(sink)
        guard redirected == STDERR_FILENO else { throw NSError(domain: "StderrCapture", code: 3) }
        var failure: Error?
        do { try await body() } catch { failure = error }
        XCTAssertEqual(dup2(saved, STDERR_FILENO), STDERR_FILENO, "fd 2 was not restored")
        if let failure { throw failure }
        return try String(contentsOf: file, encoding: .utf8)
    }
}
