#!/bin/bash
# che-apple-mail-mcp SessionStart hook — detect stale MCP binary, kill PID for respawn.
#
# Resolves PsychQuant/che-apple-mail-mcp#76: wrapper version-check only fires at
# spawn; in-memory binary never re-checks plugin.json. This hook compares wrapper-
# written runtime state against current plugin.json version; if they differ and
# the recorded PID is alive, SIGTERM (then SIGKILL after grace) so Claude Code
# respawns MCP via wrapper, picking up the new binary.
#
# Failure mode: every dependency missing or unexpected → silent exit 0. Worst
# case is no-op (current pre-fix behavior); never break session start.

set -u

# Dependencies — graceful skip if missing.
command -v jq >/dev/null 2>&1 || exit 0
command -v ps >/dev/null 2>&1 || exit 0

BINARY_NAME="CheAppleMailMCP"
INSTALL_DIR="$HOME/bin"
RUNTIME_FILE="$INSTALL_DIR/.${BINARY_NAME}.runtime.json"

# Locate plugin root via hook's own path (PLUGIN_ROOT/hooks/session-start.sh).
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

# Both files required.
[ -f "$RUNTIME_FILE" ] || exit 0
[ -f "$PLUGIN_JSON" ] || exit 0

# Read versions. Runtime state records BINARY tag (per #77 fix to wrapper).
# Plugin.json has two fields since #77: .version (plugin shell) and
# .binary_version (binary tag). Hook must compare against .binary_version
# when present, falling back to .version for plugins not yet migrated.
# Without this fallback chain, the hook compares runtime binary tag against
# plugin shell version and triggers spurious kill every session (see #73).
RUNTIME_VERSION=$(jq -r '.version_at_spawn // ""' "$RUNTIME_FILE" 2>/dev/null)
PLUGIN_VERSION=$(jq -r '.binary_version // .version // ""' "$PLUGIN_JSON" 2>/dev/null)

[ -z "$RUNTIME_VERSION" ] && exit 0
[ -z "$PLUGIN_VERSION" ] && exit 0

# Match → no-op.
[ "$RUNTIME_VERSION" = "$PLUGIN_VERSION" ] && exit 0

# Mismatch — check if recorded PID is still alive.
PID=$(jq -r '.pid // empty' "$RUNTIME_FILE" 2>/dev/null)
[ -z "$PID" ] && exit 0

# `ps -p $PID -o pid=` returns empty if PID is dead. Also guard against
# matching the wrong process (e.g. PID reused by something else): require
# the running process command to contain BINARY_NAME.
ps -p "$PID" -o pid= >/dev/null 2>&1 || exit 0
PID_COMM=$(ps -p "$PID" -o command= 2>/dev/null)
case "$PID_COMM" in
    *"$BINARY_NAME"*) ;;
    *) exit 0 ;;
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

exit 0
