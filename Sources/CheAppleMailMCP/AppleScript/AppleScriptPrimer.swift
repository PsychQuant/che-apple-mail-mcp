import Foundation

/// #471 — initialize the AppleScript component on the MAIN thread before any
/// background NSAppleScript runs.
///
/// `runGuarded` executes every NSAppleScript on a detached thread. In a fresh
/// process, the thread that happens to initialize the AppleScript component
/// never receives the replies to its Apple Events: the call waits in
/// `UASRemoteSend → AEDefaultActiveProc → … → mach_msg` until the 45-second
/// deadline (a `sample` of the server showed exactly that stack), while
/// `osascript` queries to Mail from outside stayed fast. Measured in the server:
/// the first `list_accounts` took 45–75 s and the first `create_draft` ~39 s
/// instead of ~8 s; later calls in the same process were normal.
///
/// A standalone reproduction (fresh process, main thread in `CFRunLoopRun`)
/// pinned the cause to WHERE the component is first initialized, not to Mail
/// or the query:
///   - background NSAppleScript, first call: no reply after 100 s;
///   - main-thread NSAppleScript 0.34 s, `osascript` 0.30 s;
///   - a second background thread started while the first hangs: 0.21 s;
///   - `return 1` executed once on the main thread first: every later
///     background call 0.24 s. The same `return 1` on a background thread does
///     NOT help, and a call that is already stuck cannot be rescued afterwards,
///     so priming has to happen before the first background script.
///
/// `return 1` sends no Apple Event, so priming needs no TCC grant and does not
/// launch or touch Mail.
///
/// Deadlock note: the default executor hops with `DispatchQueue.main.sync` and
/// the lock is held across it. A MAIN-thread caller arriving while a background
/// thread is mid-prime would wait on the lock while the background thread waits
/// on the main queue. No server-mode code primes from the main thread (all
/// scripts run through the `MailController` actor), and a main-thread caller
/// that finds the primer idle runs the prime inline.
final class AppleScriptPrimer: @unchecked Sendable {
    static let shared = AppleScriptPrimer()

    private let lock = NSLock()
    private var primed = false

    /// Runs `work` on the main thread and waits for it; inline when already there.
    static let mainThreadExecutor: (@escaping () -> Void) -> Void = { work in
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    /// Initializes the AppleScript component without sending an Apple Event.
    static let defaultPrime: () -> Void = {
        var error: NSDictionary?
        _ = NSAppleScript(source: "return 1")?.executeAndReturnError(&error)
    }

    /// Idempotent and thread-safe. Callers that arrive while the first prime is
    /// running wait for it, so no background script can start before it ends.
    func ensurePrimed(
        onMain: (@escaping () -> Void) -> Void = AppleScriptPrimer.mainThreadExecutor,
        prime: @escaping () -> Void = AppleScriptPrimer.defaultPrime
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !primed else { return }
        onMain(prime)
        primed = true
    }
}
