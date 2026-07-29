import Foundation

/// #303 — surface MCP-server staleness. Pure, actor-free, filesystem-free.
///
/// A long-lived Claude Code window keeps its MCP server process alive across a
/// binary update, so the running image can lag the on-disk binary. The `#297`
/// timeout guard bounds a stuck *AppleScript execution* (a stale server
/// fast-fails the call and survives) — note it does NOT cover the caller-side
/// preflight this check runs in, which is why the sidecar read must be bounded
/// at the syscall (see `MailController.readVersionSidecar`, #303 verify B1).
/// Staleness is otherwise invisible — the user silently runs old features. This
/// helper turns the compiled self-version and the wrapper-written sidecar
/// version into a one-line actionable warning so the server can *say* it's
/// stale and nudge a restart.
///
/// It never refuses work and never throws — refusing would break a still-safe
/// (post-#297) session. It is deliberately conservative: it warns ONLY when the
/// on-disk binary is strictly newer than the running one, and fails open on every
/// ambiguous input.
enum StalenessCheck {
    /// Returns a warning string (naming both versions + restart guidance) iff
    /// both `compiled` and `sidecar` parse as `major.minor.patch` **and**
    /// `sidecar > compiled` (the running image is behind the installed binary).
    ///
    /// Returns `nil` — fail-open — for every other case: `sidecar` is `nil`
    /// (no sidecar found, e.g. a dev build run from `.build/` or a non-plugin
    /// install), unparseable on either side, or `sidecar <= compiled` (the
    /// running image is current or ahead). Fail-open is the whole point: a
    /// spurious "restart" nag on every ambiguous session would be worse than
    /// the (already-guarded) staleness it warns about.
    static func evaluate(compiled: String, sidecar: String?) -> String? {
        guard let sidecar,
              let running = SemVer(compiled),
              let onDisk = SemVer(sidecar),
              onDisk > running
        else { return nil }

        // #303 verify #3: interpolate the PARSED components, never the raw
        // sidecar bytes. Only the prefix before the first `-`/`+` is validated,
        // so a raw `2.26.0-<ANSI escapes / newlines / forged log lines>` would
        // otherwise reach stderr verbatim — and this stderr is collected into
        // ~/Library/Logs/Claude/mcp-server-*.log, which people `tail -f`.
        // Ints cannot carry control characters, so this closes the injection
        // at the type level rather than by filtering.
        return "che-apple-mail-mcp is running a stale binary v\(running.major).\(running.minor).\(running.patch); "
            + "v\(onDisk.major).\(onDisk.minor).\(onDisk.patch) is installed on disk. "
            + "This session's MCP server started before the update — "
            + "restart Claude Code to load it."
    }
}

/// Minimal `major.minor.patch` comparison. Pre-release / build metadata (a `-`
/// or `+` suffix) is ignored — the release pipeline only ever emits clean
/// `vMAJOR.MINOR.PATCH` tags — and any non-numeric or wrong-arity input parses
/// to `nil` so the caller fails open.
struct SemVer: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ raw: String) {
        // #303 verify #4: a LEADING `-`/`+` is a malformed version, not a
        // suffix — and `split(whereSeparator:)` omits empty subsequences, so
        // `"-1.2.3"` used to yield `["1.2.3"]` and parse as 1.2.3. Reject it
        // explicitly before splitting; everything from the first separator
        // onward is still discarded as documented above.
        guard let firstChar = raw.first, firstChar != "-", firstChar != "+" else { return nil }
        let core = raw.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? raw
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]),
              a >= 0, b >= 0, c >= 0
        else { return nil }
        (major, minor, patch) = (a, b, c)
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
