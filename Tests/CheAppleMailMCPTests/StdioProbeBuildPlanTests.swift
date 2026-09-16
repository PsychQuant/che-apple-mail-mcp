import Foundation
import XCTest

final class StdioProbeBuildPlanTests: XCTestCase {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stdio plan \(UUID().uuidString)")
        let products = root.appendingPathComponent("Products/Debug")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, products)
    }

    private func write(_ value: Any, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: path)
    }

    private func link(products: URL) throws -> [String: Any] {
        let objects = ["main.o", "Server.o", "dependency with space.o"].map { products.appendingPathComponent($0).path }
        for path in objects { try Data().write(to: URL(fileURLWithPath: path)) }
        return ["tool": "shell", "args": ["/fixture/toolchain/swiftc", "-target", "arm64-apple-macos13.0",
                                           "-sdk", "/fixture/SDK With Space", "-o", products.appendingPathComponent("CheAppleMailMCP").path],
                "inputs": objects]
    }

    func testSwiftBuildUsesExactOutputAndStructuredObjectPaths() throws {
        try fixture { root, products in
            let command = try link(products: products)
            let good = root.appendingPathComponent("Intermediates.noindex/XCBuildData/good.xcbuilddata/manifest.json")
            try write(["commands": ["app": command]], to: good)
            var unrelated = command
            var arguments = try XCTUnwrap(command["args"] as? [String])
            arguments[arguments.count - 1] = root.appendingPathComponent("Other/Debug/CheAppleMailMCP").path
            unrelated["args"] = arguments
            let newer = root.appendingPathComponent("Intermediates.noindex/XCBuildData/newer.xcbuilddata/manifest.json")
            try write(["commands": ["other": unrelated]], to: newer)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: good.path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: newer.path)
            let plan = try StdioProbeBuildPlan.load(products: products)
            XCTAssertEqual(plan.compiler, "/fixture/toolchain/swiftc")
            XCTAssertEqual(plan.target, "arm64-apple-macos13.0")
            XCTAssertEqual(plan.sdk, "/fixture/SDK With Space")
            XCTAssertEqual(plan.modules, products)
            XCTAssertEqual(plan.objects, [products.appendingPathComponent("Server.o").path,
                                          products.appendingPathComponent("dependency with space.o").path])
            XCTAssertNil(plan.responseContents)
        }
    }

    func testSwiftBuildRejectsAmbiguousLinkCommandsAndMissingSDK() throws {
        try fixture { root, products in
            var command = try link(products: products)
            let manifest = root.appendingPathComponent("Intermediates.noindex/XCBuildData/current.xcbuilddata/manifest.json")
            try write(["commands": ["first": command, "second": command]], to: manifest)
            XCTAssertThrowsError(try StdioProbeBuildPlan.load(products: products))
            command["args"] = ["/fixture/toolchain/swiftc", "-target", "arm64-apple-macos13.0", "-o", products.appendingPathComponent("CheAppleMailMCP").path]
            try write(["commands": ["app": command]], to: manifest)
            XCTAssertThrowsError(try StdioProbeBuildPlan.load(products: products))
        }
    }

    func testSwiftBuildRejectsMissingObjectsAndUnrecognizedEntrypoint() throws {
        try fixture { root, products in
            var command = try link(products: products)
            let manifest = root.appendingPathComponent("Intermediates.noindex/XCBuildData/current.xcbuilddata/manifest.json")
            try write(["commands": ["app": command]], to: manifest)
            try FileManager.default.removeItem(at: products.appendingPathComponent("Server.o"))
            XCTAssertThrowsError(try StdioProbeBuildPlan.load(products: products))
            command["inputs"] = [products.appendingPathComponent("dependency with space.o").path]
            try write(["commands": ["app": command]], to: manifest)
            XCTAssertThrowsError(try StdioProbeBuildPlan.load(products: products))
        }
    }

    func testNativeLayoutPreservesItsResponseFileAndCompilerMetadata() throws {
        try fixture { _, products in
            let list = products.appendingPathComponent("CheAppleMailMCP.product/Objects.LinkFileList")
            try FileManager.default.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "/build/CheAppleMailMCP.build/main.swift.o\n\"/build/object with space.o\"\n".write(to: list, atomically: true, encoding: .utf8)
            let command: [String: Any] = ["moduleName": "CheAppleMailMCP", "executable": "/native/toolchain/swiftc",
                                         "otherArguments": ["-target", "arm64-apple-macos13.0", "-sdk", "/native/sdk"]]
            let description = products.appendingPathComponent("description.json")
            try write(["swiftCommands": ["app": command]], to: description)
            let plan = try StdioProbeBuildPlan.load(products: products)
            XCTAssertEqual(plan.compiler, "/native/toolchain/swiftc")
            XCTAssertEqual(plan.sdk, "/native/sdk")
            XCTAssertEqual(plan.modules, products.appendingPathComponent("Modules"))
            XCTAssertEqual(plan.responseContents, "\"/build/object with space.o\"\n")
            XCTAssertTrue(plan.objects.isEmpty)
            try write(["swiftCommands": ["app": command, "duplicate": command]], to: description)
            XCTAssertThrowsError(try StdioProbeBuildPlan.load(products: products))
        }
    }
}
