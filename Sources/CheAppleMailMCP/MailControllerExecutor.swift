import Dispatch

/// Keep blocking AppleScript waits off Swift's cooperative executor pool.
final class MailControllerExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "che-apple-mail-mcp.mail-controller", qos: .userInitiated)

    func enqueue(_ job: UnownedJob) {
        queue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }
}
