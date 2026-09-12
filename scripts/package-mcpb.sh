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
[[ ! -d "$OUTPUT" ]] || { echo "error: output must name a package file, not a directory" >&2; exit 1; }

# Build a private bundle tree: packaging must not reuse a stale sidecar or
# include unrelated files left in the repository's generated server directory.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/che-mail-mcpb.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/server"
cp "$BINARY" "$STAGE/server/CheAppleMailMCP"
chmod 755 "$STAGE/server/CheAppleMailMCP"
PACKAGE_BINARY="$STAGE/server/CheAppleMailMCP"

# ---- Distribution gate ------------------------------------------------------
# Fails CLOSED. The whole point of #323 is that an unsigned bundle is not a
# lesser bundle — it is one that cannot work at all on a current macOS, and
# nothing downstream would have told the user why.
ARCHS=$(lipo -archs "$PACKAGE_BINARY" 2>/dev/null || echo "")
SIGN_INFO=$(codesign -dvvv "$PACKAGE_BINARY" 2>&1 || true)
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

# Query the image that will actually be packaged, after the distribution gate.
# stdin is closed; a failed, malformed or stuck query must not publish a bundle
# with stale/guessed metadata. The unsigned dev opt-in does not bypass this.
python3 - "$PACKAGE_BINARY" "$VERSION" "$STAGE/server/.CheAppleMailMCP.version" <<'PY_VERSION'
import re
import subprocess
import sys
from pathlib import Path

pattern = re.compile(r"(?:0|[1-9][0-9]{0,18})\.(?:0|[1-9][0-9]{0,18})\.(?:0|[1-9][0-9]{0,18})")
def valid(value):
    return bool(pattern.fullmatch(value)) and all(int(p) <= (1 << 63) - 1 for p in value.split('.'))

if not valid(sys.argv[2]):
    raise SystemExit("error: manifest version must be a canonical MAJOR.MINOR.PATCH value")
try:
    result = subprocess.run([sys.argv[1], "--version"], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            check=True, timeout=5)
except subprocess.TimeoutExpired:
    raise SystemExit("error: packaged binary --version timed out after 5 seconds")
except (OSError, subprocess.CalledProcessError):
    raise SystemExit("error: packaged binary --version failed")
try:
    version = result.stdout.decode('ascii')
except UnicodeDecodeError:
    raise SystemExit("error: packaged binary returned an invalid version")
if version.endswith('\n'):
    version = version[:-1]
if not valid(version):
    raise SystemExit("error: packaged binary returned an invalid version")
if version != sys.argv[2]:
    raise SystemExit("error: packaged binary version does not match mcpb/manifest.json")
Path(sys.argv[3]).write_text(version + '\n', encoding='ascii')
PY_VERSION

# ---- Package ----------------------------------------------------------------
cp mcpb/manifest.json mcpb/icon.png mcpb/PRIVACY.md "$STAGE/"
( cd "$STAGE" && zip -qr bundle.mcpb manifest.json icon.png PRIVACY.md server/ )
mkdir -p "$(dirname "$OUTPUT")"
mv -f "$STAGE/bundle.mcpb" "$OUTPUT"

shasum -a 256 "$OUTPUT" | awk '{print $1}' > "$OUTPUT.sha256"

echo "→ packaged $OUTPUT"
echo "   binary : ${ARCHS:-unknown}${TEAM:+, TeamIdentifier=$TEAM}"
echo "   version: $VERSION"
echo "   sha256 : $(cat "$OUTPUT.sha256")"
