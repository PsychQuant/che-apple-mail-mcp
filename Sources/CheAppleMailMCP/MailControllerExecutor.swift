import Dispatch

/// Keep blocking AppleScript waits off Swift's cooperative executor pool.
final class MailControllerExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "che-apple-mail-mcp.mail-controller", qos: .userInitiated)

    // The protocol's default witness is macOS 14+ in newer toolchains.
    // Supply the older runtime-compatible representation explicitly.
    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func enqueue(_ job: UnownedJob) {
        queue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }
}
