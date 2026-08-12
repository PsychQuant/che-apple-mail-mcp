import Foundation
import Logging
import MCP

/// #349-B — stop executing once nobody can hear the answers.
///
/// #320 installed `signal(SIGPIPE, SIG_IGN)` because the default disposition
/// killed the server at the first write to a broken pipe. That was the right
/// call, but it created an execution mode nobody had chosen: with the signal
/// ignored, a stdout write returns `EPIPE`, the SDK's per-request task swallows
/// it (`_ = try? await self.handleRequest(request, sendResponse: true)`), and
/// the transport does not disconnect. Subsequent requests keep **executing** —
/// `compose_email`, `delete_email`, `move_email` included — while every
/// response vanishes. A host that reconnects and retries then repeats side
/// effects that already happened, with nothing in the protocol to reveal it.
///
/// So a stdout write failure is treated as what it is: the end of the session.
/// The failure is reported on stderr (a different fd, which may well still be
/// open) and the server is stopped, so no further tool call is dispatched.
///
/// Reading stops too, by consequence: `Server.stop()` ends the receive loop.
/// An in-flight call is not interrupted — cancelling mid-mutation would be a
/// worse failure than the one being fixed. The guarantee is narrow and precise:
/// no NEW work is started after the transport has proven unable to answer.
actor ShutdownOnWriteFailureTransport: Transport {

    nonisolated let logger: Logger
    private let wrapped: any Transport
    private var upstream: AsyncThrowingStream<Data, Swift.Error>?
    private var onWriteFailure: (@Sendable () async -> Void)?
    private var alreadyFailed = false

    init(wrapping wrapped: any Transport, logger: Logger) {
        self.wrapped = wrapped
        self.logger = logger
    }

    /// Set by `run()` once the `Server` exists — the transport is constructed
    /// first, so the callback cannot be an init parameter.
    func setOnWriteFailure(_ handler: @escaping @Sendable () async -> Void) {
        self.onWriteFailure = handler
    }

    func connect() async throws {
        try await wrapped.connect()
        // `receive()` is a synchronous protocol requirement, and `wrapped` is a
        // separate actor — so the stream has to be obtained here, in async
        // context, and handed out later.
        upstream = await wrapped.receive()
    }

    func disconnect() async {
        await wrapped.disconnect()
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        upstream ?? AsyncThrowingStream { $0.finish() }
    }

    func send(_ data: Data) async throws {
        do {
            try await wrapped.send(data)
        } catch {
            // Report once: a broken stdout usually breaks for every subsequent
            // write too, and a flood of identical lines would bury the first.
            if !alreadyFailed {
                alreadyFailed = true
                Diagnostics.emit(
                    "che-apple-mail-mcp: stdout write failed (\(error)) — the client is no "
                    + "longer reading responses. Shutting down rather than continuing to "
                    + "execute tool calls whose results nobody will receive (#349); a host "
                    + "that reconnects and retries would otherwise repeat side effects that "
                    + "already happened.\n")
                let handler = onWriteFailure
                Task { await handler?() }
            }
            throw error
        }
    }
}
