#!/bin/bash
# Version-aware auto-download wrapper for CheAppleMailMCP.
#
# Design:
# - Reads desired version from plugin.json (plugin's intended binary version)
# - Compares against ~/bin/.CheAppleMailMCP.version sidecar
# - Re-downloads when plugin has been updated but binary is stale
# - Atomic file swap (.tmp + mv) so partial downloads never break things
# - Falls back to releases/latest if plugin.json unreadable or pinned tag missing

set -u

REPO="PsychQuant/che-apple-mail-mcp"
BINARY_NAME="CheAppleMailMCP"
INSTALL_DIR="$HOME/bin"
BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"
# #392: remembers a pinned version whose tag was missing upstream, so the
# latest-fallback does not turn into a re-download on every single spawn.
FALLBACK_MARKER="$INSTALL_DIR/.${BINARY_NAME}.fallback-tried"
RUNTIME_FILE="$INSTALL_DIR/.${BINARY_NAME}.runtime.json"

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
if [[ -f "$PLUGIN_JSON" ]]; then
    DESIRED_VERSION=$(grep -oE '"binary_version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
        | head -1 | cut -d'"' -f4 || true)
    if [[ -z "$DESIRED_VERSION" ]]; then
        DESIRED_VERSION=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
            | head -1 | cut -d'"' -f4 || true)
    fi
fi

# Read currently installed version from sidecar (empty string if file missing/unreadable).
INSTALLED_VERSION=""
[[ -f "$VERSION_FILE" ]] && INSTALLED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)

# Decide whether to download.
NEED_DOWNLOAD=false
REASON=""
if [[ ! -x "$BINARY" ]]; then
    NEED_DOWNLOAD=true
    REASON="binary not installed"
elif [[ -n "$DESIRED_VERSION" ]] && [[ "$INSTALLED_VERSION" != "$DESIRED_VERSION" ]]; then
    if [[ -f "$FALLBACK_MARKER" ]] \
       && [[ "$(tr -d '[:space:]' < "$FALLBACK_MARKER" 2>/dev/null)" == "$DESIRED_VERSION" ]]; then
        # #392: the pinned tag was already found missing on a previous spawn and we
        # fell back to latest. Re-trying every spawn is a per-spawn download loop;
        # run what is installed and retry only when the pin itself changes.
        echo "$BINARY_NAME: pinned v${DESIRED_VERSION} was unavailable on a previous spawn — running installed v${INSTALLED_VERSION:-unknown}; will retry when the pin changes" >&2
    else
        NEED_DOWNLOAD=true
        REASON="plugin wants v${DESIRED_VERSION}, installed is v${INSTALLED_VERSION:-unknown}"
    fi
fi

if $NEED_DOWNLOAD; then
    echo "$BINARY_NAME: $REASON — downloading from $REPO..." >&2
    mkdir -p "$INSTALL_DIR"

    # Try pinned tag first, then fall back to latest release.
    # curl -f (#392): an HTTP error must be a curl failure, never a body we parse.
    URL=""
    PIN_MISS=false
    if [[ -n "$DESIRED_VERSION" ]]; then
        URL=$(curl -sfL --max-time 30 "https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION" 2>/dev/null \
            | grep '"browser_download_url"' | grep "/$BINARY_NAME\"" | head -1 \
            | sed 's/.*"\(https[^"]*\)".*/\1/')
        [[ -z "$URL" ]] && PIN_MISS=true
    fi
    if [[ -z "$URL" ]]; then
        URL=$(curl -sfL --max-time 30 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
            | grep '"browser_download_url"' | grep "/$BINARY_NAME\"" | head -1 \
            | sed 's/.*"\(https[^"]*\)".*/\1/')
    fi

    if [[ -z "$URL" ]]; then
        if [[ -x "$BINARY" ]]; then
            echo "$BINARY_NAME: WARNING — no download URL found, keeping existing binary" >&2
        else
            echo "$BINARY_NAME: ERROR — no download URL found at $REPO. Install manually: https://github.com/$REPO/releases" >&2
            exit 1
        fi
    else
        if curl -sfL --max-time 300 "$URL" -o "${BINARY}.tmp" 2>/dev/null; then
            # #392: verify the download against the release's .sha256 asset BEFORE
            # chmod/mv. tmp+mv already keeps a failed curl from clobbering the good
            # binary; this closes the "curl exit 0 but body is garbage" case and
            # the corrupted/tampered-download case. Missing asset (older releases
            # never shipped one) => disclose and proceed, backward compatible.
            SHA_REJECTED=false
            EXPECTED_SHA=$(curl -sfL --max-time 30 "${URL}.sha256" 2>/dev/null | awk '{print $1}' | head -1)
            if [[ -n "$EXPECTED_SHA" ]]; then
                ACTUAL_SHA=$(shasum -a 256 "${BINARY}.tmp" 2>/dev/null | awk '{print $1}')
                if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
                    SHA_REJECTED=true
                    rm -f "${BINARY}.tmp"
                    if [[ -x "$BINARY" ]]; then
                        echo "$BINARY_NAME: ERROR — sha256 mismatch on downloaded binary (expected ${EXPECTED_SHA}, got ${ACTUAL_SHA:-none}); keeping existing binary" >&2
                    else
                        echo "$BINARY_NAME: ERROR — sha256 mismatch and no existing binary to fall back to. Install manually: https://github.com/$REPO/releases" >&2
                        exit 1
                    fi
                fi
            else
                echo "$BINARY_NAME: note — no .sha256 asset published for this release; installing unverified" >&2
            fi
            if [[ "$SHA_REJECTED" != true ]]; then
            chmod +x "${BINARY}.tmp"
            mv "${BINARY}.tmp" "$BINARY"
            # Sidecar records the ACTUAL downloaded binary tag, parsed from
            # the GitHub release URL (path segment between /download/ and
            # the next /). This breaks the #77 "silent skip" trap: when
            # plugin.json lacks `binary_version`, DESIRED is the shell
            # version which never matches a real binary tag, so writing
            # DESIRED_VERSION makes the sidecar lie. Parsing the URL keeps
            # the sidecar honest regardless of which path was taken.
            ACTUAL_VERSION=$(echo "$URL" | sed -nE 's|.*/releases/download/v?([^/]+)/.*|\1|p')
            echo "${ACTUAL_VERSION:-${DESIRED_VERSION:-unknown}}" > "$VERSION_FILE"
            echo "$BINARY_NAME: installed v${ACTUAL_VERSION:-${DESIRED_VERSION:-latest}}" >&2
            # #392: latest-fallback loop guard — record the pin that was missing so
            # the next spawn runs what is installed instead of re-downloading; any
            # pin change (or a later successful pinned fetch) clears the marker.
            if [[ "$PIN_MISS" == true ]] && [[ -n "$DESIRED_VERSION" ]]; then
                printf '%s\n' "$DESIRED_VERSION" > "$FALLBACK_MARKER" 2>/dev/null || true
            else
                rm -f "$FALLBACK_MARKER" 2>/dev/null
            fi
            fi
        else
            rm -f "${BINARY}.tmp" 2>/dev/null
            if [[ -x "$BINARY" ]]; then
                echo "$BINARY_NAME: WARNING — download failed, keeping existing binary" >&2
            else
                echo "$BINARY_NAME: ERROR — download failed" >&2
                exit 1
            fi
        fi
    fi
fi

# Write runtime state (per #76 — let session-start hook detect mid-session staleness).
# Atomic write: .tmp + mv; failures silent (|| true) so they never block spawn.
#
# #393: version_at_spawn records the ACTUAL installed version (re-read from the
# sidecar, which #77 made honest) — NOT the DESIRED pin. Writing DESIRED meant a
# failed download that kept an old binary stamped the runtime state with the new
# version, and the session-start staleness hook (which the hook's own comment
# says compares binary tags) went false-negative forever. With the actual value,
# a stale binary mismatches plugin.json, the hook kills/respawns, and the wrapper
# retries the download — one visible retry per session start, bounded.
RUNTIME_VERSION="${DESIRED_VERSION:-unknown}"
if [[ -f "$VERSION_FILE" ]]; then
    SIDECAR_VALUE=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)
    [[ -n "$SIDECAR_VALUE" ]] && RUNTIME_VERSION="$SIDECAR_VALUE"
fi
{
    printf '{"pid":%d,"started_at":%d,"version_at_spawn":"%s"}\n' \
        "$$" "$(date +%s)" "${RUNTIME_VERSION}" \
        > "${RUNTIME_FILE}.tmp" \
        && mv "${RUNTIME_FILE}.tmp" "$RUNTIME_FILE"
} 2>/dev/null || true

exec "$BINARY" "$@"
