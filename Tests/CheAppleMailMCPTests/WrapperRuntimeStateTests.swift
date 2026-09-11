import XCTest
@testable import CheAppleMailMCP

final class WrapperRuntimeStateTests: XCTestCase {
    func testOnlyMatchingWrapperPIDCanRequestPublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for marker in [nil, "wrong", "124"] as [String?] {
            var env = ["HOME": root.path]
            env["CHE_APPLE_MAIL_WRAPPER_PID"] = marker
            XCTAssertFalse(try publishWrapperRuntimeState(environment: env, processID: 123, version: "3.0.0", startedAt: 100))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRunningImageReplacesStaleWrapperObservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = bin.appendingPathComponent(".CheAppleMailMCP.runtime.json")
        try Data("{\"pid\":123,\"version_at_spawn\":\"2.99.0\"}".utf8).write(to: file)
        let env = ["HOME": root.path, "CHE_APPLE_MAIL_WRAPPER_PID": "123",
                   "CHE_APPLE_MAIL_WRAPPER_STARTED_AT": "95",
                   "CHE_APPLE_MAIL_DEGRADED_PIN": "2.99.0"]
        XCTAssertTrue(try publishWrapperRuntimeState(environment: env, processID: 123, version: "3.0.0", startedAt: 100))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(value["pid"] as? Int, 123)
        XCTAssertEqual(value["started_at"] as? Int, 95)
        XCTAssertEqual(value["version_at_spawn"] as? String, "3.0.0")
        XCTAssertEqual(value["degraded_pin"] as? String, "2.99.0")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bin.path), [file.lastPathComponent])
    }

    func testPublicationFailureDoesNotLeaveTemporaryFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = root.appendingPathComponent("bin")
        let destination = bin.appendingPathComponent(".CheAppleMailMCP.runtime.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try publishWrapperRuntimeState(
            environment: ["HOME": root.path, "CHE_APPLE_MAIL_WRAPPER_PID": "123"],
            processID: 123, version: "3.0.0", startedAt: 100))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bin.path), [destination.lastPathComponent])
    }
}
