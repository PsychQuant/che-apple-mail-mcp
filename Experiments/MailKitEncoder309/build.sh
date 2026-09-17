#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
probe_app="$PWD/.build/Build/Products/Debug/ProbeHost.app"
cleanup_registration() {
    local registry=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
    # Some macOS builds return nonzero after removing the record. Verify
    # the exact path is absent; never turn a remaining registration green.
    "$registry" -u "$probe_app" || true
    "$registry" -dump | python3 -c 'import sys; sys.exit(1 if sys.argv[1] in sys.stdin.read() else 0)' "$probe_app"
}
trap cleanup_registration EXIT
xcodegen generate
xcodebuild -project MailKitEncoder309.xcodeproj -scheme ProbeTests \
    -destination 'platform=macOS' -derivedDataPath .build test CODE_SIGNING_ALLOWED=NO
xcodebuild -project MailKitEncoder309.xcodeproj -scheme ProbeHost \
    -destination 'platform=macOS' -derivedDataPath .build build CODE_SIGNING_ALLOWED=NO
