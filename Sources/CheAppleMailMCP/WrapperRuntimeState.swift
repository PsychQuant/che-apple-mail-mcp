import Foundation
import Darwin

/// #393 — the running image is the authority for version_at_spawn. A wrapper
/// can only observe an install before exec; another installer may replace it
/// in that gap. Only an explicitly cooperating wrapper requests this write.
@discardableResult
func publishWrapperRuntimeState(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    processID: Int32 = ProcessInfo.processInfo.processIdentifier,
    version: String,
    startedAt: Int64 = Int64(Date().timeIntervalSince1970)
) throws -> Bool {
    guard processID > 0,
          environment["CHE_APPLE_MAIL_WRAPPER_PID"] == String(processID),
          let home = environment["HOME"], home.hasPrefix("/") else { return false }

    let directory = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("bin")
    let destination = directory.appendingPathComponent(".CheAppleMailMCP.runtime.json")
    let temporary = directory.appendingPathComponent(".CheAppleMailMCP.runtime.\(UUID().uuidString).tmp")
    let wrapperStart = environment["CHE_APPLE_MAIL_WRAPPER_STARTED_AT"].flatMap(Int64.init)
    let data = try JSONSerialization.data(withJSONObject: [
        "pid": processID,
        "started_at": wrapperStart.flatMap { $0 >= 0 ? $0 : nil } ?? startedAt,
        "version_at_spawn": version,
        "version_source": "binary",
        "degraded_pin": environment["CHE_APPLE_MAIL_DEGRADED_PIN"] ?? "",
    ])
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer {
        try? handle.close()
        try? FileManager.default.removeItem(at: temporary)
    }
    try handle.write(contentsOf: data)
    try handle.close()
    guard rename(temporary.path, destination.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return true
}
