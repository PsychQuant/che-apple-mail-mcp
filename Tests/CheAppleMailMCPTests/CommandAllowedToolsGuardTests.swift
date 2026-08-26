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
/// Four invariants, each locking a defect this repo has actually shipped:
///   1. every command file declares `allowed-tools` (the repair command
///      shipped with NO frontmatter at all — broader than the wildcard #395
///      removed, since a command without frontmatter is unrestricted);
///   2. no wildcard mail authorization anywhere;
///   3. every mail tool a command's prose actually invokes is in its own
///      allow-list (the drift guard — a new step that calls a new tool fails
///      here instead of prompting the user at runtime);
///   4. every allow-listed mail tool exists in `defineTools()` (no phantom
///      names, which would silently authorize nothing and mask a typo).
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
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
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
            if knownNames.contains(name) { found.insert(name) }
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

    func testArchiveMailAuthorizesExactlyTheArchivalSet() throws {
        // #395 round 3, and the sharpest finding of that round: every other
        // invariant here checks `invoked ⊆ authorized` — i.e. too FEW tools.
        // #395's actual defect was the opposite direction: a wildcard
        // pre-authorizing all 53 mail tools. Appending
        // `…_mail__delete_email` to the allow-list passed all four invariants,
        // because it is non-empty, not a wildcard, not invoked, and does exist
        // in defineTools(). The guard did not cover the direction it was
        // written for.
        //
        // For this one security-sensitive command, pin set EQUALITY. An
        // archival command's authority is a closed list, so widening it must
        // be a conscious edit here, in the same commit.
        let expected: Set<String> = [
            "search_emails", "get_email", "get_email_headers", "list_accounts",
            "get_special_mailboxes", "list_attachments", "list_attachments_batch",
            "save_attachment", "batch_export_emails_markdown",
        ]
        let command = try XCTUnwrap(try loadCommands().first { $0.name == "archive-mail" },
                                    "plugin/commands/archive-mail.md not found")
        XCTAssertNil(command.formatError, "archive-mail frontmatter: \(command.formatError ?? "")")

        let authorizedMail = Set(command.allowedTools
            .filter { $0.hasPrefix(Self.mailPrefix) }
            .map { String($0.dropFirst(Self.mailPrefix.count)) })
        let extra = authorizedMail.subtracting(expected).sorted()
        let absent = expected.subtracting(authorizedMail).sorted()
        XCTAssertTrue(extra.isEmpty,
            "/archive-mail authorizes mail tool(s) beyond the archival set: \(extra). "
            + "Archiving never needs to delete, compose, move or junk anything — that breadth "
            + "IS the #395 defect. Widening this list requires editing `expected` here.")
        XCTAssertTrue(absent.isEmpty,
            "/archive-mail no longer authorizes: \(absent) — if a step stopped using one, "
            + "remove it from `expected` in the same commit.")

        // Non-mail authority is a closed list too: `Bash(*)` carries no mail
        // prefix, so none of the mail-scoped invariants would ever see it.
        let nonMail = Set(command.allowedTools.filter { !$0.hasPrefix(Self.mailPrefix) })
        XCTAssertEqual(nonMail, ["Bash(mkdir:*)", "Read", "Write", "Glob"],
            "/archive-mail's non-mail authority changed. `Bash(mkdir:*)` is deliberately the "
            + "narrowest form; a broader Bash grant would be invisible to every other check here.")
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
}
