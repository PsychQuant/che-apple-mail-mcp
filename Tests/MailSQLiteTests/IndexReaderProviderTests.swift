import XCTest
import SQLite3
@testable import MailSQLite
#if canImport(Darwin)
import Darwin
#endif

/// #537 — the server opened its Envelope Index reader once, in `init`. A refusal
/// at that moment (a TCC denial that clears a minute later, a launch-time
/// hiccup) therefore lasted for the whole process, while `check_fda` — which
/// only `fopen`s the file — happily reported "GRANTED".
///
/// `IndexReaderProvider` makes a missing reader a state, not a verdict: reads
/// ask it for the reader, it retries the open at most once per interval, and a
/// forced retry (for `check_fda`) skips the interval. Everything outside the
/// provider (opening, the clock, the FDA probe, the log sink) is injected, so
/// these tests touch no Mail data and no real clock.
final class IndexReaderProviderTests: XCTestCase {

    // MARK: - harness

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        @discardableResult func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000
        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        /// Line `index`, or "" when there is none (keeps a failing run from trapping).
        func line(_ index: Int) -> String { lines.indices.contains(index) ? lines[index] : "" }
    }

    private struct OpenFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A tiny valid SQLite file, so `EnvelopeIndexReader.init` succeeds.
    private func makeDatabasePath() throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "IndexReaderProviderTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Envelope Index").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw OpenFailure(message: "could not create the fixture database")
        }
        sqlite3_close(db)
        return path
    }

    private struct Harness {
        let provider: IndexReaderProvider
        let opens: Counter
        let clock: Clock
        let log: Log
    }

    /// `script(n)` decides the outcome of the n-th `open` call (1-based):
    /// a message means "fail with it", nil means "succeed".
    private func makeHarness(
        retryInterval: TimeInterval = 30,
        probe: @escaping () -> FDAStatus.Detail = { FDAStatus.Detail(probe: .denied, errnoValue: EACCES) },
        openDelayMicroseconds: UInt32 = 0,
        script: @escaping @Sendable (Int) -> String?
    ) throws -> Harness {
        let path = try makeDatabasePath()
        let opens = Counter()
        let clock = Clock()
        let log = Log()
        let provider = IndexReaderProvider(
            retryInterval: retryInterval,
            open: {
                let n = opens.increment()
                if openDelayMicroseconds > 0 { usleep(openDelayMicroseconds) }
                if let failure = script(n) { throw OpenFailure(message: failure) }
                return try EnvelopeIndexReader(databasePath: path, accountMapping: [:])
            },
            uptime: { clock.now },
            probe: probe,
            log: { log.append($0) })
        return Harness(provider: provider, opens: opens, clock: clock, log: log)
    }

    // MARK: - 1. success is cached

    func testFirstSuccessIsReturnedAndCached() throws {
        let h = try makeHarness { _ in nil }
        let first = try XCTUnwrap(h.provider.current())
        h.clock.advance(3_600)
        let second = try XCTUnwrap(h.provider.current())
        XCTAssertTrue(first === second, "once open, the same reader must be handed out")
        XCTAssertEqual(h.opens.count, 1)
        XCTAssertEqual(h.log.lines, [], "a clean start prints nothing")
    }

    // MARK: - 2. failures are rate limited

    func testFailureWithinTheIntervalDoesNotReopen() throws {
        let h = try makeHarness { _ in "authorization denied" }
        XCTAssertNil(h.provider.current())
        h.clock.advance(29)
        XCTAssertNil(h.provider.current())
        XCTAssertNil(h.provider.current())
        XCTAssertEqual(h.opens.count, 1, "no retry before the interval has passed")
    }

    // MARK: - 3. recovery

    func testRetryAfterTheIntervalRecoversAndSaysSo() throws {
        let h = try makeHarness { $0 == 1 ? "authorization denied" : nil }
        XCTAssertNil(h.provider.current())
        h.clock.advance(31)
        let reader = h.provider.current()
        XCTAssertNotNil(reader, "the second attempt succeeds, so the reader must now be available")
        XCTAssertEqual(h.opens.count, 2)
        let recovered = h.log.lines.last ?? ""
        XCTAssertTrue(recovered.contains("recovered"), "the recovery must be logged; got: \(recovered)")
        XCTAssertTrue(recovered.contains("authorization denied"),
                      "the recovery line names the failure it recovered from; got: \(recovered)")
    }

    // MARK: - 4. single flight

    func testConcurrentCallsAfterTheIntervalOpenExactlyOnce() throws {
        let h = try makeHarness(openDelayMicroseconds: 20_000) { $0 == 1 ? "authorization denied" : nil }
        XCTAssertNil(h.provider.current())
        h.clock.advance(31)

        let lock = NSLock()
        var seen: [ObjectIdentifier?] = []
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            let id = h.provider.current().map(ObjectIdentifier.init)
            lock.lock(); seen.append(id); lock.unlock()
        }
        XCTAssertEqual(h.opens.count, 2, "one startup attempt plus exactly one retry, however many callers raced")
        XCTAssertEqual(seen.count, 50)
        XCTAssertEqual(Set(seen.compactMap { $0 }).count, 1, "every caller must see the same reader")
        XCTAssertFalse(seen.contains(where: { $0 == nil }), "no caller may be told 'unavailable' while the open was in flight")
    }

    // MARK: - 5. a permanent failure does not flood the log

    func testPersistentIdenticalFailureIsLoggedOnce() throws {
        let h = try makeHarness { _ in "Database does not exist" }
        for _ in 0..<10 {
            XCTAssertNil(h.provider.current())
            h.clock.advance(31)
        }
        XCTAssertNil(h.provider.current())
        XCTAssertEqual(h.opens.count, 11, "1 startup attempt + 10 interval retries")
        XCTAssertEqual(h.log.lines.count, 1, "the same failure must not be printed again on every retry; got: \(h.log.lines)")
        XCTAssertTrue(h.log.line(0).hasPrefix("EnvelopeIndexReader init failed:"),
                      "the startup line keeps the documented prefix; got: \(h.log.line(0))")
    }

    // MARK: - 6. a changed failure is news

    func testChangedFailureIsLoggedAgain() throws {
        let h = try makeHarness { $0 == 1 ? "authorization denied" : "file is not a database" }
        XCTAssertNil(h.provider.current())
        h.clock.advance(31)
        XCTAssertNil(h.provider.current())
        h.clock.advance(31)
        XCTAssertNil(h.provider.current())
        XCTAssertEqual(h.log.lines.count, 2, "startup failure plus one line when the failure changed")
        XCTAssertTrue(h.log.line(1).contains("retry failed"), "got: \(h.log.line(1))")
        XCTAssertTrue(h.log.line(1).contains("file is not a database"))
    }

    func testChangedProbeResultIsLoggedAgainEvenIfTheErrorIsTheSame() throws {
        // The probe moving from denied to granted while the open still fails is
        // exactly the H3 evidence (#537): it must not be swallowed as a repeat.
        let probes = Counter()
        let h = try makeHarness(probe: {
            probes.increment() == 1
                ? FDAStatus.Detail(probe: .denied, errnoValue: EACCES)
                : FDAStatus.Detail(probe: .granted, errnoValue: 0)
        }) { _ in "authorization denied" }
        XCTAssertNil(h.provider.current())
        h.clock.advance(31)
        XCTAssertNil(h.provider.current())
        XCTAssertEqual(h.log.lines.count, 2)
        XCTAssertTrue(h.log.line(1).contains("granted"))
    }

    // MARK: - 7. forced retry

    func testForceRetryWhenAlreadyAvailableDoesNotReopen() throws {
        let h = try makeHarness { _ in nil }
        XCTAssertNotNil(h.provider.current())
        XCTAssertEqual(h.provider.forceRetry(), .alreadyAvailable)
        XCTAssertEqual(h.opens.count, 1)
    }

    func testForceRetryBypassesTheIntervalAndReportsRecovery() throws {
        let h = try makeHarness { $0 == 1 ? "authorization denied" : nil }
        XCTAssertNil(h.provider.current())
        // No time has passed: a lazy retry would be refused, a forced one must not.
        let outcome = h.provider.forceRetry()
        guard case .recovered(let prior) = outcome else {
            return XCTFail("expected .recovered, got \(outcome)")
        }
        XCTAssertTrue(prior?.contains("authorization denied") == true, "prior failure should be carried; got \(String(describing: prior))")
        XCTAssertNotNil(h.provider.current())
        XCTAssertEqual(h.opens.count, 2)
    }

    func testForceRetryReportsAFailureAndAlwaysLogsIt() throws {
        let h = try makeHarness { _ in "authorization denied" }
        XCTAssertNil(h.provider.current())
        XCTAssertEqual(h.log.lines.count, 1)
        XCTAssertEqual(h.provider.forceRetry(), .stillUnavailable("authorization denied"))
        XCTAssertEqual(h.provider.forceRetry(), .stillUnavailable("authorization denied"))
        XCTAssertEqual(h.log.lines.count, 3, "an explicit check_fda is always answered in the log, repeated or not")
    }

    func testForceRetryRestartsTheIntervalFromThatMoment() throws {
        let h = try makeHarness { $0 <= 2 ? "authorization denied" : nil }
        XCTAssertNil(h.provider.current())
        h.clock.advance(25)
        XCTAssertEqual(h.provider.forceRetry(), .stillUnavailable("authorization denied"))
        h.clock.advance(10)   // 35 s since the startup attempt, only 10 s since the forced one
        XCTAssertNil(h.provider.current(), "the interval counts from the forced attempt")
        XCTAssertEqual(h.opens.count, 2)
        h.clock.advance(21)
        XCTAssertNotNil(h.provider.current())
        XCTAssertEqual(h.opens.count, 3)
    }

    // MARK: - 8. every line carries the probe evidence

    func testEveryLogLineCarriesTheProbeResultAndErrno() throws {
        let h = try makeHarness { $0 == 1 || $0 == 2 ? "authorization denied" : nil }
        _ = h.provider.current()                     // startup failure
        _ = h.provider.forceRetry()                  // forced failure
        h.clock.advance(31)
        _ = h.provider.current()                     // recovery
        XCTAssertEqual(h.log.lines.count, 3)
        for line in h.log.lines {
            XCTAssertTrue(line.contains("FDA probe: denied (errno \(EACCES))"),
                          "every line must carry the probe result and errno; got: \(line)")
        }
    }
}
