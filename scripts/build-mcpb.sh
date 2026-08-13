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

echo "Copying binary to mcpb/server/..."
cp .build/release/CheAppleMailMCP mcpb/server/

echo "Packaging mcpb..."
cd mcpb
rm -f che-apple-mail-mcp.mcpb
zip -r che-apple-mail-mcp.mcpb manifest.json icon.png PRIVACY.md server/

echo "Done! Package: mcpb/che-apple-mail-mcp.mcpb"
