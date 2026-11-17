import Darwin
import Foundation

/// #646 — why a child could not be started.
struct SpawnFailure: Error, Equatable {
    let message: String
}

/// #646 — a child started with `posix_spawn` in its own process group, reaped by us and nobody else.
///
/// Foundation's `Process` already puts its child in a group of its own, but it reaps the leader the
/// moment it exits. After that, `kill(-pid, …)` can reach an unrelated group that reused the number.
/// Here the leader stays unreaped (alive, or a zombie) until the caller says so, so the group number
/// cannot be reused while it is signalled. The rule for callers: signal the group first, reap last.
///
/// One thread owns an instance (the one running `LogShowRunner.read`); nothing here is locked.
final class SpawnedChild {
    let pid: pid_t
    /// Read ends of the child's stdout and stderr. The caller owns both and closes each exactly once.
    let stdoutFD: Int32
    let stderrFD: Int32
    /// Who owns the leader's pid. A group signal is only allowed while it is `.owned` (unreaped, so the
    /// number cannot be reissued). From any other state nothing may signal, or wait on, this pid or its
    /// group by anything but the one hand-off that already holds the right to.
    private enum State {
        case owned
        /// We reaped it.
        case reaped
        /// Handed to a background thread that waits on the pid (the leader was still ours).
        case handedOff
        /// `waitid` says there is no such child: someone else reaped it, so the pid may be reissued.
        /// Never wait on it again.
        case gone
        /// `waitid` failed in another way: the leader may still be ours, but it cannot be observed.
        /// `reap` hands it to a background thread, once.
        case unobservable
    }
    private var state = State.owned

    private init(pid: pid_t, stdoutFD: Int32, stderrFD: Int32) {
        self.pid = pid
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
    }

    // MARK: - Spawn

    /// Starts `executablePath` with stdin on `/dev/null`, stdout and stderr on fresh pipes, in a new
    /// process group (pgid == pid), with only those three descriptors inherited and default signal
    /// handling. No shell is involved: `arguments` is the argv after the program name.
    static func spawn(executablePath: String, arguments: [String],
                      environment: [String: String]) throws -> SpawnedChild {
        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw SpawnFailure(message: "pipe failed: \(errnoText())") }
        guard pipe(&err) == 0 else {
            let why = errnoText()
            close(out[0]); close(out[1])
            throw SpawnFailure(message: "pipe failed: \(why)")
        }
        // Ours must never leak into any other child either.
        for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        func closeAll() { for fd in out + err where fd >= 0 { close(fd) } }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            closeAll()
            throw SpawnFailure(message: "posix_spawn_file_actions_init failed")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            closeAll()
            throw SpawnFailure(message: "posix_spawnattr_init failed")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var allSignals = sigset_t()
        sigfillset(&allSignals)
        sigdelset(&allSignals, SIGKILL)
        sigdelset(&allSignals, SIGSTOP)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)

        // CLOEXEC_DEFAULT: the child inherits the descriptors named in the file actions and nothing else.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        let configured =
            posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0) == 0
            && posix_spawn_file_actions_adddup2(&fileActions, out[1], 1) == 0
            && posix_spawn_file_actions_adddup2(&fileActions, err[1], 2) == 0
            && posix_spawnattr_setpgroup(&attributes, 0) == 0
            && posix_spawnattr_setsigdefault(&attributes, &allSignals) == 0
            && posix_spawnattr_setsigmask(&attributes, &noSignals) == 0
            && posix_spawnattr_setflags(&attributes, Int16(flags)) == 0
        guard configured else {
            closeAll()
            throw SpawnFailure(message: "could not configure the spawn")
        }

        let argv = cStringArray([executablePath] + arguments)
        let envp = cStringArray(environment.map { "\($0.key)=\($0.value)" })
        defer { freeCStringArray(argv); freeCStringArray(envp) }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executablePath, &fileActions, &attributes, argv, envp)
        guard rc == 0 else {
            closeAll()
            throw SpawnFailure(message: String(cString: strerror(rc)))
        }
        // The child holds the write ends now; ours must go, or the reads below never see EOF.
        close(out[1]); close(err[1])
        return SpawnedChild(pid: pid, stdoutFD: out[0], stderrFD: err[0])
    }

    // MARK: - Lifecycle

    /// Waits up to `seconds` for the leader to exit, WITHOUT reaping it: it stays a zombie holding
    /// the group number until `reap`. Returns true when waiting is over: it has exited, or it can no
    /// longer be observed (then the group is not signalled any more and `reap` never blocks on it).
    func waitForExit(timeout seconds: TimeInterval) -> Bool {
        if state != .owned { return true }
        let giveUp = DispatchTime.now() + seconds
        while true {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                if info.si_pid != 0 { return true }
            } else if errno != EINTR {
                // Not waitable: ECHILD means something else reaped the leader (the pid may be reissued
                // from now on); any other error means waitid itself failed. Either way the leader no
                // longer provably pins the group number, so stop signalling and never wait blocking.
                state = errno == ECHILD ? .gone : .unobservable
                return true
            }
            if DispatchTime.now() >= giveUp { return false }
            usleep(5_000)
        }
    }

    /// Signals every member of the child's group. Only valid while the leader is unreaped.
    func signalGroup(_ signal: Int32) {
        guard state == .owned else { return }
        _ = kill(-pid, signal)
    }

    /// Reaps the leader and returns its exit status (the signal number for a child killed by a
    /// signal), or -1 for a child that did not exit within `seconds`. That child is handed to a
    /// background thread that reaps it whenever it does, and the group is not signalled again.
    func reap(waitingUpTo seconds: TimeInterval) -> Int32 {
        if state == .owned, !waitForExit(timeout: seconds) {
            state = .handedOff
            handOffToBackgroundReaper()
            return -1
        }
        switch state {
        case .owned:
            break
        case .unobservable:
            // A blocking wait here could hang, so collect it in the background, once.
            state = .handedOff
            handOffToBackgroundReaper()
            return -1
        case .reaped, .handedOff, .gone:
            return -1
        }
        state = .reaped
        var status: Int32 = 0
        while true {
            let r = waitpid(pid, &status, 0)
            if r == pid { break }
            if r < 0, errno == EINTR { continue }
            return -1
        }
        let signalNumber = status & 0x7f
        return signalNumber == 0 ? (status >> 8) & 0xff : signalNumber
    }

    /// Test seam: how many background reaper threads have been started (each waits on a pid).
    static var backgroundReapersStarted: Int { reaperCounter.value }
    private static let reaperCounter = ReaperCounter()

    private func handOffToBackgroundReaper() {
        let pid = self.pid
        Self.reaperCounter.increment()
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        }
    }

    // MARK: - Helpers

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}

private func cStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
    let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
    for (index, string) in strings.enumerated() { array[index] = strdup(string) }
    array[strings.count] = nil
    return array
}

private func freeCStringArray(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
    var index = 0
    while let item = array[index] { free(item); index += 1 }
    array.deallocate()
}

private final class ReaperCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
