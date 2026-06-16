#!/bin/bash
# Sign and notarize the CheAppleMailMCP universal binary for outside-App-Store
# distribution.
#
# Why (#211): the released binary used to be ad-hoc signed. macOS TCC keys the
# Full Disk Access grant for an ad-hoc binary to its cdhash, so every version
# bump invalidated the grant and the user had to re-add the binary to the FDA
# list. A Developer ID Application signature makes TCC key the grant to the
# stable designated requirement (Team ID + signing identity), so it survives
# version bumps. That signature — not notarization — is what delivers the
# FDA-persistence #211 is about.
#
# Why notarize anyway: notarization matters for *quarantined-launch* paths — a
# browser download or the .mcpb (Claude Desktop) install, where Gatekeeper
# assesses the binary on first launch. The plugin wrapper's `curl` + `exec`
# path sets no com.apple.quarantine xattr, so Gatekeeper never fires there and
# an un-notarized (even ad-hoc) binary would exec identically. We notarize so
# the published release asset is safe to run by ANY means, not only the wrapper.
#
# Unlike che-ical-mcp this binary needs NO personal-information entitlement:
# Full Disk Access (kTCCServiceSystemPolicyAllFiles) is not a requestable
# entitlement. The entitlements file (if present) is therefore optional/empty.
#
# Stapling is NOT performed: stapler staple does not support raw Mach-O
# binaries (only .app/.pkg/.dmg). Gatekeeper online-checks at first launch
# instead — this requires the user's machine to be online once when first
# running the binary.
#
# Usage:
#   scripts/sign-and-notarize.sh <path/to/binary>
#
# Required env vars (no defaults — fork-friendly, no maintainer PII in errors):
#   DEVELOPER_ID    — codesigning identity, e.g. "Developer ID Application: Your Name (TEAMID)"
#                     (a cert SHA-1 fingerprint also works)
#   NOTARY_PROFILE  — notarytool keychain profile name
#                     (set up via: xcrun notarytool store-credentials <name> ...)
#
# Optional env var:
#   ENTITLEMENTS    — entitlements .plist path (default:
#                     "Sources/CheAppleMailMCP/Entitlements.plist"). If the file
#                     is absent the binary is signed with hardened runtime and
#                     no entitlements — sufficient for FDA.

set -euo pipefail

BINARY="${1:?Usage: $0 <path/to/binary>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENTITLEMENTS="${ENTITLEMENTS:-$PROJECT_DIR/Sources/CheAppleMailMCP/Entitlements.plist}"
# Pinned signing identifier → stable designated-requirement identifier half,
# independent of the on-disk filename (#211 DA-2). Keep this value invariant
# across releases; changing it would invalidate the user's existing FDA grant.
BINARY_IDENTIFIER="${BINARY_IDENTIFIER:-CheAppleMailMCP}"

# Pre-flight: xcrun must exist. Without Xcode Command Line Tools every
# downstream `xcrun ...` would fail with a confusing "unable to find utility"
# error mid-flow. Surface it up-front with a fix-it message.
if ! command -v xcrun >/dev/null 2>&1; then
    echo "Error: xcrun not found. Install Xcode or Xcode Command Line Tools:" >&2
    echo "         xcode-select --install" >&2
    exit 1
fi

# Pre-flight: required env vars
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    echo "Error: DEVELOPER_ID is not set." >&2
    echo "       Export your Developer ID Application identity:" >&2
    echo "       export DEVELOPER_ID='Developer ID Application: Your Name (TEAMID)'" >&2
    echo "       Find available identities: security find-identity -p codesigning -v" >&2
    exit 1
fi

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Error: NOTARY_PROFILE is not set." >&2
    echo "       Export your notarytool keychain profile name:" >&2
    echo "       export NOTARY_PROFILE='your-profile-name'" >&2
    echo "       Set up profile (one-time): xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team-id>" >&2
    echo "       (notarytool will prompt for app-specific password — do NOT pass it on the command line)" >&2
    exit 1
fi

if [[ ! -f "$BINARY" ]]; then
    echo "Error: binary not found at $BINARY" >&2
    exit 1
fi

# Pre-flight: confirm $BINARY is actually a Mach-O binary. Catches the common
# fat-finger of pointing at a wrong artifact (test fixture, source file, etc.)
# before codesign produces a cryptic "unsupported file type" error.
if ! file "$BINARY" 2>/dev/null | grep -q "Mach-O"; then
    echo "Error: $BINARY does not appear to be a Mach-O binary." >&2
    echo "       file output: $(file "$BINARY" 2>&1)" >&2
    exit 1
fi

# Pre-flight: verify cert exists in keychain (avoids cryptic codesign error mid-flow)
if ! security find-identity -p codesigning -v 2>/dev/null | grep -qF "$DEVELOPER_ID"; then
    echo "Error: codesigning identity not found in keychain: $DEVELOPER_ID" >&2
    echo "       Available identities:" >&2
    security find-identity -p codesigning -v 2>&1 | grep -E '"[^"]*"' | sed 's/^/         /' >&2
    exit 1
fi

# Pre-flight: verify notarytool keychain profile exists (avoids submit-then-fail)
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Error: notarytool keychain profile '$NOTARY_PROFILE' not configured." >&2
    echo "       Set up with: xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
    echo "                      --apple-id <your-apple-id> --team-id <your-team-id>" >&2
    exit 1
fi

# Entitlements are optional for this server (FDA needs none). Use them only if
# the file exists; otherwise sign with hardened runtime + no entitlements.
CODESIGN_ENTITLEMENT_ARGS=()
if [[ -f "$ENTITLEMENTS" ]]; then
    CODESIGN_ENTITLEMENT_ARGS=(--entitlements "$ENTITLEMENTS")
    ENT_DESC="$ENTITLEMENTS"
else
    ENT_DESC="(none — hardened runtime only; FDA needs no entitlement)"
fi

# Use mktemp for /tmp zip + trap to ensure cleanup on any exit (incl. SIGINT/SIGTERM/error)
ZIP_PATH=""
cleanup() {
    [[ -n "$ZIP_PATH" && -f "$ZIP_PATH" ]] && rm -f "$ZIP_PATH"
}
trap cleanup EXIT INT TERM

echo "=== sign-and-notarize: $BINARY ==="
echo "  Identity:      $DEVELOPER_ID"
echo "  Profile:       $NOTARY_PROFILE"
echo "  Entitlements:  $ENT_DESC"
echo ""

# Step 1: codesign with hardened runtime
echo "[1/4] Signing with Developer ID + hardened runtime..."
echo "  Identifier:    $BINARY_IDENTIFIER (pinned — stable DR across filename changes)"
codesign --force \
    --options runtime \
    --identifier "$BINARY_IDENTIFIER" \
    "${CODESIGN_ENTITLEMENT_ARGS[@]}" \
    --sign "$DEVELOPER_ID" \
    "$BINARY"

# Step 2: verify signature locally (gating: codesign --verify exit code is checked;
# |head is output trimming only — under pipefail a verify failure still aborts).
echo ""
echo "[2/4] Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$BINARY" 2>&1 | head -5

# Step 3: notarize (requires zip wrapper for raw Mach-O).
# Capture submission output so we can extract the submission ID for post-mortem
# debug if the wait fails.
echo ""
echo "[3/4] Submitting for notarization (this typically takes 1-15 minutes)..."
ZIP_PATH="$(mktemp -t notarize-XXXXXXXX).zip"
ditto -c -k --keepParent "$BINARY" "$ZIP_PATH"

SUBMIT_LOG="$(mktemp -t notarize-log-XXXXXXXX)"
trap 'cleanup; rm -f "$SUBMIT_LOG"' EXIT INT TERM

# Helper: extract submission UUID; never aborts under set -e (trailing || true).
extract_submission_id() {
    grep -m1 -E '^[[:space:]]*id:' "$1" 2>/dev/null | awk '{print $2}' || true
}

if ! xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$SUBMIT_LOG"; then
    SUBMISSION_ID="$(extract_submission_id "$SUBMIT_LOG")"
    echo "" >&2
    echo "Error: notarization failed (or notarytool errored)." >&2
    if [[ -n "$SUBMISSION_ID" ]]; then
        echo "       To see Apple's rejection reason:" >&2
        echo "         xcrun notarytool log $SUBMISSION_ID --keychain-profile $NOTARY_PROFILE" >&2
    else
        echo "       (no submission ID captured — full notarytool output above; if format changed," >&2
        echo "        run: xcrun notarytool history --keychain-profile $NOTARY_PROFILE)" >&2
    fi
    exit 1
fi

SUBMISSION_ID="$(extract_submission_id "$SUBMIT_LOG")"
if [[ -n "$SUBMISSION_ID" ]]; then
    echo "Submission ID: $SUBMISSION_ID"
else
    echo "(submission accepted but ID not captured — notarytool output format may have changed)"
fi

# Step 4: cross-check that Apple's notarization service actually accepted the
# artifact. notarytool exit 0 means the submission was processed, but does NOT
# guarantee Apple's CDN has propagated the verdict. spctl is the canonical
# Gatekeeper-eye check; mismatch here = signed-but-not-notarized state.
#
# -t install (not -t execute): raw Mach-O CLI binaries fall through Apple's
# .app bundle check under -t execute on recent macOS.
echo ""
echo "[4/4] Cross-checking notarization with spctl..."
# spctl makes a network call to Apple OCSP servers and can hang if they are
# slow/unreachable. Wrap in a perl-alarm timeout (perl is always present on
# macOS; GNU `timeout` needs coreutils). Override via SPCTL_TIMEOUT_SECONDS.
SPCTL_TIMEOUT_SECONDS="${SPCTL_TIMEOUT_SECONDS:-60}"
if ! [[ "$SPCTL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: SPCTL_TIMEOUT_SECONDS must be a positive integer (got '$SPCTL_TIMEOUT_SECONDS')." >&2
    exit 1
fi
SPCTL_EXIT=0
SPCTL_OUTPUT="$(perl -e 'my $t=shift; alarm $t; exec @ARGV or die "exec failed: $!"' \
    -- "$SPCTL_TIMEOUT_SECONDS" spctl -a -vvv -t install "$BINARY" 2>&1)" || SPCTL_EXIT=$?
if [ "$SPCTL_EXIT" -eq 142 ]; then
    # perl alarm exit code: 128 + SIGALRM (14) = 142
    echo "Error: spctl timed out after ${SPCTL_TIMEOUT_SECONDS}s." >&2
    echo "       Apple's OCSP infrastructure is likely unreachable or slow." >&2
    echo "       Workaround: set SPCTL_TIMEOUT_SECONDS=N for slower links," >&2
    echo "       or re-run after network connectivity is restored." >&2
    exit 1
fi
if ! echo "$SPCTL_OUTPUT" | grep -q "source=Notarized Developer ID"; then
    echo "Error: spctl does not recognize $BINARY as notarized." >&2
    echo "       Partial-state failure: codesign succeeded + notarytool returned 0," >&2
    echo "       but Gatekeeper would still reject on first launch." >&2
    echo "       spctl output:" >&2
    echo "$SPCTL_OUTPUT" | sed 's/^/         /' >&2
    if [[ -n "${SUBMISSION_ID:-}" ]]; then
        echo "       Check Apple's log: xcrun notarytool log $SUBMISSION_ID --keychain-profile $NOTARY_PROFILE" >&2
    fi
    exit 1
fi
echo "  ✓ spctl accepts as Notarized Developer ID"

echo ""
echo "Final signature state:"
codesign -dv --verbose=2 "$BINARY" 2>&1 | grep -E "Authority|TeamIdentifier|flags|Signature" || true

echo ""
echo "=== sign-and-notarize: DONE ==="
echo "Note: stapling skipped (raw Mach-O binaries don't support stapler)."
echo "      Gatekeeper will online-check on first launch."
