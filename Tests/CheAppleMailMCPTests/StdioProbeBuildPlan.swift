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
    /// Module maps of the C modules the app's dependencies import (#742: SwiftMail
    /// brings swift-atomics and NIO's C shims). The probe compiles with implicit
    /// modules, so it must be told where each map is, as the app's own compile was.
    let moduleMaps: [String]

    /// The compiler arguments that hand `moduleMaps` to clang.
    var moduleMapArguments: [String] { moduleMaps.flatMap { ["-Xcc", "-fmodule-map-file=" + $0] } }

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
            // The native backend names every C module map on the app's own command line.
            var maps: [String] = []
            for index in arguments.indices.dropLast() where arguments[index] == "-Xcc"
                && arguments[index + 1].hasPrefix("-fmodule-map-file=") {
                maps.append(String(arguments[index + 1].dropFirst("-fmodule-map-file=".count)))
            }
            // Preserve the native backend's response-file quoting verbatim.
            return Self(compiler: compiler, target: try argument("-target", in: arguments),
                        sdk: try argument("-sdk", in: arguments),
                        modules: products.appendingPathComponent("Modules"), objects: [],
                        responseContents: objects.joined(separator: "\n") + "\n", moduleMaps: maps)
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
        // #578: Foundation reports a checkout under /tmp as /tmp/... while Swift Build records
        // /private/tmp/..., and `standardizedFileURL` does not resolve that link. Both sides go
        // through the same symlink resolution so the two spellings compare equal.
        let expectedOutput = canonicalPath(products.appendingPathComponent("CheAppleMailMCP"))
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
                return canonicalPath(URL(fileURLWithPath: output)) == expectedOutput
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
            let sdk = try argument("-sdk", in: args)
            return Self(compiler: compiler, target: try argument("-target", in: args),
                        sdk: sdk, modules: products,
                        objects: objects, responseContents: nil,
                        moduleMaps: try moduleMaps(besides: objects, outside: sdk))
        }
        throw invalid("No SwiftBuild link metadata matches the current app output")
    }

    /// SwiftBuild compiles with explicit modules and does not put the module maps on a command
    /// line this test can read, but each object's dependency file (`X.d` next to `X.o`) lists
    /// every module map that compile read. The SDK's own maps are found without help.
    static func moduleMaps(besides objects: [String], outside sdk: String) throws -> [String] {
        var seen = Set<String>(), maps: [String] = []
        for object in objects {
            let dependencies = (object as NSString).deletingPathExtension + ".d"
            guard let text = try? String(contentsOfFile: dependencies, encoding: .utf8) else { continue }
            // Make-style dependency lists escape a space in a path as "\ ".
            let paths = text.replacingOccurrences(of: "\\ ", with: "\u{0}")
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\\" })
                .map { $0.replacingOccurrences(of: "\u{0}", with: " ") }
            for path in paths where path.hasSuffix(".modulemap") && !path.hasPrefix(sdk) && seen.insert(path).inserted {
                maps.append(path)
            }
        }
        return maps
    }

    /// `realpath` of the deepest existing ancestor, with the rest of the path appended. The output
    /// binary may not exist yet, and `resolvingSymlinksInPath` leaves a path alone when its last
    /// component is missing (measured), so it cannot be used here.
    static func canonicalPath(_ url: URL) -> String {
        var head = url.standardizedFileURL.path
        var tail: [String] = []
        while true {
            if let resolved = realpath(head, nil) {
                defer { free(resolved) }
                return tail.reversed().reduce(String(cString: resolved)) { ($0 as NSString).appendingPathComponent($1) }
            }
            let parent = (head as NSString).deletingLastPathComponent
            if parent == head || parent.isEmpty { return url.standardizedFileURL.path }
            tail.append((head as NSString).lastPathComponent)
            head = parent
        }
    }
}
