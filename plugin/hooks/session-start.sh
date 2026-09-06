#!/bin/bash
# che-apple-mail-mcp SessionStart hook — detect stale MCP binary, kill PID for respawn.
#
# Resolves PsychQuant/che-apple-mail-mcp#76: wrapper version-check only fires at
# spawn; in-memory binary never re-checks plugin.json. This hook compares wrapper-
# written runtime state against current plugin.json version; if they differ and
# the recorded PID is alive, SIGTERM (then SIGKILL after grace) so Claude Code
# respawns MCP via wrapper, picking up the new binary.
#
# Failure mode: silent exit 0 on missing dependencies, scoped PER FEATURE (#394).
# The scoping is STRUCTURAL, not positional: the staleness block lives inside
# run_staleness_detection() and its dependency gates `return 0`, so a feature
# added AFTER it still runs on a jq-less machine. #399 verify round 2 showed why
# that matters — with the gates as bare `exit 0`, "put new tool-independent
# features above the gates" was only a comment, and #394's root cause (ordering
# decides who gets swallowed) was still live for the next feature.
#
# What each part actually needs: the staleness block needs jq + ps. The FDA
# assist needs the binary plus tr / sort / head / mkdir / dirname — NOT "no
# external tool", as this header claimed before #399 round 2; the accurate
# statement is that it needs neither jq nor ps, which is what #394 turned on.
#
# CHE_MAIL_HOOK_DEBUG=1 (exactly "1") makes gate decisions say so on stderr —
# both the skips AND a "gates passed" seam, so the suite can prove the gates
# still GUARD the block rather than merely still printing. Any other value,
# including "0", leaves stderr silent.

set -u

# `set -u` + an unset HOME would abort with an unbound-variable error and a
# non-zero exit — the one thing this hook promises never to do. (#399 verify:
# a new edge once PLUGIN_ROOT/HOME resolution moved above the gates.)
[ -n "${HOME:-}" ] || exit 0

BINARY_NAME="CheAppleMailMCP"
INSTALL_DIR="$HOME/bin"
RUNTIME_FILE="$INSTALL_DIR/.${BINARY_NAME}.runtime.json"

# Locate plugin root via hook's own path (PLUGIN_ROOT/hooks/session-start.sh).
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

# ---- First-run Full Disk Access assist (mail#355) -----------------------------
#
# The setup window has existed since mail#213/#214 — live FDA status, a button
# that opens the right System Settings pane, a button that copies the binary
# path — and NOTHING on the install path ever opened it. The wrapper only
# compares versions, this hook only killed stale processes, and the README
# mentioned `--setup` in a reference section you had to already know to look
# for. So the convenient way to grant FDA was reachable only by people who
# already knew it existed.
#
# This must run BEFORE the staleness block below: that block exits early when
# $RUNTIME_FILE is absent, which is precisely the state of a brand-new install —
# the first run, the only run this assist cares about.
#
# Deliberate constraints:
#   - offered ONCE per machine (marker), never a recurring nag
#   - only when FDA is actually missing
#   - the window is launched DETACHED; it runs a GUI runloop and would otherwise
#     block session start forever
#   - the marker is written BEFORE launching, so a failure cannot loop
#   - old binaries are skipped by version: they parse `--check-fda --quiet` as
#     plain `--check-fda`, which PRINTS and opens System Settings — exactly the
#     nagging this is written to avoid
first_run_fda_assist() {
    local binary="$INSTALL_DIR/$BINARY_NAME"
    [ -x "$binary" ] || return 0

    local marker_dir="${XDG_STATE_HOME:-$HOME/.local/state}/che-apple-mail-mcp"
    local marker="$marker_dir/fda-setup-offered"
    [ -f "$marker" ] && return 0

    # `--check-fda --quiet` (status only, no output, no pane) landed in binary
    # 2.28.0. Anything older: skip rather than risk the loud path.
    local bin_ver
    bin_ver=$("$binary" --version 2>/dev/null | tr -d '[:space:]')
    [ -z "$bin_ver" ] && return 0
    [ "$(printf '%s\n2.28.0\n' "$bin_ver" | sort -V | head -1)" = "2.28.0" ] || return 0

    # Silent probe. `--check-fda --quiet` is a FOUR-value contract (SetupCLI:
    # 0 granted / 1 denied / 2 noMailData / 3 undetermined) that this line
    # collapses to a boolean, so states 2 and 3 offer the assist AND burn the
    # once-only marker. Pre-existing since mail#355, out of scope for #394;
    # surfaced by #399 verify round 2 and tracked in #403.
    # 0 = granted → nothing to offer.
    "$binary" --check-fda --quiet >/dev/null 2>&1 && return 0

    mkdir -p "$marker_dir" 2>/dev/null || return 0
    : > "$marker" 2>/dev/null || return 0

    echo "che-apple-mail-mcp: Full Disk Access is not granted — opening the setup window." >&2
    echo "  It shows live status and links straight to the right System Settings pane." >&2
    echo "  (Shown once. Re-open any time with: $binary --setup)" >&2

    # Detached: the window owns a GUI runloop and must not block session start.
    ( "$binary" --setup >/dev/null 2>&1 & ) >/dev/null 2>&1

    return 0
}
first_run_fda_assist

# ---- Staleness detection (needs jq for the runtime JSON + ps for the PID) ----
# #394: these gates used to sit at the very top of the file, BEFORE the FDA
# assist — which needs neither tool — so a jq-less machine (exactly the
# fresh-install audience the assist exists for) silently lost the assist too.
#
# The block is a FUNCTION so its gates `return` instead of `exit`: the skip is
# scoped to this feature, and anything added below still runs without jq/ps.
# Graceful-skip semantics for the staleness block itself are unchanged.
run_staleness_detection() {
    command -v jq >/dev/null 2>&1 || {
        [ "${CHE_MAIL_HOOK_DEBUG:-}" = "1" ] && echo "hook: staleness gate — jq missing, skipping" >&2
        return 0
    }
    command -v ps >/dev/null 2>&1 || {
        [ "${CHE_MAIL_HOOK_DEBUG:-}" = "1" ] && echo "hook: staleness gate — ps missing, skipping" >&2
        return 0
    }
    # Positive seam: proves the gates GUARD the block, not merely that they
    # print. Without it, deleting both `return 0` above left the suite fully
    # green — the diagnostic still fired and the block failed harmlessly later
    # (#399 verify round 2 reproduced exactly that).
    [ "${CHE_MAIL_HOOK_DEBUG:-}" = "1" ] && echo "hook: staleness gates passed" >&2

    # Both files required.
    [ -f "$RUNTIME_FILE" ] || return 0
    [ -f "$PLUGIN_JSON" ] || return 0

    # Read versions. Runtime state records BINARY tag (per #77 fix to wrapper).
    # Plugin.json has two fields since #77: .version (plugin shell) and
    # .binary_version (binary tag). Hook must compare against .binary_version
    # when present, falling back to .version for plugins not yet migrated.
    # Without this fallback chain, the hook compares runtime binary tag against
    # plugin shell version and triggers spurious kill every session (see #73).
    RUNTIME_VERSION=$(jq -r '.version_at_spawn // ""' "$RUNTIME_FILE" 2>/dev/null)
    PLUGIN_VERSION=$(jq -r '.binary_version // .version // ""' "$PLUGIN_JSON" 2>/dev/null)

    [ -z "$RUNTIME_VERSION" ] && return 0
    [ -z "$PLUGIN_VERSION" ] && return 0

    # Match → no-op.
    [ "$RUNTIME_VERSION" = "$PLUGIN_VERSION" ] && return 0

    # Mismatch — check if recorded PID is still alive.
    PID=$(jq -r '.pid // empty' "$RUNTIME_FILE" 2>/dev/null)
    [ -z "$PID" ] && return 0

    # `ps -p $PID -o pid=` returns empty if PID is dead. Also guard against
    # matching the wrong process (e.g. PID reused by something else): require
    # the running process command to contain BINARY_NAME.
    ps -p "$PID" -o pid= >/dev/null 2>&1 || return 0
    PID_COMM=$(ps -p "$PID" -o command= 2>/dev/null)
    case "$PID_COMM" in
        *"$BINARY_NAME"*) ;;
        *) return 0 ;;
    esac

    echo "⚠ Killing stale ${BINARY_NAME} PID ${PID} (was v${RUNTIME_VERSION}, plugin now v${PLUGIN_VERSION}) — Claude Code will respawn with new binary." >&2

    # SIGTERM, give 5s for graceful shutdown (SQLite WAL flush, etc).
    kill -TERM "$PID" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        ps -p "$PID" -o pid= >/dev/null 2>&1 || break
        sleep 1
    done

    # Still alive → SIGKILL.
    if ps -p "$PID" -o pid= >/dev/null 2>&1; then
        echo "⚠ ${BINARY_NAME} PID ${PID} did not exit on SIGTERM, sending SIGKILL." >&2
        kill -KILL "$PID" 2>/dev/null || true
    fi
}
run_staleness_detection

exit 0
