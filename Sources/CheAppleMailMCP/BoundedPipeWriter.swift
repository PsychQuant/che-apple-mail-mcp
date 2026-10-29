import Darwin
import Dispatch
import Foundation

enum BoundedPipeWriteError: Error {
    case timedOut, cancelled
    case posix(Int32)
}

/// Nonblocking input delivery shares the caller's absolute execution deadline.
/// F_SETNOSIGPIPE is descriptor-local, so tests need not alter process signals.
enum BoundedPipeWriter {
    static func write(_ data: Data, to fd: Int32, deadline: DispatchTime,
                      cancelled: () -> Bool = { Task.isCancelled }) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw BoundedPipeWriteError.posix(errno) }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                if cancelled() { throw BoundedPipeWriteError.cancelled }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline.uptimeNanoseconds else { throw BoundedPipeWriteError.timedOut }
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else {
                    throw BoundedPipeWriteError.posix(errno)
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let remaining = deadline.uptimeNanoseconds - now
                let milliseconds = Int32(min(50, max(1, remaining / 1_000_000)))
                let result = poll(&descriptor, 1, milliseconds)
                if result < 0 && errno != EINTR { throw BoundedPipeWriteError.posix(errno) }
            }
        }
    }
}
