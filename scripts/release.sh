#!/bin/bash
#
# Release a new version of che-apple-mail-mcp end-to-end:
#   1. Sanity checks (clean tree, tag not already present, CHANGELOG entry exists)
#   2. Build release binary
#   3. Create git tag on HEAD
#   4. Push tag to origin
#   5. Create GitHub release
#   6. Upload binary (and future: mcpb bundle) as release assets
#
# Usage:
#   ./scripts/release.sh <version> [<release-title>]
#
# Example:
#   ./scripts/release.sh v2.1.2 "v2.1.2: list_accounts EWS display_name"
#
# The release notes are automatically extracted from CHANGELOG.md's matching
# version section. If the title is omitted, defaults to "<version>".
#
# This script is the formalized replacement for the error-prone manual sequence
# that previously forgot to upload the v2.1.1 binary (#13).

set -euo pipefail

# ---- Config ------------------------------------------------------------------

REPO="PsychQuant/che-apple-mail-mcp"
BINARY_NAME="CheAppleMailMCP"
# Distribution artifact: a signed + notarized UNIVERSAL (arm64 + x86_64) binary,
# lipo'd into a dedicated dist dir so the per-arch .build trees stay untouched.
DIST_DIR=".build/dist"
BINARY_PATH="$DIST_DIR/$BINARY_NAME"

# ---- Helpers -----------------------------------------------------------------

die() {
    echo "error: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

# ---- Argument parsing --------------------------------------------------------

if [[ $# -lt 1 ]]; then
    die "usage: $0 <version> [<release-title>]

Example:
    $0 v2.1.2
    $0 v2.1.2 \"v2.1.2: list_accounts EWS display_name\""
fi

VERSION="$1"
TITLE="${2:-$VERSION}"

# Validate the tag against the rules the RUNTIME parser actually applies
# (#303 verify round 8, cross-model). The byte-exact probes further down only
# guarantee "manifest == Version.swift == tag"; they say nothing about whether
# that agreed-upon value is one `SemVer()` can parse. Three ways the previous
# `[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]` accepted a tag that `SemVer()`
# then rejected — shipping a self-consistent but unparseable version, which
# silently disables staleness detection exactly like R6/R7 did:
#   1. `shopt -s nocasematch` (a `BASH_ENV` away) makes the pattern accept
#      `V2.27.0`, and `${VERSION#v}` does not strip a capital V.
#   2. bash's `[0-9]` is locale-sensitive: under some collations it matches
#      characters that are not ASCII digits (`vA.27.0` was accepted).
#   3. the components were unbounded, so `v9223372036854775808.0.0` passed and
#      then overflowed Swift's `Int` inside `SemVer()`.
# Same lesson as rounds 1-3 and 6-7 in a third costume: validate with the thing
# that will actually consume the value. Python's `[0-9]` is ASCII by definition
# and case-sensitivity is not a global toggle.
#
# The digit bound is `{1,19}`, not `{1,18}` (#303 verify round 9): `Int64`'s
# ceiling 9223372036854775807 is 19 digits, so an 18-digit cap REJECTED values
# `SemVer()` parses happily — e.g. `v1000000000000000000.0.0` — blocking a
# release the old check allowed. The regex now admits every 19-digit component
# and the `2**63 - 1` test does the real bounding; that test is load-bearing,
# not decoration, since 19 digits reach past Int64.
#
# How this compares to `SemVer()` — measured against the real parser, not
# assumed (#303 verify round 10 caught the previous version of this comment
# asserting two asymmetries that do not exist):
#   `01.02.03`   both accept  (`Int("01")` is 1; the regex allows leading zeros)
#   `1.+1.0`     both reject  (`+` is a suffix separator, so SemVer sees 2 parts)
#   `2.27.0-rc1` DIFFER: SemVer accepts it as 2.27.0 — it discards a `-`/`+`
#                suffix by design — while this validator refuses the tag.
# The direction of every difference is the same: `SemVer()` COERCES a range of
# inputs to a version, this validator insists on the canonical `vN.N.N` form
# with each component at most 19 digits. So anything SemVer would coerce —
# a `-`/`+` suffix, or zero-padding past the digit cap (`v0…01.0.0`, which
# SemVer reads as 1.0.0) — is refused at TAG time. Deliberate: the validator
# gates what we cut, `SemVer()` parses what we later read, and being tighter on
# the way out is fine provided it never blocks a sane release — precisely what
# round 9's finding was about. (No exhaustive claim here: rounds 10 and 11 each
# falsified a "these are the only differences" sentence in this very comment.)
if ! LC_ALL=C python3 - "$VERSION" <<'PY'
import re, sys
m = re.fullmatch(r'v([0-9]{1,19})\.([0-9]{1,19})\.([0-9]{1,19})', sys.argv[1])
if not m:
    sys.exit(1)
if any(int(g) > 2**63 - 1 for g in m.groups()):   # 19 digits can exceed Int64
    sys.exit(1)
PY
then
    die "version must match vMAJOR.MINOR.PATCH — ASCII decimal components, each within Swift's Int,
  so the value round-trips through the same SemVer() the server parses at runtime (got: $VERSION)"
fi

# Strip leading 'v' for CHANGELOG lookup
VERSION_NO_V="${VERSION#v}"

# ---- Sanity checks -----------------------------------------------------------

info "Running sanity checks..."

# Must be run from repo root
if [[ ! -f "Package.swift" ]] || [[ ! -f "CHANGELOG.md" ]]; then
    die "run this script from the repo root (where Package.swift lives)"
fi

# Clean working tree
if [[ -n "$(git status --porcelain)" ]]; then
    die "working tree not clean. commit or stash changes before releasing."
fi

# Tag must not already exist locally
if git rev-parse "refs/tags/$VERSION" >/dev/null 2>&1; then
    die "tag $VERSION already exists locally. delete it first or use a new version."
fi

# Tag must not already exist on origin
if git ls-remote --tags origin "refs/tags/$VERSION" | grep -q "$VERSION"; then
    die "tag $VERSION already exists on origin. delete it first or use a new version."
fi

# HEAD must be pushed to origin
LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse origin/main 2>/dev/null || echo "")"
if [[ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]]; then
    die "local HEAD ($LOCAL_HEAD) differs from origin/main ($REMOTE_HEAD).
        push your commits first: git push origin main"
fi

# CHANGELOG must have an entry for this version.
#
# Via scripts/changelog.py — the repo's single definition of a released header
# (#349). The bare grep this replaced accepted a `## [x.y.z]` line inside a
# fenced code block, and it was one of three parsers in the repo that could
# disagree with each other about what "a release" is.
if ! python3 scripts/changelog.py has "$VERSION_NO_V" CHANGELOG.md; then
    die "CHANGELOG.md has no released entry for [$VERSION_NO_V] (a header inside a
  fenced code block does not count). add one before releasing."
fi

# mcpb/manifest.json must agree with the tag (#311). The field had no owner in
# the release pipeline and froze at 2.7.2 for ~18 releases — masked because
# Server.swift's then-hardcoded handshake version had rotted to the same value.
# Fail-closed check (not auto-edit: this script requires a clean tree, so
# editing mid-release would contradict its own precondition). Parse with
# python3 json, not grep — the file is JSON, so read it as JSON.
#
# COMPARE THE BYTES WHERE THEY LIVE — never in a bash variable (#303 verify
# rounds 6-7, cross-model). Two rounds attacked this comparison and each fix
# only covered the byte it was shown:
#   R6: `$( )` strips EVERY trailing newline, so a manifest holding
#       `"2.27.0\n"` normalized to `2.27.0` and passed. An "X-guard" sentinel
#       fixed that instance.
#   R7: a bash variable CANNOT HOLD A NUL AT ALL — command substitution drops
#       `\0` regardless of any sentinel — so a value of `"2.27.0<NUL>"`
#       still arrived as `2.27.0` and passed.
# The class is "bash string equality is not byte equality", and no amount of
# quoting closes it. So the value never enters a variable: python compares it
# in-process against the tag and communicates only an exit status. Any byte
# that differs — NUL, LF, CR, space, anything — fails, and the diagnostic
# prints a repr so the offending bytes are visible.
if ! python3 - "$VERSION_NO_V" <<'PY'
import json, sys
want = sys.argv[1]
try:
    got = json.load(open('mcpb/manifest.json'))['version']
except Exception as exc:                       # missing file / invalid JSON / no key
    print(f"    could not read version from mcpb/manifest.json: {exc}", file=sys.stderr)
    sys.exit(2)
if not isinstance(got, str) or got != want:
    print(f"    manifest version is {got!r}, releasing {want!r}", file=sys.stderr)
    sys.exit(1)
PY
then
    die "mcpb/manifest.json version does not match '$VERSION_NO_V' (exact bytes shown above).
  Bump it alongside the CHANGELOG entry (ManifestVersionTests pins the same invariant in CI)."
fi

# mcpb/manifest.json's `tools` ARRAY must list exactly the registered tools (#348).
# Same rot as the `version` field one line up, one field over: no owner, so it
# drifted to 47 entries against 53 registered — the packaged .mcpb advertised an
# incomplete tool surface (both TCC probes' names, update_draft, and both names
# of the batch export were missing).
#
# Unlike the checks above this one CANNOT be evaluated statically: the authority
# is `defineTools()`, which only exists once Swift compiles. So rather than
# reimplementing name extraction in bash — a second spec that would drift from
# the first — run the test that already owns the invariant. There is no CI in
# this repo (no .github/workflows), so without this line nothing forces that
# test to run before a release, which is the whole gap #311 was about.
# mktemp, not a fixed /tmp path: another local user can pre-create a symlink at
# a predictable name, and the redirect would then follow it and truncate the
# target with the release runner's privileges.
MANIFEST_GATE_LOG="$(mktemp -t che-mail-manifest-tools-gate)"
trap 'rm -f "$MANIFEST_GATE_LOG"' EXIT
if ! swift test --filter 'ManifestToolsSetEqualityTests' > "$MANIFEST_GATE_LOG" 2>&1; then
    grep -E "ABSENT from|NOT registered|duplicate tool names|descriptions differ|error:" \
        "$MANIFEST_GATE_LOG" >&2 || true
    die "mcpb/manifest.json's tools array does not match the registered tools (#348).
  Full output was shown above.
  Reproduce:   swift test --filter ManifestToolsSetEqualityTests
  Regenerate:  REGENERATE_MCPB_MANIFEST=1 swift test --filter ManifestToolsSetEqualityTests"
fi

# AppVersion.current (the server's self-reported version) MUST match the tag (#303).
# This is what makes the "2.7.2"-rot impossible to repeat: the compiled MCP handshake
# serverVersion + the staleness-check baseline both read AppVersion.current, so a tag
# that disagrees with Version.swift is a release-blocking drift, not a silent mismatch.
VERSION_SWIFT="Sources/CheAppleMailMCP/Version.swift"
if [[ ! -f "$VERSION_SWIFT" ]]; then
    die "$VERSION_SWIFT not found — cannot verify AppVersion.current matches $VERSION_NO_V."
fi
# COMPILE the value; do not parse for it (#303 verify rounds 1-3).
#
# Three text-matching attempts were defeated in sequence, each by a different
# piece of legal Swift, and each "fix" only covered the instance it was shown:
#   1. unanchored grep matched `// static let current = "9.9.9"`.
#   2. anchoring at line start missed a block comment, whose inner line begins
#      with `static`.
#   3. a hand-rolled comment stripper missed NESTED block comments (Swift
#      permits them; a boolean cannot track depth) and, more fundamentally,
#      missed a multi-line string literal containing a fake declaration:
#          private static let example = """
#          static let current = "9.9.9"
#          """
#      which is not a comment at all and no comment-stripper can help with.
#
# Every one of those would have shipped a binary whose handshake version
# disagreed with its tag — silently. The class is "recognising Swift requires a
# Swift parser", so ask the compiler for the value instead of guessing at it.
# This is also less code than the lexer it replaces.
# EXIT, not RETURN: this runs inside a subshell, not a function. bash only
# honors a RETURN trap inside a function body, so the original spelling never
# fired and leaked a temp dir (holding a compiled binary) on every release.
# EXIT fires when the subshell ends, which is exactly the scope here.
#
# The probe writes the value to a FILE and compares with `cmp` inside the
# subshell; it never crosses into a bash variable (see the manifest probe's
# comment for why — R7's NUL case is unfixable at the variable layer). The
# subshell's exit status is the whole result; `if !` keeps a failure from
# tripping errexit before the diagnostic below can run (#303 verify round 4).
if ! (
    tmp=$(mktemp -d) || { echo "    mktemp failed" >&2; exit 3; }
    trap 'rm -rf "$tmp"' EXIT
    cp "$VERSION_SWIFT" "$tmp/Version.swift"
    printf 'print(AppVersion.current, terminator: "")\n' > "$tmp/main.swift"
    xcrun swiftc -O "$tmp/Version.swift" "$tmp/main.swift" -o "$tmp/probe" 2>"$tmp/err" || {
        sed 's/^/    /' "$tmp/err" >&2      # surface WHY, don't swallow it
        exit 4
    }
    "$tmp/probe" > "$tmp/got" 2>/dev/null || { echo "    the probe crashed" >&2; exit 5; }
    printf '%s' "$VERSION_NO_V" > "$tmp/want"
    # `cmp` distinguishes 0 (same) / 1 (differ) / >1 (trouble: unreadable file,
    # cmp itself missing). Reporting >1 as "version mismatch" would be a false
    # diagnosis of a correct fail-closed (#303 verify round 8, LOW).
    cmp -s "$tmp/got" "$tmp/want"
    case $? in
        0) : ;;
        1) printf '    AppVersion.current, byte for byte (first 64):\n' >&2
           od -c "$tmp/got" | sed 's/^/      /' | head -4 >&2
           exit 1 ;;
        *) echo "    cmp could not compare the probe output (is cmp available?)" >&2
           exit 2 ;;
    esac
); then
    die "AppVersion.current in $VERSION_SWIFT does not match '$VERSION_NO_V' (bytes above, if the probe got that far).
  The probe compiles that file and compares the printed value byte for byte, so a failure means one of:
    - a real version drift → update $VERSION_SWIFT to '$VERSION_NO_V'
    - a malformed literal (stray NUL / newline / space inside the string)
    - xcrun/swiftc unavailable (check: xcrun swiftc --version)
    - $VERSION_SWIFT no longer compiles standalone (a new import or dependency?)
  Fails closed by design: without a verified version we will not tag a release."
fi

info "Sanity checks passed."

# ---- Extract release notes ---------------------------------------------------
# Pull the section between "## [VERSION]" and the next "## [" header.

info "Extracting release notes from CHANGELOG.md..."

# Same parser as the entry check and the two test guards (#349) — the awk this
# replaced was the third independent reading of the file's structure.
RELEASE_NOTES="$(python3 scripts/changelog.py notes "$VERSION_NO_V" CHANGELOG.md \
    | sed -e '/^---$/d')"

if [[ -z "$RELEASE_NOTES" ]]; then
    die "extracted release notes are empty. check CHANGELOG.md format for [$VERSION_NO_V]."
fi

info "Release notes (first 5 lines):"
echo "$RELEASE_NOTES" | head -5 | sed 's/^/    /'
echo "    ..."

# ---- Build universal binary --------------------------------------------------

info "Building release binary (universal: arm64 + x86_64)..."
swift build -c release --arch arm64
swift build -c release --arch x86_64

ARM64_BINARY=".build/arm64-apple-macosx/release/$BINARY_NAME"
X64_BINARY=".build/x86_64-apple-macosx/release/$BINARY_NAME"
if [[ ! -f "$ARM64_BINARY" || ! -f "$X64_BINARY" ]]; then
    die "expected per-arch binaries missing (arm64: $ARM64_BINARY, x86_64: $X64_BINARY). build failed?"
fi

mkdir -p "$DIST_DIR"
# rm -f forces a fresh inode (macOS caches code-signature hashes per inode;
# reusing one held by a running process causes "load code signature error 2").
rm -f "$BINARY_PATH"
lipo -create "$ARM64_BINARY" "$X64_BINARY" -output "$BINARY_PATH"
chmod +x "$BINARY_PATH"

# Validate (not just print) that both slices made it into the fat binary (#211).
ARCHS="$(lipo -archs "$BINARY_PATH")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] \
    || die "universal binary missing expected archs (got: $ARCHS)"

BINARY_SIZE="$(ls -lh "$BINARY_PATH" | awk '{print $5}')"
info "Universal binary built: $BINARY_PATH ($BINARY_SIZE), archs: $ARCHS"

# Interrogate the ACTUAL shipped artifact — every slice (#303 verify round 4).
#
# The earlier sanity check compiled Version.swift into a separate host-only
# probe. That guesses at the artifact rather than examining it, and a perfectly
# legal Version.swift can make the two disagree:
#     #if arch(x86_64)
#     static let current = "0.0.0"
#     #else
#     static let current = "2.25.0"
#     #endif
# The arm64 probe prints 2.25.0 and every check passes, while the Intel slice of
# the binary being signed and shipped reports 0.0.0 — wrong handshake version,
# wrong staleness baseline, silently. `#if compiler(...)` does the same (and this
# repo genuinely builds the probe and the slices with different toolchains).
# So ask each slice what it is, using the mode it exposes for exactly this.
for slice in $ARCHS; do
    # Byte-exact against the artifact, without a bash variable in the path.
    # `--version` prints the value plus one `print()` newline, so the expected
    # bytes are `<version>\n` and `cmp` decides. Two earlier spellings routed
    # the output through `$( )` and were defeated in turn — R6 by a trailing LF
    # inside the literal (stripped along with print()'s), R7 by a NUL, which a
    # bash variable cannot hold at all. Comparing files closes the whole class.
    if ! (
        tmp=$(mktemp -d) || { echo "    mktemp failed" >&2; exit 3; }
        trap 'rm -rf "$tmp"' EXIT
        arch -"$slice" "$BINARY_PATH" --version > "$tmp/got" 2>/dev/null || {
            echo "    the $slice slice failed to run --version" >&2; exit 5; }
        [[ -s "$tmp/got" ]] || { echo "    the $slice slice printed nothing" >&2; exit 6; }
        printf '%s\n' "$VERSION_NO_V" > "$tmp/want"
        cmp -s "$tmp/got" "$tmp/want"
        case $? in
            0) : ;;
            1) printf '    the %s slice reports, byte for byte (first 64):\n' "$slice" >&2
               od -c "$tmp/got" | sed 's/^/      /' | head -4 >&2
               exit 1 ;;
            *) echo "    cmp could not compare the $slice slice output" >&2
               exit 2 ;;
        esac
    ); then
        die "version mismatch in the SHIPPED binary: the $slice slice does not report '$VERSION_NO_V' (bytes above).
  A conditional or malformed AppVersion.current can make the host probe and the
  actual slices disagree — this check reads the artifact itself."
    fi
done
info "Both slices self-report $VERSION_NO_V."

# ---- Confirm with user -------------------------------------------------------

cat <<EOF

==========================================================================
About to release $VERSION with the following plan:

    Tag: $VERSION (on $LOCAL_HEAD)
    Title: $TITLE
    Binary: $BINARY_PATH ($BINARY_SIZE)
    Repo: $REPO
    Notes: extracted from CHANGELOG.md [$VERSION_NO_V]

This will:
    1. Sign + notarize the universal binary (unless SKIP_CODESIGN / no DEVELOPER_ID)
    2. Create git tag $VERSION on HEAD
    3. Push tag to origin
    4. Create GitHub release $VERSION
    5. Upload $BINARY_NAME (+ .sha256) as release assets

EOF
read -p "Proceed? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Aborted."
    exit 0
fi

# ---- Sign + notarize ---------------------------------------------------------
# macOS TCC keys the Full Disk Access grant to the binary's designated
# requirement. A Developer ID signature makes that grant stable across version
# bumps; an ad-hoc binary loses it every release (#211).
#
# Gate (fork-friendly):
#   SKIP_CODESIGN=1                    → skip (dev/emergency; ships ad-hoc binary)
#   no DEVELOPER_ID / cert not present → skip with warning (default for forks)
#   REQUIRE_CODESIGN=1                 → fail-fast instead of skipping
#                                        (set by `make release-signed`)
#   otherwise                          → sign + notarize
SHOULD_SIGN=true
SKIP_REASON=""
if [[ "${SKIP_CODESIGN:-}" == "1" || "${SKIP_CODESIGN:-}" == "true" ]]; then
    SHOULD_SIGN=false; SKIP_REASON="SKIP_CODESIGN=$SKIP_CODESIGN"
elif [[ -z "${DEVELOPER_ID:-}" ]]; then
    SHOULD_SIGN=false; SKIP_REASON="DEVELOPER_ID env not set"
elif ! security find-identity -p codesigning -v 2>/dev/null | grep -qF "$DEVELOPER_ID"; then
    SHOULD_SIGN=false; SKIP_REASON="codesigning identity '$DEVELOPER_ID' not in keychain"
fi

if [[ "$SHOULD_SIGN" == "false" ]]; then
    if [[ "${REQUIRE_CODESIGN:-}" == "1" || "${REQUIRE_CODESIGN:-}" == "true" ]]; then
        die "Refusing to ship an unsigned binary: REQUIRE_CODESIGN set but $SKIP_REASON.
        Set DEVELOPER_ID + NOTARY_PROFILE and install the Developer ID Application cert.
        See README 'Signing & Notarization'."
    fi
    info "Skipping Developer ID signing + notarize ($SKIP_REASON)."
    echo "    Applying an ad-hoc signature to the final universal binary —"
    echo "    lipo invalidates the per-arch signatures, and an unsigned arm64"
    echo "    binary can fail to launch (#211 CODEX-2)."
    codesign --force --sign - "$BINARY_PATH"
    echo "    ⚠ Ad-hoc signed only. On macOS, users must re-grant Full Disk Access"
    echo "      after every such release (#211). For a stable grant that survives"
    echo "      version bumps, set DEVELOPER_ID + NOTARY_PROFILE and re-run"
    echo "      (or use make release-signed)."
else
    info "Signing + notarizing the universal binary..."
    "$(dirname "$0")/sign-and-notarize.sh" "$BINARY_PATH"
fi

# SHA-256 companion of the (possibly signed) binary, uploaded alongside it.
shasum -a 256 "$BINARY_PATH" | awk '{print $1}' > "$BINARY_PATH.sha256"
info "SHA-256: $(cat "$BINARY_PATH.sha256")"

# ---- Tag + release + upload --------------------------------------------------

info "Creating git tag $VERSION..."
git tag -a "$VERSION" -m "$TITLE" "$LOCAL_HEAD"

info "Pushing tag to origin..."
git push origin "$VERSION"

info "Creating GitHub release..."
gh release create "$VERSION" \
    --repo "$REPO" \
    --title "$TITLE" \
    --notes "$RELEASE_NOTES"

info "Uploading $BINARY_NAME (+ .sha256)..."
gh release upload "$VERSION" "$BINARY_PATH" "$BINARY_PATH.sha256" --repo "$REPO"

# ---- Done --------------------------------------------------------------------

info "Release $VERSION published successfully."
echo
echo "View at: https://github.com/$REPO/releases/tag/$VERSION"
echo
echo "Next steps:"
echo "    - Update marketplace.json version in psychquant-claude-plugins"
echo "    - /plugin marketplace update psychquant-claude-plugins"
echo "    - /plugin update che-apple-mail-mcp@psychquant-claude-plugins"
