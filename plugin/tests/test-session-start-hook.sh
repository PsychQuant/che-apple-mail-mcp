#!/bin/bash
# Integration tests for hooks/session-start.sh (#76).
#
# Each case: arrange (set up runtime state file + plugin.json + optional mock PID),
# act (run hook), assert (exit code + side effects). All temp state lives under
# $TEST_DIR which is auto-cleaned via trap.
#
# Mock strategy:
# - Override $HOME via env so RUNTIME_FILE points into TEST_DIR
# - Override BASH_SOURCE-derived plugin root by symlinking a fake plugin tree
# - Mock MCP binary process via `sleep 1000 &` background process
# - Process command match is on substring "CheAppleMailMCP" — sleep alone won't
#   pass the guard, so we use exec via a renamed command via /bin/sh -c with
#   $0 trick is too brittle; instead skip the comm check by trusting jq parse
#   in cases where PID points to our sleep, by using a wrapper script that
#   re-execs sleep with argv[0]=CheAppleMailMCP.

set -u

TEST_DIR=$(mktemp -d -t test-session-start-hook.XXXXXX)
PASS=0
FAIL=0
FAIL_DETAIL=""

cleanup() {
    # Kill any tracked mock PIDs.
    for pid in $(cat "$TEST_DIR/mock_pids" 2>/dev/null); do
        kill -KILL "$pid" 2>/dev/null || true
    done
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# --- Setup mock plugin layout ---
# Real hook lives at: <plugin>/hooks/session-start.sh
# Plugin.json lives at: <plugin>/.claude-plugin/plugin.json
# Hook resolves PLUGIN_ROOT via "$(dirname BASH_SOURCE)/..".
# Trick: copy hook into a fake plugin root inside TEST_DIR so PLUGIN_ROOT
# resolves to our test plugin layout.

REAL_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
REAL_HOOK="$REAL_HOOK_DIR/session-start.sh"

if [ ! -x "$REAL_HOOK" ]; then
    echo "ERROR: hook not found or not executable at $REAL_HOOK" >&2
    exit 2
fi

FAKE_PLUGIN="$TEST_DIR/fake-plugin"
mkdir -p "$FAKE_PLUGIN/hooks" "$FAKE_PLUGIN/.claude-plugin"
cp "$REAL_HOOK" "$FAKE_PLUGIN/hooks/session-start.sh"
chmod +x "$FAKE_PLUGIN/hooks/session-start.sh"

# Spawn a mock binary process whose argv[0] contains "CheAppleMailMCP" so the
# hook's comm-substring guard passes. macOS SIP / codesigning kills sleep when
# launched from a copied path, so use `exec -a` to fake argv[0] inside a
# subshell — sleep itself runs from /bin/sleep but appears as
# "CheAppleMailMCP-mock" in `ps -o command=`.
#
# IMPORTANT: cannot use `start_mock_pid; PID=$LAST_MOCK_PID` command substitution — bash
# waits for every child of the substitution subshell to exit, including the
# backgrounded sleep, so $() blocks for 1000s. Use a global variable instead.
LAST_MOCK_PID=""
start_mock_pid() {
    ( exec -a CheAppleMailMCP-mock sleep 1000 ) >/dev/null 2>&1 &
    LAST_MOCK_PID=$!
    echo "$LAST_MOCK_PID" >> "$TEST_DIR/mock_pids"
    # Briefly wait for the exec to settle so subsequent `ps -p $pid` succeeds.
    sleep 0.2
}

run_hook() {
    # Override HOME so RUNTIME_FILE in hook resolves inside TEST_DIR.
    HOME="$TEST_DIR" mkdir -p "$TEST_DIR/bin"
    HOME="$TEST_DIR" "$FAKE_PLUGIN/hooks/session-start.sh" 2>"$TEST_DIR/hook.stderr"
    return $?
}

write_plugin_json() {
    local version="$1"
    if [ "$version" = "MISSING" ]; then
        rm -f "$FAKE_PLUGIN/.claude-plugin/plugin.json"
    else
        cat > "$FAKE_PLUGIN/.claude-plugin/plugin.json" <<EOF
{"name":"test","version":"$version"}
EOF
    fi
}

# v2.19.5+ schema (post-#77): plugin.json has both `version` (shell) and
# `binary_version` (binary tag). Runtime state records binary tag.
write_plugin_json_with_binary() {
    local shell_version="$1"
    local binary_version="$2"
    cat > "$FAKE_PLUGIN/.claude-plugin/plugin.json" <<EOF
{"name":"test","version":"$shell_version","binary_version":"$binary_version"}
EOF
}

write_runtime_file() {
    local pid="$1"
    local version="$2"
    if [ "$pid" = "MISSING" ]; then
        rm -f "$TEST_DIR/bin/.CheAppleMailMCP.runtime.json"
        return
    fi
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/.CheAppleMailMCP.runtime.json" <<EOF
{"pid":${pid},"started_at":1000000,"version_at_spawn":"${version}"}
EOF
}

assert() {
    local name="$1"
    local condition="$2"
    if eval "$condition"; then
        PASS=$((PASS+1))
        printf "  PASS  %s\n" "$name"
    else
        FAIL=$((FAIL+1))
        FAIL_DETAIL="${FAIL_DETAIL}\n  FAIL  ${name}\n        condition: ${condition}\n        stderr: $(cat "$TEST_DIR/hook.stderr" 2>/dev/null)"
        printf "  FAIL  %s\n" "$name"
    fi
}

reset_state() {
    rm -f "$TEST_DIR/bin/.CheAppleMailMCP.runtime.json"
    rm -f "$FAKE_PLUGIN/.claude-plugin/plugin.json"
    : > "$TEST_DIR/hook.stderr"
}

# ============================================================
# Case 1: no runtime state file → exit 0, no-op
# ============================================================
echo "Case 1: no runtime state file"
reset_state
write_plugin_json "2.18.0"
run_hook
EXIT=$?
assert "exit 0" "[ $EXIT -eq 0 ]"
assert "no warning emitted" "[ ! -s $TEST_DIR/hook.stderr ]"

# ============================================================
# Case 2: version match → no kill
# ============================================================
echo "Case 2: version match"
reset_state
start_mock_pid; PID=$LAST_MOCK_PID
write_plugin_json "2.18.0"
write_runtime_file "$PID" "2.18.0"
run_hook
EXIT=$?
assert "exit 0" "[ $EXIT -eq 0 ]"
assert "no warning emitted" "[ ! -s $TEST_DIR/hook.stderr ]"
assert "mock PID still alive" "ps -p $PID -o pid= >/dev/null 2>&1"
kill -KILL "$PID" 2>/dev/null || true

# ============================================================
# Case 3: version mismatch + PID alive → SIGTERM, PID dies
# ============================================================
echo "Case 3: version mismatch + PID alive"
reset_state
start_mock_pid; PID=$LAST_MOCK_PID
write_plugin_json "2.18.0"
write_runtime_file "$PID" "2.17.0"
run_hook
EXIT=$?
assert "exit 0" "[ $EXIT -eq 0 ]"
assert "warning printed to stderr" "grep -q 'Killing stale CheAppleMailMCP' $TEST_DIR/hook.stderr"
sleep 0.5
assert "mock PID is dead" "! ps -p $PID -o pid= >/dev/null 2>&1"

# ============================================================
# Case 4: runtime state present but PID already dead → no-op
# ============================================================
echo "Case 4: stale runtime state, PID dead"
reset_state
start_mock_pid; PID=$LAST_MOCK_PID
kill -KILL "$PID" 2>/dev/null
sleep 0.2
write_plugin_json "2.18.0"
write_runtime_file "$PID" "2.17.0"
run_hook
EXIT=$?
assert "exit 0" "[ $EXIT -eq 0 ]"
assert "no warning emitted" "[ ! -s $TEST_DIR/hook.stderr ]"

# ============================================================
# Case 5: jq missing → silent exit 0
# ============================================================
echo "Case 5: jq missing"
reset_state
start_mock_pid; PID=$LAST_MOCK_PID
write_plugin_json "2.18.0"
write_runtime_file "$PID" "2.17.0"
# Mock missing jq by overriding PATH to exclude it.
MINIMAL_PATH="/sbin:/usr/sbin"  # neither contains jq
EXISTING_HOME="$HOME"
HOME="$TEST_DIR" PATH="$MINIMAL_PATH" "$FAKE_PLUGIN/hooks/session-start.sh" 2>"$TEST_DIR/hook.stderr"
EXIT=$?
HOME="$EXISTING_HOME"
assert "exit 0" "[ $EXIT -eq 0 ]"
assert "no warning emitted" "[ ! -s $TEST_DIR/hook.stderr ]"
assert "mock PID still alive (hook should not have killed without jq)" "ps -p $PID -o pid= >/dev/null 2>&1"
kill -KILL "$PID" 2>/dev/null || true

# ============================================================
# Case 6: plugin.json missing → silent exit 0
# ============================================================
echo "Case 6: plugin.json missing"
reset_state
start_mock_pid; PID=$LAST_MOCK_PID
write_plugin_json "MISSING"
write_runtime_file "$PID" "2.17.0"
run_hook
EXIT=$?
assert "exit 0" "[ $EXIT -eq 0 ]"
assert "no warning emitted" "[ ! -s $TEST_DIR/hook.stderr ]"
assert "mock PID still alive" "ps -p $PID -o pid= >/dev/null 2>&1"
kill -KILL "$PID" 2>/dev/null || true

# ============================================================
# Case 7: binary_version field present, matches runtime → no kill (#73)
# Verifies hook prefers .binary_version over .version when comparing
# against runtime state. Pre-#73 fix: this would FAIL because hook
# compared runtime binary tag (2.8.5) against plugin.json shell version
# (2.19.5), triggering unnecessary kill on every session start.
# ============================================================
echo "Case 7: binary_version field present, matches runtime"
reset_state
start_mock_pid; PID=$LAST_MOCK_PID
# Shell v2.19.5 + binary v2.8.5 (post-#77 two-field schema)
write_plugin_json_with_binary "2.19.5" "2.8.5"
# Runtime state records binary tag, not shell version
write_runtime_file "$PID" "2.8.5"
run_hook
EXIT=$?
assert "exit 0" "[ $EXIT -eq 0 ]"
assert "no warning emitted" "[ ! -s $TEST_DIR/hook.stderr ]"
assert "mock PID still alive (binary_version matches, no kill)" "ps -p $PID -o pid= >/dev/null 2>&1"
kill -KILL "$PID" 2>/dev/null || true

# ============================================================
# Case 8: binary_version absent (legacy schema) → fallback to .version (#73)
# When plugin.json has no binary_version field (pre-#77 plugins), hook
# falls back to comparing against .version. Verifies backward compat.
# ============================================================
echo "Case 8: binary_version absent, fallback to .version"
reset_state
start_mock_pid; PID=$LAST_MOCK_PID
# Legacy single-field schema (no binary_version)
write_plugin_json "2.17.0"
# Runtime version_at_spawn matches plugin.json version
write_runtime_file "$PID" "2.17.0"
run_hook
EXIT=$?
assert "exit 0" "[ $EXIT -eq 0 ]"
assert "no warning emitted" "[ ! -s $TEST_DIR/hook.stderr ]"
assert "mock PID still alive (legacy fallback works)" "ps -p $PID -o pid= >/dev/null 2>&1"
kill -KILL "$PID" 2>/dev/null || true

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================="
echo "Results: $PASS pass, $FAIL fail"
echo "============================================="

if [ "$FAIL" -gt 0 ]; then
    printf "%b\n" "$FAIL_DETAIL"
    exit 1
fi
exit 0
