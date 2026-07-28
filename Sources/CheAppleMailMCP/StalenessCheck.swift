import Foundation

/// #303 — surface MCP-server staleness. Pure, actor-free, filesystem-free.
///
/// A long-lived Claude Code window keeps its MCP server process alive across a
/// binary update, so the running image can lag the on-disk binary. The `#297`
/// timeout guard already prevents such a stale server from hanging-to-disconnect
/// (a stuck call fast-fails, the server survives), but staleness is otherwise
/// invisible — the user silently runs old features. This helper turns the
/// compiled self-version and the wrapper-written sidecar version into a one-line
/// actionable warning so the server can *say* it's stale and nudge a restart.
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

        return "che-apple-mail-mcp is running a stale binary v\(compiled); "
            + "v\(sidecar) is installed on disk. This session's MCP server started "
            + "before the update — restart Claude Code to load it."
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
        // Strip a `-prerelease` / `+build` suffix before splitting on `.`.
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
