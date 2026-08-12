import XCTest
import Logging
import MCP
@testable import CheAppleMailMCP

/// #349-B — `SIG_IGN` (#320) created an execution mode nobody chose.
///
/// Before #320 a host that closed its stdout read end killed the server at the
/// first response. After it, the write returns `EPIPE`, the SDK's per-request
/// task swallows it — `_ = try? await self.handleRequest(request,
/// sendResponse: true)` in `Server.swift:236` of the pinned swift-sdk — and the
/// transport stays connected. Every later request still EXECUTES, including
/// `compose_email` / `delete_email` / `move_email`; only the responses vanish.
/// A host that reconnects and retries repeats side effects that already
/// happened, and nothing in the protocol reveals it.
///
/// This is not an argument against #320; dying on a broken pipe was worse. It
/// is the unowned consequence of it, now owned: a write failure means nobody
/// can hear the answers, so the session ends.
final class ShutdownOnWriteFailureTransportTests: XCTestCase {

    /// A transport whose `send` always fails, standing in for a closed stdout.
    private actor FailingTransport: Transport {
        nonisolated let logger = Logger(label: "test")
        private(set) var sendAttempts = 0
        struct Broken: Error {}
        func connect() async throws {}
        func disconnect() async {}
        func send(_ data: Data) async throws { sendAttempts += 1; throw Broken() }
        func receive() -> AsyncThrowingStream<Data, Swift.Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func attempts() -> Int { sendAttempts }
    }

    private actor ShutdownSpy {
        private(set) var count = 0
        func record() { count += 1 }
        func value() -> Int { count }
    }

    func testWriteFailureTriggersShutdown() async throws {
        let spy = ShutdownSpy()
        let t = ShutdownOnWriteFailureTransport(wrapping: FailingTransport(),
                                                logger: Logger(label: "test"))
        await t.setOnWriteFailure { await spy.record() }

        do {
            try await t.send(Data("{}".utf8))
            XCTFail("the write failure must propagate, not be swallowed here")
        } catch {
            // expected — the SDK still gets its error; we only add the shutdown
        }

        // The handler is dispatched in a Task; give it a turn to run.
        try await Task.sleep(nanoseconds: 200_000_000)
        let fired = await spy.value()
        XCTAssertEqual(fired, 1,
            "a failed stdout write must stop the server — otherwise the loop keeps "
            + "executing mutations whose responses nobody receives (#349-B)")
    }

    func testShutdownIsRequestedOnlyOnceAcrossRepeatedFailures() async throws {
        let spy = ShutdownSpy()
        let t = ShutdownOnWriteFailureTransport(wrapping: FailingTransport(),
                                                logger: Logger(label: "test"))
        await t.setOnWriteFailure { await spy.record() }

        for _ in 0..<5 { _ = try? await t.send(Data("{}".utf8)) }
        try await Task.sleep(nanoseconds: 200_000_000)

        let fired = await spy.value()
        XCTAssertEqual(fired, 1,
            "a broken stdout breaks for every subsequent write too; one shutdown "
            + "request and one stderr line, not a flood")
    }

    func testSuccessfulWritesNeverTriggerShutdown() async throws {
        /// Succeeds, so the decorator must stay out of the way.
        actor OKTransport: Transport {
            nonisolated let logger = Logger(label: "test")
            private(set) var sent: [Data] = []
            func connect() async throws {}
            func disconnect() async {}
            func send(_ data: Data) async throws { sent.append(data) }
            func receive() -> AsyncThrowingStream<Data, Swift.Error> {
                AsyncThrowingStream { $0.finish() }
            }
            func count() -> Int { sent.count }
        }
        let inner = OKTransport()
        let spy = ShutdownSpy()
        let t = ShutdownOnWriteFailureTransport(wrapping: inner, logger: Logger(label: "test"))
        await t.setOnWriteFailure { await spy.record() }

        try await t.send(Data("a".utf8))
        try await t.send(Data("b".utf8))
        try await Task.sleep(nanoseconds: 100_000_000)

        let forwarded = await inner.count()
        let fired = await spy.value()
        XCTAssertEqual(forwarded, 2, "payloads must pass through untouched")
        XCTAssertEqual(fired, 0)
    }
}
