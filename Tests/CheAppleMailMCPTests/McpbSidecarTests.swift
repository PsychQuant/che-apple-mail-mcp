import XCTest
@testable import CheAppleMailMCP

final class McpbSidecarTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func run(_ executable: String, _ arguments: [String],
                     directory: URL, environment: [String: String] = [:]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testPackagerFailureAndArchiveContracts() throws {
        let result = try run("/usr/bin/env", ["python3", "scripts/test-package-mcpb.py"], directory: root)
        XCTAssertEqual(result.0, 0, result.1)
    }

    func testRealPackagedSidecarFeedsTheProductionReader() throws {
        let fm = FileManager.default
        let lab = fm.temporaryDirectory.appendingPathComponent("mcpb-real-\(UUID().uuidString)")
        try fm.createDirectory(at: lab.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: lab.appendingPathComponent("mcpb"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: lab) }
        for path in ["scripts/package-mcpb.sh", "mcpb/manifest.json", "mcpb/icon.png", "mcpb/PRIVACY.md"] {
            try fm.copyItem(at: root.appendingPathComponent(path), to: lab.appendingPathComponent(path))
        }
        let products = Bundle(for: type(of: self)).bundleURL.deletingLastPathComponent()
        let executable = products.appendingPathComponent("CheAppleMailMCP")
        XCTAssertTrue(fm.fileExists(atPath: executable.path), "Build the real executable before this test")
        let archive = lab.appendingPathComponent("result.mcpb")
        let packaged = try run("/bin/bash", ["scripts/package-mcpb.sh", executable.path, archive.path],
                               directory: lab, environment: ["MCPB_ALLOW_UNSIGNED": "1"])
        XCTAssertEqual(packaged.0, 0, packaged.1)
        guard packaged.0 == 0 else { return }
        let extracted = lab.appendingPathComponent("extracted")
        let unzip = try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path], directory: lab)
        XCTAssertEqual(unzip.0, 0, unzip.1)
        let sidecar = extracted.appendingPathComponent("server/.CheAppleMailMCP.version")
        let installed = MailController.readVersionSidecar(at: sidecar.path)
        XCTAssertEqual(installed, AppVersion.current)
        XCTAssertNil(StalenessCheck.evaluate(compiled: AppVersion.current, sidecar: installed))
        let warning = StalenessCheck.evaluate(compiled: "0.0.0", sidecar: installed)
        XCTAssertTrue(warning?.contains("Claude Desktop") == true, "Desktop users need applicable restart guidance")
    }
}
