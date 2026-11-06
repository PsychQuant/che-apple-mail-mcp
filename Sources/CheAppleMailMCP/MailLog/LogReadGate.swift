import Foundation

/// #467 — how many `log show` children may run at once.
///
/// One child costs 237–350 MB, and a client that retries in a loop could start
/// one per call, each living to its 30-second deadline. A call past the cap is
/// refused at once instead of queued: a queued call would hold a client request
/// open against the host's own timeout, and the cap exists to stop a flood.
///
/// One lock around a counter; no caller holds it across a suspension point.
final class LogReadGate: @unchecked Sendable {
    static let shared = LogReadGate(limit: 2)

    let limit: Int
    private let lock = NSLock()
    private var running = 0

    init(limit: Int) { self.limit = limit }

    /// Takes a slot if one is free. Every `true` must be paired with `release()`.
    func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard running < limit else { return false }
        running += 1
        return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        // Clamped, not a precondition: the server outlives a bookkeeping bug.
        running = max(running - 1, 0)
    }

    var active: Int {
        lock.lock(); defer { lock.unlock() }
        return running
    }
}

/// #467 — set by the tool handler when the client cancels the call, read by the
/// blocking read on its own thread. Once set, stays set.
final class LogReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    init() {}

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}
