import XCTest
import MCP
@testable import CheAppleMailMCP

/// #467 — `get_mail_log_events` runs at most two `log show` children at once
/// and stops a child when the client cancels the call.
final class LogReadGateTests: XCTestCase {

    private let now = Synthetic.base.addingTimeInterval(2606)

    /// Blocks inside `read` until released, so a test can hold a slot open.
    private final class HoldingSource: LogEventSource {
        private let lock = NSLock()
        private var count = 0
        let proceed = DispatchSemaphore(value: 0)
        var reads: Int { lock.lock(); defer { lock.unlock() }; return count }

        func read(_ request: LogReadRequest, onLine: (Data) -> Bool) -> LogReadEnd {
            lock.lock(); count += 1; lock.unlock()
            proceed.wait()
            return .exhausted(exitStatus: 0, stderrTail: "")
        }
    }

    /// Delivers a line every 10 ms until the handler stops it.
    private final class TickingSource: LogEventSource {
        func read(_ request: LogReadRequest, onLine: (Data) -> Bool) -> LogReadEnd {
            let giveUp = Date().addingTimeInterval(20)
            while Date() < giveUp {
                if !onLine(Data("{}".utf8)) { return .stoppedByHandler }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return .deadline
        }
    }

    private func call(source: LogEventSource, gate: LogReadGate) async throws -> [String: Any] {
        let text = try await MailLogTool.handle(arguments: [:], source: source, now: now,
                                                timeZone: Synthetic.taipei, gate: gate)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func waitUntil(_ condition: () -> Bool, seconds: TimeInterval = 5) async {
        let giveUp = Date().addingTimeInterval(seconds)
        while !condition(), Date() < giveUp { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    // MARK: - gate

    func testGateCountsSlots() {
        let gate = LogReadGate(limit: 2)
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertFalse(gate.tryAcquire())
        XCTAssertEqual(gate.active, 2)
        gate.release()
        XCTAssertTrue(gate.tryAcquire())
    }

    func testTheSharedGateAllowsTwoReads() {
        XCTAssertEqual(LogReadGate.shared.limit, 2)
    }

    func testAThirdCallIsRefusedAtOnceAndStartsNoRead() async throws {
        let gate = LogReadGate(limit: 2)
        let source = HoldingSource()
        let first = Task { try await self.call(source: source, gate: gate) }
        let second = Task { try await self.call(source: source, gate: gate) }
        await waitUntil { source.reads == 2 }
        XCTAssertEqual(source.reads, 2)

        let t0 = Date()
        let third = try await call(source: source, gate: gate)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1, "refused, not queued")
        XCTAssertEqual(third["status"] as? String, "unavailable")
        XCTAssertEqual(third["reason"] as? String, "busy")
        XCTAssertEqual(third["returned"] as? Int, 0)
        XCTAssertNotNil(third["window"], "the response keeps the shape of every other unavailable")
        XCTAssertTrue((third["notice"] as? String ?? "").contains("says nothing about whether the action happened"))
        XCTAssertFalse((third["notice"] as? String ?? "").contains("admin group"), "a busy reader is not a permissions problem")
        XCTAssertEqual(source.reads, 2, "the third call started no reader")

        source.proceed.signal(); source.proceed.signal()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(gate.active, 0)
        let after = try await call(source: FakeLogSource(), gate: gate)
        XCTAssertEqual(after["status"] as? String, "no_events_in_window", "the slots came back")
    }

    func testEveryWayARunEndsFreesTheSlot() async throws {
        let ends: [LogReadEnd] = [.spawnFailed("no"), .exhausted(exitStatus: 1, stderrTail: "x"),
                                  .exhausted(exitStatus: 0, stderrTail: ""), .deadline, .scanCap,
                                  .stoppedByHandler, .cancelled]
        for end in ends {
            let gate = LogReadGate(limit: 1)
            _ = try await call(source: FakeLogSource(end: end), gate: gate)
            XCTAssertEqual(gate.active, 0, "\(end) kept the slot")
        }
    }

    func testAnInvalidRequestTakesNoSlot() async {
        let gate = LogReadGate(limit: 1)
        do {
            _ = try await MailLogTool.handle(arguments: ["limit": .int(0)], source: FakeLogSource(), now: now,
                                             timeZone: Synthetic.taipei, gate: gate)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(gate.active, 0)
        }
    }

    // MARK: - cancellation

    func testCancellingTheTaskStopsTheReadAndFreesTheSlot() async throws {
        let gate = LogReadGate(limit: 1)
        let t0 = Date()
        let task = Task { try await self.call(source: TickingSource(), gate: gate) }
        await waitUntil { gate.active == 1 }
        task.cancel()
        let response = try await task.value
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
        XCTAssertEqual(response["status"] as? String, "unavailable")
        XCTAssertEqual(response["reason"] as? String, "cancelled")
        XCTAssertFalse((response["notice"] as? String ?? "").contains("admin group"),
                       "a cancelled read is not a permissions problem")
        XCTAssertEqual(gate.active, 0)
    }

    func testAnExtraReleaseDoesNotUnderflowOrCrash() {
        let gate = LogReadGate(limit: 1)
        gate.release()
        XCTAssertEqual(gate.active, 0)
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertFalse(gate.tryAcquire(), "the cap still holds")
    }

    func testASlotIsHeldUntilTheCancelledReadHasReturned() async throws {
        // Cancel only asks; the slot must not free while the read still runs.
        let gate = LogReadGate(limit: 1)
        let source = HoldingSource()
        let task = Task { try await self.call(source: source, gate: gate) }
        await waitUntil { source.reads == 1 }
        task.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(gate.active, 1, "the child has not gone yet")
        source.proceed.signal()
        _ = try await task.value
        XCTAssertEqual(gate.active, 0)
    }

    func testACallAlreadyCancelledStartsNoRead() async throws {
        let gate = LogReadGate(limit: 1)
        let source = FakeLogSource(lines: [Synthetic.line(offset: 2300)])
        let task = Task { () throws -> [String: Any] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.call(source: source, gate: gate)
        }
        let response = try await task.value
        XCTAssertEqual(response["reason"] as? String, "cancelled")
        XCTAssertEqual(source.delivered, 0)
        XCTAssertEqual(gate.active, 0)
    }

    // MARK: - the real subprocess path

    private func request() -> LogReadRequest {
        LogReadRequest(start: Date(timeIntervalSince1970: 1790916146),
                       end: Date(timeIntervalSince1970: 1790916206), categories: [])
    }

    private func isRunning(_ marker: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", marker]
        p.standardOutput = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func testCancelStopsASilentChildAndReapsIt() {
        // The child writes nothing, so nothing but the poll loop can notice.
        let marker = "idd467-silent-\(UUID().uuidString)"
        let runner = LogShowRunner(executableURL: URL(fileURLWithPath: "/bin/sh"), deadline: 25,
                                   makeArguments: { _ in ["-c", "# \(marker)\nwhile true; do sleep 1; done"] })
        let cancellation = LogReadCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellation.cancel() }
        let t0 = Date()
        let end = runner.read(request(), cancellation: cancellation) { _ in true }
        XCTAssertEqual(end, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5, "well before the 25 s deadline")
        let giveUp = Date().addingTimeInterval(3)
        while isRunning(marker), Date() < giveUp { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertFalse(isRunning(marker), "the child must be gone, not abandoned")
    }

    func testARunnerAlreadyCancelledSpawnsNothing() {
        // A missing executable would report spawnFailed if it tried.
        let runner = LogShowRunner(executableURL: URL(fileURLWithPath: "/nonexistent/not-here"),
                                   makeArguments: { _ in [] })
        let cancellation = LogReadCancellation()
        cancellation.cancel()
        XCTAssertEqual(runner.read(request(), cancellation: cancellation) { _ in true }, .cancelled)
    }

    func testTheDefaultImplementationStopsAtTheNextLine() {
        let source = FakeLogSource()
        source.endless = { _ in Data("{}".utf8) }
        let cancellation = LogReadCancellation()
        var seen = 0
        let end = source.read(request(), cancellation: cancellation) { _ in
            seen += 1
            if seen == 3 { cancellation.cancel() }
            return true
        }
        XCTAssertEqual(end, .cancelled)
        XCTAssertEqual(seen, 3)
    }

    func testDescriptionStatesTheCap() {
        XCTAssertTrue((MailLogTool.definition.description ?? "").contains("busy"))
    }
}
