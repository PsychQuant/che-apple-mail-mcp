import XCTest
@testable import CheAppleMailMCP

/// #471 — the first NSAppleScript in a process must be initialized on the MAIN
/// thread, or the background thread that initialized the AppleScript component
/// never receives its Apple Event replies.
///
/// Reproduced outside the server (fresh process, main thread in CFRunLoopRun,
/// the same nine-account query each time):
///   - background NSAppleScript, first call: no reply after 100 s (twice);
///   - main-thread NSAppleScript: 0.34 s; `osascript`: 0.30 s;
///   - a second background thread started while the first hangs: 0.21 s;
///   - `return 1` (no Apple Event) run once on the main thread first: every
///     later background call 0.24 s. The same `return 1` on a background
///     thread does not help, and a call that is already stuck cannot be
///     rescued afterwards.
/// In the server this surfaced as the first `list_accounts` taking 45–75 s and
/// the first `create_draft` ~39 s instead of ~8 s.
final class AppleScriptPrimerTests: XCTestCase {

    func testPrimesExactlyOnceUnderConcurrentCalls() {
        let primer = AppleScriptPrimer()
        let count = Counter()
        let group = DispatchGroup()
        for _ in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                primer.ensurePrimed(onMain: { work in work() }, prime: { count.increment() })
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(count.value, 1, "the prime action must run once per process, not per call")
    }

    func testPrimeRunsThroughTheMainThreadExecutor() {
        let primer = AppleScriptPrimer()
        var routedThroughMain = false
        var primedInsideExecutor = false
        primer.ensurePrimed(
            onMain: { work in routedThroughMain = true; work() },
            prime: { primedInsideExecutor = routedThroughMain })
        XCTAssertTrue(routedThroughMain, "the prime must be handed to the main-thread executor")
        XCTAssertTrue(primedInsideExecutor, "and must execute inside it, not before it")
    }

    func testLaterCallsDoNotReenterTheExecutor() {
        let primer = AppleScriptPrimer()
        var executorCalls = 0
        for _ in 0..<3 {
            primer.ensurePrimed(onMain: { work in executorCalls += 1; work() }, prime: {})
        }
        XCTAssertEqual(executorCalls, 1, "after the first prime, calls must not touch the main thread again")
    }

    func testDefaultExecutorDoesNotDeadlockWhenCalledOnTheMainThread() {
        // The production executor hops with DispatchQueue.main.sync; called
        // from the main thread itself that would deadlock unless it runs inline.
        let primer = AppleScriptPrimer()
        var ran = false
        XCTAssertTrue(Thread.isMainThread)
        primer.ensurePrimed(onMain: AppleScriptPrimer.mainThreadExecutor, prime: { ran = Thread.isMainThread })
        XCTAssertTrue(ran)
    }

    func testDefaultExecutorRunsOnTheMainThreadFromABackgroundThread() {
        let primer = AppleScriptPrimer()
        let done = expectation(description: "primed")
        var ranOnMain = false
        DispatchQueue.global().async {
            primer.ensurePrimed(onMain: AppleScriptPrimer.mainThreadExecutor, prime: { ranOnMain = Thread.isMainThread })
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(ranOnMain)
    }

    /// Every real NSAppleScript construction in MailController must be preceded,
    /// inside the same function, by a call that primes on the main thread.
    func testEveryNSAppleScriptInMailControllerIsPrimedFirst() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CheAppleMailMCP/AppleScript/MailController.swift"),
            encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let sites = lines.indices.filter {
            lines[$0].contains("NSAppleScript(source:")
                && !lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        XCTAssertFalse(sites.isEmpty, "expected the real NSAppleScript paths in MailController")
        for site in sites {
            guard let fn = lines[..<site].lastIndex(where: { $0.contains("func ") }) else {
                XCTFail("no enclosing func for line \(site + 1)"); continue
            }
            let body = lines[fn..<site].joined(separator: "\n")
            XCTAssertTrue(body.contains("ensurePrimed()"),
                "line \(site + 1): NSAppleScript is constructed without priming the AppleScript "
                + "component on the main thread first (#471)")
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
