#!/bin/bash
# Version-aware auto-download wrapper for CheAppleMailMCP.
#
# Design:
# - Reads desired version from plugin.json (plugin's intended binary version)
# - Compares against ~/bin/.CheAppleMailMCP.version sidecar
# - Re-downloads when plugin has been updated but binary is stale
# - Atomic file swap (unique mktemp + mv) so partial or concurrent downloads
#   never break things (#392: fixed-name .tmp was a TOCTOU window)
# - Downloads are sha256-verified against the release's own asset list (#392);
#   only a release that genuinely publishes no .sha256 installs unverified
# - Falls back to releases/latest ONLY on a definitive pinned-tag 404; a
#   transient API failure keeps the installed binary and retries next spawn
# - State files in ~/bin (all prefixed .CheAppleMailMCP.):
#     .version         — sidecar: ACTUAL installed binary tag (#77)
#     .runtime.json    — pid/started_at/version_at_spawn (+degraded_pin) for the
#                        session-start staleness hook (#76/#393)
#     .fallback-tried  — "<pin> <epoch>": a pin found definitively missing (or
#                        failing verification) upstream; suppresses re-download
#                        for RETRY_TTL seconds or until the pin changes (#392).
#                        Deleting the file forces an immediate retry.

set -u

REPO="PsychQuant/che-apple-mail-mcp"
BINARY_NAME="CheAppleMailMCP"
INSTALL_DIR="$HOME/bin"
BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"
FALLBACK_MARKER="$INSTALL_DIR/.${BINARY_NAME}.fallback-tried"
RUNTIME_FILE="$INSTALL_DIR/.${BINARY_NAME}.runtime.json"
RETRY_TTL=86400   # retry a marked-unavailable pin at most once a day

# Locate plugin root via wrapper's own path (more reliable than $CLAUDE_PLUGIN_ROOT
# which isn't guaranteed in MCP spawn env). Wrapper lives at PLUGIN_ROOT/bin/*.sh.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

# Read desired BINARY version from plugin.json. Prefer the explicit
# `binary_version` field (introduced for #77 — disambiguates from the
# plugin shell's own `version`). Fall back to `version` for plugins that
# haven't migrated yet — they pay the existing silent-skip risk for
# binary-only releases (documented in #77).
DESIRED_VERSION=""
HAS_BINARY_VERSION=false
if [[ -f "$PLUGIN_JSON" ]]; then
    DESIRED_VERSION=$(grep -oE '"binary_version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
        | head -1 | cut -d'"' -f4 || true)
    if [[ -n "$DESIRED_VERSION" ]]; then
        HAS_BINARY_VERSION=true
    else
        DESIRED_VERSION=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
            | head -1 | cut -d'"' -f4 || true)
    fi
fi

# Read currently installed version from sidecar (empty string if file missing/unreadable).
INSTALLED_VERSION=""
[[ -f "$VERSION_FILE" ]] && INSTALLED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)

# --- helpers ------------------------------------------------------------------

# GET $1, body to $2. Echoes the HTTP status code ("000" on transport failure).
# Deliberately NOT -f: distinguishing a definitive 404 from rate-limits /
# timeouts / 5xx is the whole point (#392 round 1: conflating them let one
# transient outage pin the user to the wrong binary permanently).
http_get() {
    local code
    code=$(curl -sL --proto '=https' --max-redirs 3 --max-time 30 \
        -o "$2" -w '%{http_code}' "$1" 2>/dev/null) || code="000"
    printf '%s' "${code:-000}"
}

# Extract the browser_download_url ending in /$1 from the API body $2.
asset_url() {
    grep '"browser_download_url"' "$2" 2>/dev/null \
        | grep "/$1\"" | head -1 \
        | sed 's/.*"\(https[^"]*\)".*/\1/'
}

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 -r "$1" 2>/dev/null | awk '{print $1}'
    fi
}

# JSON-safe version token (#398 round 1: URL/sidecar-derived strings were
# interpolated into runtime.json unescaped).
sanitize_token() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._-'; }

# --- decide whether to download ----------------------------------------------

NEED_DOWNLOAD=false
REASON=""
DEGRADED_PIN=""   # set when we knowingly run a non-pinned binary (see hook)
if [[ ! -x "$BINARY" ]]; then
    NEED_DOWNLOAD=true
    REASON="binary not installed"
elif [[ -n "$DESIRED_VERSION" ]] && [[ "$INSTALLED_VERSION" != "$DESIRED_VERSION" ]]; then
    MARKER_PIN=""
    MARKER_EPOCH=0
    if [[ -f "$FALLBACK_MARKER" ]]; then
        read -r MARKER_PIN MARKER_EPOCH _ < "$FALLBACK_MARKER" 2>/dev/null || true
        MARKER_EPOCH=${MARKER_EPOCH:-0}
    fi
    NOW=$(date +%s)
    if [[ "$MARKER_PIN" == "$DESIRED_VERSION" ]] \
       && (( NOW - MARKER_EPOCH < RETRY_TTL )); then
        # #392: this pin was definitively missing (or failed verification)
        # upstream within the TTL. Run what is installed; retry when the pin
        # changes, the TTL lapses, or the marker file is deleted by hand.
        echo "$BINARY_NAME: pinned v${DESIRED_VERSION} was unavailable upstream — running installed v${INSTALLED_VERSION:-unknown}; retrying after $(( (MARKER_EPOCH + RETRY_TTL - NOW) / 3600 + 1 ))h or when the pin changes (rm $FALLBACK_MARKER to force)" >&2
        DEGRADED_PIN="$DESIRED_VERSION"
    else
        NEED_DOWNLOAD=true
        REASON="plugin wants v${DESIRED_VERSION}, installed is v${INSTALLED_VERSION:-unknown}"
    fi
fi

if $NEED_DOWNLOAD; then
    echo "$BINARY_NAME: $REASON — downloading from $REPO..." >&2
    mkdir -p "$INSTALL_DIR"

    META=$(mktemp "${INSTALL_DIR}/.${BINARY_NAME}.meta.XXXXXX")
    URL=""
    SHA_URL=""
    PIN_DEFINITIVE_MISS=false
    PIN_TRANSIENT=false

    if [[ -n "$DESIRED_VERSION" ]]; then
        CODE=$(http_get "https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION" "$META")
        if [[ "$CODE" == "200" ]]; then
            URL=$(asset_url "$BINARY_NAME" "$META")
            SHA_URL=$(asset_url "$BINARY_NAME.sha256" "$META")
            # Tag exists but carries no binary asset: a broken release —
            # definitive for marker purposes (TTL still bounds it).
            [[ -z "$URL" ]] && PIN_DEFINITIVE_MISS=true
        elif [[ "$CODE" == "404" ]]; then
            PIN_DEFINITIVE_MISS=true
        else
            PIN_TRANSIENT=true
        fi
    fi

    if [[ -n "$URL" ]]; then
        :   # pinned resolution succeeded
    elif [[ "$PIN_TRANSIENT" == true ]] && [[ -x "$BINARY" ]]; then
        # #392 round 1 (reproduced finding): a transient API failure must NOT
        # churn the install to latest or write a marker — keep what we have,
        # retry next spawn.
        echo "$BINARY_NAME: transient failure resolving pinned v${DESIRED_VERSION} (HTTP ${CODE:-000}) — keeping installed v${INSTALLED_VERSION:-unknown}, will retry next spawn" >&2
        DEGRADED_PIN="$DESIRED_VERSION"
        NEED_DOWNLOAD=false
    else
        CODE2=$(http_get "https://api.github.com/repos/$REPO/releases/latest" "$META")
        if [[ "$CODE2" == "200" ]]; then
            URL=$(asset_url "$BINARY_NAME" "$META")
            SHA_URL=$(asset_url "$BINARY_NAME.sha256" "$META")
        fi
    fi

    if $NEED_DOWNLOAD; then
    if [[ -z "$URL" ]]; then
        if [[ -x "$BINARY" ]]; then
            echo "$BINARY_NAME: WARNING — no download URL found, keeping existing binary" >&2
        else
            rm -f "$META"
            echo "$BINARY_NAME: ERROR — no download URL found at $REPO. Install manually: https://github.com/$REPO/releases" >&2
            exit 1
        fi
    else
        # Unique temp per process (#392 round 1: a shared fixed .tmp let a
        # concurrent spawn swap content between verification and mv).
        TMP=$(mktemp "${BINARY}.tmp.XXXXXX")
        DL_CODE=$(http_get "$URL" "$TMP")
        if [[ "$DL_CODE" == "200" ]] && [[ -s "$TMP" ]]; then
            # ---- sha256 verification (#392) --------------------------------
            INSTALL_OK=true
            if [[ -z "$SHA_URL" ]]; then
                # Definitively absent from the release's own asset list — the
                # one approved unverified path (old releases never shipped one).
                echo "$BINARY_NAME: note — this release publishes no .sha256 asset; installing unverified" >&2
            else
                SHA_TMP=$(mktemp "${INSTALL_DIR}/.${BINARY_NAME}.sha.XXXXXX")
                SHA_CODE=$(http_get "$SHA_URL" "$SHA_TMP")
                EXPECTED_SHA=$(head -1 "$SHA_TMP" 2>/dev/null | awk '{print $1}' | tr 'A-F' 'a-f')
                rm -f "$SHA_TMP"
                ACTUAL_SHA=$(sha256_of "$TMP" | tr 'A-F' 'a-f')
                if [[ "$SHA_CODE" != "200" ]] || [[ ! "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ ]]; then
                    # The asset exists but we could not obtain a usable digest:
                    # that is a verification FAILURE, not "no asset" (#392
                    # round 1: fail-open here defeated the whole feature).
                    # Transient by nature — no marker; retry next spawn.
                    INSTALL_OK=false
                    echo "$BINARY_NAME: ERROR — could not fetch a usable .sha256 (HTTP ${SHA_CODE}); refusing unverified install" >&2
                elif [[ -z "$ACTUAL_SHA" ]]; then
                    # No hash tool on this machine (shasum is a perl script
                    # Apple is sunsetting; openssl fallback also absent) —
                    # same trust posture as a release without a digest.
                    echo "$BINARY_NAME: note — no sha256 tool available (shasum/openssl); installing unverified" >&2
                elif [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
                    INSTALL_OK=false
                    echo "$BINARY_NAME: ERROR — sha256 mismatch on downloaded binary (expected ${EXPECTED_SHA}, got ${ACTUAL_SHA}); refusing install" >&2
                    # Persistent-mismatch guard: without a marker every spawn
                    # re-downloads 18 MB of the same rejected bytes (#398 R1).
                    if [[ -x "$BINARY" ]] && [[ -n "$DESIRED_VERSION" ]]; then
                        printf '%s %s verify\n' "$DESIRED_VERSION" "$(date +%s)" > "$FALLBACK_MARKER" 2>/dev/null || true
                        DEGRADED_PIN="$DESIRED_VERSION"
                    fi
                fi
            fi
            if [[ "$INSTALL_OK" == true ]]; then
                chmod +x "$TMP"
                if mv "$TMP" "$BINARY" 2>/dev/null; then
                    # Sidecar records the ACTUAL downloaded binary tag, parsed
                    # from the release URL — keeps the sidecar honest (#77).
                    ACTUAL_VERSION=$(echo "$URL" | sed -nE 's|.*/releases/download/v?([^/]+)/.*|\1|p')
                    echo "${ACTUAL_VERSION:-${DESIRED_VERSION:-unknown}}" > "$VERSION_FILE"
                    echo "$BINARY_NAME: installed v${ACTUAL_VERSION:-${DESIRED_VERSION:-latest}}" >&2
                    if [[ "$PIN_DEFINITIVE_MISS" == true ]] && [[ -n "$DESIRED_VERSION" ]]; then
                        # Definitive miss + successful fallback: remember it so
                        # the next spawns don't re-download; TTL + pin-change
                        # + manual rm all clear it (#392).
                        printf '%s %s miss\n' "$DESIRED_VERSION" "$(date +%s)" > "$FALLBACK_MARKER" 2>/dev/null || true
                        DEGRADED_PIN="$DESIRED_VERSION"
                    else
                        rm -f "$FALLBACK_MARKER" 2>/dev/null
                    fi
                else
                    rm -f "$TMP"
                    if [[ -x "$BINARY" ]]; then
                        echo "$BINARY_NAME: WARNING — install rename failed, keeping existing binary" >&2
                    else
                        rm -f "$META"
                        echo "$BINARY_NAME: ERROR — install rename failed" >&2
                        exit 1
                    fi
                fi
            else
                rm -f "$TMP"
                if [[ ! -x "$BINARY" ]]; then
                    rm -f "$META"
                    echo "$BINARY_NAME: ERROR — verification failed and no existing binary to fall back to. Install manually: https://github.com/$REPO/releases" >&2
                    exit 1
                fi
            fi
        else
            rm -f "$TMP"
            if [[ -x "$BINARY" ]]; then
                echo "$BINARY_NAME: WARNING — download failed (HTTP ${DL_CODE}), keeping existing binary" >&2
            else
                rm -f "$META"
                echo "$BINARY_NAME: ERROR — download failed (HTTP ${DL_CODE})" >&2
                exit 1
            fi
        fi
    fi
    fi
    rm -f "$META" 2>/dev/null
fi

# Write runtime state (per #76 — let session-start hook detect mid-session staleness).
# Atomic write: mktemp + mv; failures silent (|| true) so they never block spawn.
#
# #393: version_at_spawn records the ACTUAL installed version (re-read from the
# sidecar, which #77 made honest) — NOT the DESIRED pin. Writing DESIRED meant a
# failed download that kept an old binary stamped the new version into runtime
# state and the staleness hook went false-negative forever. When the sidecar is
# missing/unreadable the honest value is "unknown", not the pin (#398 round 1).
# Legacy plugins without `binary_version` keep the old DESIRED semantics — for
# them the hook compares against the SHELL version, and an actual binary tag
# would re-open the #73 spurious-kill trap.
if [[ "$HAS_BINARY_VERSION" == true ]]; then
    RUNTIME_VERSION="unknown"
    if [[ -f "$VERSION_FILE" ]]; then
        SIDECAR_VALUE=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)
        [[ -n "$SIDECAR_VALUE" ]] && RUNTIME_VERSION="$SIDECAR_VALUE"
    fi
else
    RUNTIME_VERSION="${DESIRED_VERSION:-unknown}"
fi
RUNTIME_VERSION=$(sanitize_token "$RUNTIME_VERSION")
DEGRADED_PIN=$(sanitize_token "$DEGRADED_PIN")
{
    RT_TMP=$(mktemp "${RUNTIME_FILE}.XXXXXX") \
        && printf '{"pid":%d,"started_at":%d,"version_at_spawn":"%s","degraded_pin":"%s"}\n' \
            "$$" "$(date +%s)" "${RUNTIME_VERSION:-unknown}" "$DEGRADED_PIN" \
            > "$RT_TMP" \
        && mv "$RT_TMP" "$RUNTIME_FILE"
} 2>/dev/null || true

exec "$BINARY" "$@"
