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
BINARY_PATH=".build/release/$BINARY_NAME"

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

# ---- Build binary ------------------------------------------------------------

info "Building release binary..."
swift build -c release

if [[ ! -f "$BINARY_PATH" ]]; then
    die "expected binary at $BINARY_PATH but it's missing. build failed?"
fi

BINARY_SIZE="$(ls -lh "$BINARY_PATH" | awk '{print $5}')"
info "Binary built: $BINARY_PATH ($BINARY_SIZE)"

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
    1. Create git tag $VERSION on HEAD
    2. Push tag to origin
    3. Create GitHub release $VERSION
    4. Upload $BINARY_NAME as release asset

EOF
read -p "Proceed? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Aborted."
    exit 0
fi

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

info "Uploading $BINARY_NAME..."
gh release upload "$VERSION" "$BINARY_PATH" --repo "$REPO"

# ---- Done --------------------------------------------------------------------

info "Release $VERSION published successfully."
echo
echo "View at: https://github.com/$REPO/releases/tag/$VERSION"
echo
echo "Next steps:"
echo "    - Update marketplace.json version in psychquant-claude-plugins"
echo "    - /plugin marketplace update psychquant-claude-plugins"
echo "    - /plugin update che-apple-mail-mcp@psychquant-claude-plugins"
