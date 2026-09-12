import XCTest
@testable import CheAppleMailMCP

/// #395 — slash-command authorization guard.
///
/// `/archive-mail` used to pre-authorize the ENTIRE mail tool set via a
/// `mcp__plugin_che-apple-mail-mcp_mail__*` wildcard — including
/// delete/compose/move/junk, none of which an archival command has any use
/// for. #395 replaced that with an explicit enumeration, but an enumeration
/// only stays correct while something checks it: this repo's own history
/// (#233, #248) shows doc↔`defineTools()` drift is recurrent, and the
/// enumeration is exactly the kind of list a future step silently outgrows.
///
/// Five invariants, each locking a defect this repo has actually shipped:
///   1. every command file declares `allowed-tools` (the repair command
///      shipped with NO frontmatter at all — broader than the wildcard #395
///      removed, since a command without frontmatter is unrestricted);
///   2. no wildcard mail authorization anywhere;
///   3. every mail tool a command's prose actually invokes is in its own
///      allow-list (the drift guard — a new step that calls a new tool fails
///      here instead of prompting the user at runtime);
///   4. every allow-listed mail tool exists in `defineTools()` (no phantom
///      names, which would silently authorize nothing and mask a typo);
///   5. archive and repair commands grant exactly their required tool sets.
final class CommandAllowedToolsGuardTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CheAppleMailMCPTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private static let mailPrefix = "mcp__plugin_che-apple-mail-mcp_mail__"

    private struct Command {
        let name: String
        let allowedTools: [String]
        let body: String
        /// Non-nil when the frontmatter is in a shape this guard refuses to
        /// interpret (see loadCommands). Reported as a failure, never ignored.
        let formatError: String?
    }

    /// Parse every `plugin/commands/*.md` into (name, allow-list, body).
    /// A file whose frontmatter is missing or carries no `allowed-tools` is
    /// returned with an empty list so invariant 1 can fail on it by name.
    private func loadCommands() throws -> [Command] {
        let dir = Self.repoRoot.appendingPathComponent("plugin/commands")
        let files = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "plugin/commands holds no .md files — wrong path?")

        return try files.map { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            let name = url.deletingPathExtension().lastPathComponent
            guard text.hasPrefix("---\n"),
                  let close = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex)
            else {
                return Command(name: name, allowedTools: [], body: text, formatError: nil)
            }
            let frontmatter = String(text[text.index(text.startIndex, offsetBy: 4)..<close.lowerBound])
            let body = String(text[close.upperBound...])
            // This is deliberately NOT a YAML parser, and that gap is a real
            // risk: a hand-rolled reader and the host's real loader can
            // disagree, and the disagreement is exploitable. #395 round 3
            // showed the shape — a flow sequence
            //     allowed-tools: ["mcp__…_mail__*", search_emails, …]
            // makes the first comma-token end in a QUOTE, so a `hasSuffix("*")`
            // wildcard check misses it, while the host sees a real wildcard.
            //
            // Rather than grow a parser, refuse anything that is not the one
            // canonical form this repo uses: a single line of comma-separated
            // bare scalars. Every other spelling fails loudly here instead of
            // being read differently by the two readers.
            let fmLines = frontmatter.split(separator: "\n", omittingEmptySubsequences: false)
            // Fail closed for the entire small metadata grammar used here.
            // Looking only for a literal allowed-tools: line misses a second
            // quoted/indented/escaped YAML key that another loader may read.
            let knownKeys: Set<String> = ["description", "argument-hint", "allowed-tools"]
            var seenKeys = Set<String>()
            for line in fmLines where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else {
                    return Command(name: name, allowedTools: [], body: body,
                                   formatError: "non-canonical frontmatter line")
                }
                let key = String(line[..<colon])
                guard knownKeys.contains(key), seenKeys.insert(key).inserted else {
                    return Command(name: name, allowedTools: [], body: body,
                                   formatError: "unsupported or duplicate frontmatter key: \(key)")
                }
            }
            let matching = fmLines.filter { $0.hasPrefix("allowed-tools:") }
            guard matching.count <= 1 else {
                return Command(name: name, allowedTools: [], body: body,
                               formatError: "duplicate `allowed-tools:` keys (\(matching.count))")
            }
            guard let line = matching.first else {
                return Command(name: name, allowedTools: [], body: body,
                               formatError: nil)   // absent — invariant 1 reports it
            }
            let value = line.dropFirst("allowed-tools:".count).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("[") || value.hasPrefix("{")
                || value.hasPrefix("\"") || value.hasPrefix("'")
                || value.hasPrefix("|") || value.hasPrefix(">") || value.isEmpty {
                return Command(name: name, allowedTools: [], body: body,
                               formatError: "non-canonical `allowed-tools:` value — this repo "
                                 + "requires one line of comma-separated bare scalars, so the "
                                 + "guard and the host cannot read it differently")
            }
            let tools = value
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let tokenPattern = #"^[A-Za-z][A-Za-z0-9_*-]*(?:\([A-Za-z0-9_./: *-]+\))?$"#
            guard tools.allSatisfy({ $0.range(of: tokenPattern, options: .regularExpression) != nil }) else {
                return Command(name: name, allowedTools: [], body: body,
                               formatError: "allowed-tools contains a non-canonical permission token")
            }
            return Command(name: name, allowedTools: tools, body: body, formatError: nil)
        }
    }

    /// Mail tools a command's prose actually invokes.
    ///
    /// Two shapes, both used by the SOP: the fully-prefixed name, and the
    /// bare name in call position (`` `save_attachment(…)` ``). Bare names are
    /// matched ONLY when followed by `(` — prose that merely *mentions* a tool
    /// ("`delete_email` 必須 confirm") is not an invocation and must not force
    /// it into an allow-list. `\b` keeps `batch_export_emails_markdown(` from
    /// registering as a call to the deprecated `export_emails_markdown` alias.
    private func invokedMailTools(in body: String, knownNames: Set<String>) throws -> Set<String> {
        var found = Set<String>()

        let prefixed = try NSRegularExpression(pattern: Self.mailPrefix + #"([a-z0-9_]+)"#)
        let range = NSRange(body.startIndex..., in: body)
        prefixed.enumerateMatches(in: body, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: body) else { return }
            let name = String(body[r])
            // A fully-prefixed name declares a mail invocation even if it is
            // misspelled. Filtering against knownNames would silently hide it.
            found.insert(name)
        }

        let bareCall = try NSRegularExpression(pattern: #"\b([a-z0-9_]+)\("#)
        bareCall.enumerateMatches(in: body, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: body) else { return }
            let name = String(body[r])
            if knownNames.contains(name) { found.insert(name) }
        }
        return found
    }

    func testEveryCommandDeclaresAllowedTools() throws {
        for command in try loadCommands() {
            XCTAssertNil(command.formatError,
                "plugin/commands/\(command.name).md: \(command.formatError ?? "")")
            XCTAssertFalse(command.allowedTools.isEmpty,
                "plugin/commands/\(command.name).md declares no `allowed-tools` — a command "
                + "without one is UNRESTRICTED, i.e. broader than the wildcard #395 removed.")
        }
    }

    func testNoWildcardMailAuthorization() throws {
        for command in try loadCommands() {
            for tool in command.allowedTools {
                XCTAssertFalse(tool.contains(Self.mailPrefix) && tool.hasSuffix("*"),
                    "plugin/commands/\(command.name).md pre-authorizes mail tools by wildcard "
                    + "(\(tool)) — enumerate the tools the command actually invokes (#395).")
            }
        }
    }

    func testInvokedMailToolsAreAuthorized() throws {
        let known = Set(CheAppleMailMCPServer.defineTools().map(\.name))
        for command in try loadCommands() {
            let authorized = Set(command.allowedTools
                .filter { $0.hasPrefix(Self.mailPrefix) }
                .map { String($0.dropFirst(Self.mailPrefix.count)) })
            let invoked = try invokedMailTools(in: command.body, knownNames: known)
            let unauthorized = invoked.subtracting(authorized).sorted()
            XCTAssertTrue(unauthorized.isEmpty,
                "plugin/commands/\(command.name).md invokes mail tool(s) missing from its own "
                + "`allowed-tools`: \(unauthorized.joined(separator: ", ")). Either add them or "
                + "stop calling them — a step that needs an unauthorized tool prompts the user "
                + "mid-run (#395).")
        }
    }

    func testArchiveCommandsAuthorizeExactlyTheirRequiredSets() throws {
        let commands = try loadCommands()
        let policies: [(String, Set<String>, Set<String>)] = [
            ("archive-mail", [
                "search_emails", "get_email", "get_email_headers", "list_accounts",
                "get_special_mailboxes", "list_attachments", "list_attachments_batch",
                "save_attachment", "batch_export_emails_markdown",
            ], ["Bash(mkdir:*)", "Read", "Write", "Glob"]),
            ("archive-mail-repair-synthetic-ids", [
                "search_emails", "get_email_headers",
            ], ["Read", "Write", "Glob"]),
        ]
        for (name, expectedMail, expectedOther) in policies {
            let command = try XCTUnwrap(commands.first { $0.name == name }, "Missing command: \(name)")
            XCTAssertNil(command.formatError, "\(name): \(command.formatError ?? "")")
            let authorizedMail = Set(command.allowedTools
                .filter { $0.hasPrefix(Self.mailPrefix) }
                .map { String($0.dropFirst(Self.mailPrefix.count)) })
            XCTAssertEqual(authorizedMail, expectedMail,
                "\(name) must authorize exactly its required mail tools; extra deletion/compose grants are the #395 defect.")
            let nonMail = Set(command.allowedTools.filter { !$0.hasPrefix(Self.mailPrefix) })
            XCTAssertEqual(nonMail, expectedOther,
                "\(name) non-mail authority changed; broad Bash grants must not bypass the mail-scoped checks.")
        }
    }

    func testAuthorizedMailToolsExist() throws {
        let known = Set(CheAppleMailMCPServer.defineTools().map(\.name))
        for command in try loadCommands() {
            for tool in command.allowedTools where tool.hasPrefix(Self.mailPrefix) {
                let name = String(tool.dropFirst(Self.mailPrefix.count))
                XCTAssertTrue(known.contains(name),
                    "plugin/commands/\(command.name).md allow-lists `\(name)`, which is not in "
                    + "defineTools() — a phantom name authorizes nothing and hides the typo.")
            }
        }
    }

    func testShippedArchiveRecipes() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", Self.repoRoot.appendingPathComponent("plugin/tests/test-archive-mail-recipes.py").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       String(data: data, encoding: .utf8) ?? "recipe runner produced non-UTF8 output")
    }
}
