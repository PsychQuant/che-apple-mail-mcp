#!/bin/bash
#
# Package a .mcpb bundle around an ALREADY-BUILT binary (#323).
#
# This exists because `build-mcpb.sh` and `release.sh` used to be two unrelated
# pipelines. The release pipeline builds universal, Developer ID signs, and
# notarizes — because on macOS 26 an ad-hoc binary cannot even trigger a TCC
# dialog (#211), so it structurally cannot acquire the permissions this server
# needs. `build-mcpb.sh` did `swift build -c release` + `cp` + `zip`: measured
# on this machine, arm64-only and `flags=0x20002(adhoc,linker-signed)` with
# `TeamIdentifier=not set`. Desktop users installing the `.mcpb` therefore got a
# binary that could never be granted Full Disk Access.
#
# There is now ONE packaging implementation, and the caller supplies the binary:
# `release.sh` passes the signed+notarized universal one, `build-mcpb.sh` passes
# a dev build and must say so out loud.
#
# Usage:
#   scripts/package-mcpb.sh <binary-path> [output-path]
#
# Env:
#   MCPB_ALLOW_UNSIGNED=1   permit an ad-hoc / non-universal binary (dev only)

set -euo pipefail

BINARY="${1:?usage: package-mcpb.sh <binary-path> [output-path]}"
cd "$(dirname "$0")/.."

[[ -f "$BINARY" ]] || { echo "error: no binary at $BINARY" >&2; exit 1; }

VERSION=$(python3 -c "import json;print(json.load(open('mcpb/manifest.json'))['version'])")
OUTPUT="${2:-mcpb/che-apple-mail-mcp-${VERSION}.mcpb}"

# ---- Distribution gate ------------------------------------------------------
# Fails CLOSED. The whole point of #323 is that an unsigned bundle is not a
# lesser bundle — it is one that cannot work at all on a current macOS, and
# nothing downstream would have told the user why.
ARCHS=$(lipo -archs "$BINARY" 2>/dev/null || echo "")
SIGN_INFO=$(codesign -dvvv "$BINARY" 2>&1 || true)
TEAM=$(printf '%s' "$SIGN_INFO" | sed -nE 's/^TeamIdentifier=(.*)$/\1/p')

PROBLEMS=()
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || \
  PROBLEMS+=("not universal (archs: ${ARCHS:-unknown}) — Intel users get no slice")
[[ -n "$TEAM" && "$TEAM" != "not set" ]] || \
  PROBLEMS+=("not Developer ID signed (TeamIdentifier: ${TEAM:-none}) — macOS 26 TCC cannot grant it permissions (#211)")

if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
    if [[ "${MCPB_ALLOW_UNSIGNED:-}" == "1" ]]; then
        echo "⚠️  DEV BUNDLE — NOT DISTRIBUTABLE:" >&2
        for p in "${PROBLEMS[@]}"; do echo "      - $p" >&2; done
        echo "      Built anyway because MCPB_ALLOW_UNSIGNED=1. Do not ship this." >&2
    else
        echo "error: refusing to package a bundle that cannot work for its users (#323):" >&2
        for p in "${PROBLEMS[@]}"; do echo "      - $p" >&2; done
        echo "" >&2
        echo "  Ship via:  make release-signed VERSION=vX.Y.Z" >&2
        echo "  Dev only:  MCPB_ALLOW_UNSIGNED=1 $0 $BINARY" >&2
        exit 1
    fi
fi

# ---- Package ----------------------------------------------------------------
mkdir -p mcpb/server
cp "$BINARY" mcpb/server/CheAppleMailMCP
chmod +x mcpb/server/CheAppleMailMCP

rm -f "$OUTPUT"
( cd mcpb && zip -qr "$(basename "$OUTPUT")" manifest.json icon.png PRIVACY.md server/ )
[[ "$(dirname "$OUTPUT")" == "mcpb" ]] || mv "mcpb/$(basename "$OUTPUT")" "$OUTPUT"

shasum -a 256 "$OUTPUT" | awk '{print $1}' > "$OUTPUT.sha256"

echo "→ packaged $OUTPUT"
echo "   binary : ${ARCHS:-unknown}${TEAM:+, TeamIdentifier=$TEAM}"
echo "   version: $VERSION"
echo "   sha256 : $(cat "$OUTPUT.sha256")"
