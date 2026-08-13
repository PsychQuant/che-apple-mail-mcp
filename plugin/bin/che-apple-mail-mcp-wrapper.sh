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
    NEED_DOWNLOAD=true
    REASON="plugin wants v${DESIRED_VERSION}, installed is v${INSTALLED_VERSION:-unknown}"
fi

if $NEED_DOWNLOAD; then
    echo "$BINARY_NAME: $REASON — downloading from $REPO..." >&2
    mkdir -p "$INSTALL_DIR"

    # Try pinned tag first, then fall back to latest release.
    URL=""
    for API_URL in \
        "${DESIRED_VERSION:+https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION}" \
        "https://api.github.com/repos/$REPO/releases/latest"
    do
        [[ -z "$API_URL" ]] && continue
        URL=$(curl -sL --max-time 30 "$API_URL" 2>/dev/null \
            | grep '"browser_download_url"' | grep "/$BINARY_NAME\"" | head -1 \
            | sed 's/.*"\(https[^"]*\)".*/\1/')
        [[ -n "$URL" ]] && break
    done

    if [[ -z "$URL" ]]; then
        if [[ -x "$BINARY" ]]; then
            echo "$BINARY_NAME: WARNING — no download URL found, keeping existing binary" >&2
        else
            echo "$BINARY_NAME: ERROR — no download URL found at $REPO. Install manually: https://github.com/$REPO/releases" >&2
            exit 1
        fi
    else
        if curl -sL --max-time 300 "$URL" -o "${BINARY}.tmp" 2>/dev/null; then
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
{
    printf '{"pid":%d,"started_at":%d,"version_at_spawn":"%s"}\n' \
        "$$" "$(date +%s)" "${DESIRED_VERSION:-unknown}" \
        > "${RUNTIME_FILE}.tmp" \
        && mv "${RUNTIME_FILE}.tmp" "$RUNTIME_FILE"
} 2>/dev/null || true

exec "$BINARY" "$@"
