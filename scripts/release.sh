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

# Validate version format: v<major>.<minor>.<patch>
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "version must match vMAJOR.MINOR.PATCH (got: $VERSION)"
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

# CHANGELOG must have an entry for this version
if ! grep -q "^## \[$VERSION_NO_V\]" CHANGELOG.md; then
    die "CHANGELOG.md has no entry for [$VERSION_NO_V]. add one before releasing."
fi

# mcpb/manifest.json must agree with the tag (#311). The field had no owner in
# the release pipeline and froze at 2.7.2 for ~18 releases — masked because
# Server.swift's then-hardcoded handshake version had rotted to the same value.
# Fail-closed check (not auto-edit: this script requires a clean tree, so
# editing mid-release would contradict its own precondition). Parse with
# python3 json, not grep — the file is JSON, so read it as JSON.
MANIFEST_VERSION=$(python3 -c "import json; print(json.load(open('mcpb/manifest.json'))['version'])" 2>/dev/null || true)
if [[ -z "$MANIFEST_VERSION" ]]; then
    die "could not read version from mcpb/manifest.json (missing file or invalid JSON)."
fi
if [[ "$MANIFEST_VERSION" != "$VERSION_NO_V" ]]; then
    die "mcpb/manifest.json version is '$MANIFEST_VERSION' but releasing '$VERSION_NO_V'.
  Bump it alongside the CHANGELOG entry (ManifestVersionTests pins the same invariant in CI)."
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
# EXIT, not RETURN: this runs inside a `$( )` subshell, not a function. bash
# only honors a RETURN trap inside a function body, so the original spelling
# never fired and leaked a temp dir (holding a compiled binary) on every
# release. EXIT fires when the subshell ends, which is exactly the scope here.
APP_VERSION=$(
    tmp=$(mktemp -d) || exit 0          # empty output → the -z check below dies
    trap 'rm -rf "$tmp"' EXIT
    cp "$VERSION_SWIFT" "$tmp/Version.swift"
    printf 'print(AppVersion.current)\n' > "$tmp/main.swift"
    xcrun swiftc -O "$tmp/Version.swift" "$tmp/main.swift" -o "$tmp/probe" 2>/dev/null \
        && "$tmp/probe" 2>/dev/null
)
if [[ -z "$APP_VERSION" ]]; then
    die "could not read AppVersion.current from $VERSION_SWIFT.
  The probe compiles that file and prints the value, so an empty result means one of:
    - xcrun/swiftc unavailable (check: xcrun swiftc --version)
    - $VERSION_SWIFT no longer compiles standalone (a new import or dependency?)
    - mktemp failed
  Fails closed by design: without a verified version we will not tag a release."
fi
if [[ "$APP_VERSION" != "$VERSION_NO_V" ]]; then
    die "version drift: AppVersion.current is '$APP_VERSION' but releasing '$VERSION_NO_V'. Update $VERSION_SWIFT to '$VERSION_NO_V' first."
fi

info "Sanity checks passed."

# ---- Extract release notes ---------------------------------------------------
# Pull the section between "## [VERSION]" and the next "## [" header.

info "Extracting release notes from CHANGELOG.md..."

RELEASE_NOTES="$(
    awk -v ver="$VERSION_NO_V" '
        $0 ~ "^## \\[" ver "\\]" { capture = 1; next }
        capture && /^## \[/ { capture = 0 }
        capture && /^---$/ { next }
        capture { print }
    ' CHANGELOG.md | sed -e '/./,$!d' -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
)"

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
