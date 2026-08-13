#!/bin/bash
# Build MCPB package for Claude Desktop

set -e

cd "$(dirname "$0")/.."

# The tools array must match the registered tools BEFORE anything is zipped
# (#348). The gate used to live only in release.sh — but this script is the
# actual entry point that produces the .mcpb, and release.sh does not even
# upload one yet, so a drifted manifest could be packaged and shipped by hand
# without ever passing the check.
echo "Verifying mcpb/manifest.json against the registered tools..."
GATE_LOG="$(mktemp -t che-mail-mcpb-gate)"
trap 'rm -f "$GATE_LOG"' EXIT
if ! swift test --filter 'ManifestToolsSetEqualityTests' > "$GATE_LOG" 2>&1; then
    grep -E "ABSENT from|NOT registered|duplicate tool names|descriptions differ|error:" "$GATE_LOG" >&2 || cat "$GATE_LOG" >&2
    echo "" >&2
    echo "error: mcpb/manifest.json does not match the registered tools (#348)." >&2
    echo "  Regenerate: REGENERATE_MCPB_MANIFEST=1 swift test --filter ManifestToolsSetEqualityTests" >&2
    exit 1
fi

echo "Building release..."
swift build -c release

# #323: this script is a DEV convenience, not a distribution path. It builds
# for the host arch only and leaves the binary ad-hoc signed — measured:
# arm64-only, flags=0x20002(adhoc,linker-signed), TeamIdentifier=not set. On
# macOS 26 such a binary cannot even trigger a TCC dialog (#211), so a bundle
# built here can never be granted Full Disk Access by the user who installs it.
#
# Packaging itself now lives in ONE place (scripts/package-mcpb.sh), which
# refuses an undistributable binary unless told explicitly that this is a dev
# build. Ship with: make release-signed VERSION=vX.Y.Z
MCPB_ALLOW_UNSIGNED=1 ./scripts/package-mcpb.sh \
    .build/release/CheAppleMailMCP \
    mcpb/che-apple-mail-mcp-dev.mcpb
