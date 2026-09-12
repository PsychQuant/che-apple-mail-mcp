import Foundation

/// Memory-only account metadata cache. No blocking wait occurs on this actor.
actor AccountIdentityCache {
    typealias Loader = @Sendable () async throws -> AccountIdentitySnapshot
    private let loader: Loader
    private let clock: @Sendable () -> TimeInterval
    private let ttl: TimeInterval
    private let backoff: TimeInterval
    private let waitNanoseconds: UInt64
    private var cached: AccountIdentitySnapshot?
    private var loadedAt: TimeInterval = 0
    private var retryAfter: TimeInterval = 0
    private var lastError = "account identity metadata unavailable"
    private var flightID: UUID?
    private var flightTimedOut = false
    private var refreshTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<AccountIdentityLookup, Never>] = [:]

    init(ttl: TimeInterval = 300, backoff: TimeInterval = 60, waitTimeout: TimeInterval = 5,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         loader: @escaping Loader) {
        self.ttl = ttl
        self.backoff = backoff
        self.waitNanoseconds = UInt64(waitTimeout * 1_000_000_000)
        self.clock = clock
        self.loader = loader
    }

    func get(forceRefresh: Bool = false) async -> AccountIdentityLookup {
        if Task.isCancelled { return .unavailable("account identity request cancelled") }
        let now = clock()
        if !forceRefresh, let cached, now - loadedAt < ttl {
            return AccountIdentityLookup(snapshot: cached, ageSeconds: Int(max(0, now - loadedAt)), error: nil)
        }
        if flightID == nil {
            if !forceRefresh, now < retryAfter { return .unavailable(lastError) }
            startRefresh()
        }
        if flightTimedOut { return .unavailable("account identity refresh is still pending") }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: .unavailable("account identity request cancelled")) }
                else if flightID == nil {
                    if let cached {
                        continuation.resume(returning: AccountIdentityLookup(snapshot: cached, ageSeconds: Int(max(0, clock() - loadedAt)), error: nil))
                    } else { continuation.resume(returning: .unavailable(lastError)) }
                } else if flightTimedOut {
                    continuation.resume(returning: .unavailable("account identity refresh is still pending"))
                } else { waiters[waiterID] = continuation }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func startRefresh() {
        let token = UUID()
        cached = nil // A forced refresh invalidates the old view for all callers.
        flightID = token
        flightTimedOut = false
        refreshTask = Task { [loader] in
            let result: Result<AccountIdentitySnapshot, Error>
            do { result = .success(try await loader()) }
            catch { result = .failure(error) }
            finishRefresh(token, result: result)
        }
        deadlineTask = Task {
            do { try await Task.sleep(nanoseconds: waitNanoseconds) }
            catch { return }
            timeoutRefresh(token)
        }
    }

    private func finishRefresh(_ token: UUID, result: Result<AccountIdentitySnapshot, Error>) {
        guard flightID == token else { return }
        deadlineTask?.cancel()
        deadlineTask = nil
        refreshTask = nil
        flightID = nil
        flightTimedOut = false
        let lookup: AccountIdentityLookup
        switch result {
        case .success(let snapshot):
            cached = snapshot
            loadedAt = clock()
            retryAfter = 0
            lookup = AccountIdentityLookup(snapshot: snapshot, ageSeconds: 0, error: nil)
        case .failure(let error):
            cached = nil // Never revive expired or invalidated evidence after failure.
            lastError = "account identity refresh failed: \(error.localizedDescription)"
            retryAfter = clock() + backoff
            Diagnostics.emit(lastError + "\n")
            lookup = .unavailable(lastError)
        }
        resumeWaiters(lookup)
    }

    private func timeoutRefresh(_ token: UUID) {
        guard flightID == token else { return }
        flightTimedOut = true
        deadlineTask = nil
        Diagnostics.emit("account identity refresh exceeded the caller wait budget; shared refresh remains pending\n")
        resumeWaiters(.unavailable("account identity refresh is still pending"))
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: .unavailable("account identity request cancelled"))
    }

    private func resumeWaiters(_ lookup: AccountIdentityLookup) {
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: lookup) }
    }
}
