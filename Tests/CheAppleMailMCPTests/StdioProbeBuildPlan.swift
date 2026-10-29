import Foundation

/// Read the compiler and object set produced by the active build backend.
/// The probe still links the real app; it never substitutes a mock transport.
struct StdioProbeBuildPlan {
    let compiler: String
    let target: String
    let sdk: String
    let modules: URL
    let objects: [String]
    let responseContents: String?

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "StdioProbeBuildPlan", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func argument(_ option: String, in arguments: [String]) throws -> String {
        let indices = arguments.indices.filter { arguments[$0] == option }
        guard indices.count == 1, let index = indices.first, index + 1 < arguments.count else {
            throw invalid("Missing or ambiguous \(option) in build metadata")
        }
        return arguments[index + 1]
    }

    static func load(products: URL) throws -> Self {
        let fm = FileManager.default
        let nativeList = products.appendingPathComponent("CheAppleMailMCP.product/Objects.LinkFileList")
        if fm.fileExists(atPath: nativeList.path) {
            let data = try Data(contentsOf: products.appendingPathComponent("description.json"))
            let description = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let commands = description?["swiftCommands"] as? [String: [String: Any]] else {
                throw invalid("Native build description has no Swift commands")
            }
            let matches = commands.values.filter { $0["moduleName"] as? String == "CheAppleMailMCP" }
            guard matches.count == 1, let command = matches.first,
                  let compiler = command["executable"] as? String,
                  let arguments = command["otherArguments"] as? [String] else {
                throw invalid("Native build has no unique app compiler command")
            }
            let lines = try String(contentsOf: nativeList).split(separator: "\n").map(String.init)
            let objects = lines.filter { !$0.contains("CheAppleMailMCP.build/main.swift.o") }
            guard lines.count - objects.count == 1, !objects.isEmpty else {
                throw invalid("Native build must contain exactly one app entry-point object")
            }
            // Preserve the native backend's response-file quoting verbatim.
            return Self(compiler: compiler, target: try argument("-target", in: arguments),
                        sdk: try argument("-sdk", in: arguments),
                        modules: products.appendingPathComponent("Modules"), objects: [],
                        responseContents: objects.joined(separator: "\n") + "\n")
        }

        let buildData = products.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Intermediates.noindex/XCBuildData")
        var manifests: [(url: URL, modified: Date)] = []
        for directory in try fm.contentsOfDirectory(at: buildData, includingPropertiesForKeys: nil)
            where directory.pathExtension == "xcbuilddata" {
            let manifest = directory.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifest.path) else { continue }
            let values = try manifest.resourceValues(forKeys: [.contentModificationDateKey])
            manifests.append((manifest, values.contentModificationDate ?? Date.distantPast))
        }
        manifests.sort { lhs, rhs in
            if lhs.modified == rhs.modified { return lhs.url.path < rhs.url.path }
            return lhs.modified > rhs.modified
        }
        let expectedOutput = products.appendingPathComponent("CheAppleMailMCP").standardizedFileURL.path
        for (manifest, _) in manifests {
            let data = try Data(contentsOf: manifest)
            let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let commands = document?["commands"] as? [String: [String: Any]] else {
                throw invalid("SwiftBuild manifest has no commands")
            }
            let matches = commands.values.filter { command in
                guard command["tool"] as? String == "shell",
                      let args = command["args"] as? [String],
                      args.first?.hasSuffix("/swiftc") == true,
                      let output = try? argument("-o", in: args) else { return false }
                return URL(fileURLWithPath: output).standardizedFileURL.path == expectedOutput
            }
            if matches.isEmpty { continue }
            guard matches.count == 1, let command = matches.first,
                  let args = command["args"] as? [String], let compiler = args.first,
                  let inputs = command["inputs"] as? [String] else {
                throw invalid("SwiftBuild has no unique app link command")
            }
            let allObjects = inputs.filter { $0.hasSuffix(".o") }
            let objects = allObjects.filter { URL(fileURLWithPath: $0).lastPathComponent != "main.o" }
            guard allObjects.count - objects.count == 1, !objects.isEmpty,
                  objects.allSatisfy({ fm.fileExists(atPath: $0) }) else {
                throw invalid("SwiftBuild app objects are missing or entry point is ambiguous")
            }
            // Use structured input paths, not the shell-style LinkFileList:
            // SwiftBuild writes that file as one quoted, space-separated line.
            return Self(compiler: compiler, target: try argument("-target", in: args),
                        sdk: try argument("-sdk", in: args), modules: products,
                        objects: objects, responseContents: nil)
        }
        throw invalid("No SwiftBuild link metadata matches the current app output")
    }
}
