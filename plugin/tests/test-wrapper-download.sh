#!/bin/bash
# Tests for bin/che-apple-mail-mcp-wrapper.sh download-chain integrity (#392, #393).
#
# Mock strategy (mirrors test-session-start-hook.sh):
# - PATH shim: a fake `curl` routes by URL against per-case scenario files;
#   a missing scenario file simulates `curl -f` failing on an HTTP error (exit 22).
# - HOME override puts INSTALL_DIR / sidecar / runtime / marker under $TEST_DIR.
# - The wrapper is copied into a fake plugin tree so BASH_SOURCE resolution works.
# - The "binary" the wrapper installs/execs is a tiny sh script printing a token,
#   so `exec "$BINARY"` terminates the subshell run cleanly.

set -u

TEST_DIR=$(mktemp -d -t test-wrapper-download.XXXXXX)
PASS=0
FAIL=0
FAIL_DETAIL=""

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

REAL_WRAPPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/che-apple-mail-mcp-wrapper.sh"
if [ ! -f "$REAL_WRAPPER" ]; then
    echo "ERROR: wrapper not found at $REAL_WRAPPER" >&2
    exit 2
fi

FAKE_PLUGIN="$TEST_DIR/fake-plugin"
mkdir -p "$FAKE_PLUGIN/bin" "$FAKE_PLUGIN/.claude-plugin"
cp "$REAL_WRAPPER" "$FAKE_PLUGIN/bin/che-apple-mail-mcp-wrapper.sh"
chmod +x "$FAKE_PLUGIN/bin/che-apple-mail-mcp-wrapper.sh"

SCEN="$TEST_DIR/scenario"
SHIM="$TEST_DIR/shim"
mkdir -p "$SCEN" "$SHIM"

# --- curl shim: routes by URL, honors -o, missing scenario file => exit 22 (-f) ---
cat > "$SHIM/curl" <<'SHIMEOF'
#!/bin/bash
SCEN="${WRAPPER_TEST_SCEN:?}"
url=""
out=""
prev=""
for a in "$@"; do
    case "$prev" in
        -o) out="$a" ;;
    esac
    case "$a" in
        https://*) url="$a" ;;
    esac
    prev="$a"
done
src=""
case "$url" in
    *"/releases/tags/"*)  src="$SCEN/api_pinned_response" ;;
    *"/releases/latest"*) src="$SCEN/api_latest_response" ;;
    *.sha256)             src="$SCEN/sha256_content" ;;
    *)                    src="$SCEN/binary_content" ;;
esac
[ -f "$src" ] || exit 22
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
exit 0
SHIMEOF
chmod +x "$SHIM/curl"

RUN_PATH="$SHIM:/usr/bin:/bin"
TEST_HOME="$TEST_DIR/home"

write_plugin_json() {
    printf '{"name":"test","version":"9.9.9","binary_version":"%s"}\n' "$1" \
        > "$FAKE_PLUGIN/.claude-plugin/plugin.json"
}

write_api_response() {
    # $1 = scenario file, $2 = version tag in the download URL
    printf '{"assets":[{"name":"CheAppleMailMCP","browser_download_url":"https://dl.test/repos/releases/download/v%s/CheAppleMailMCP"}]}\n' "$2" > "$1"
}

write_mock_binary_content() {
    # $1 = token the fake binary prints when exec'd
    printf '#!/bin/sh\necho %s\nexit 0\n' "$1" > "$SCEN/binary_content"
}

write_matching_sha() {
    shasum -a 256 "$SCEN/binary_content" | awk '{print $1}' > "$SCEN/sha256_content"
}

seed_installed() {
    # $1 = token, $2 = sidecar version — simulate an existing good install
    mkdir -p "$TEST_HOME/bin"
    printf '#!/bin/sh\necho %s\nexit 0\n' "$1" > "$TEST_HOME/bin/CheAppleMailMCP"
    chmod +x "$TEST_HOME/bin/CheAppleMailMCP"
    printf '%s\n' "$2" > "$TEST_HOME/bin/.CheAppleMailMCP.version"
}

run_wrapper() {
    HOME="$TEST_HOME" PATH="$RUN_PATH" WRAPPER_TEST_SCEN="$SCEN" \
        bash "$FAKE_PLUGIN/bin/che-apple-mail-mcp-wrapper.sh" \
        > "$TEST_DIR/out.txt" 2> "$TEST_DIR/err.txt"
    echo $? > "$TEST_DIR/exit_code"
}

reset_state() {
    rm -rf "$TEST_HOME" "$SCEN"
    mkdir -p "$TEST_HOME" "$SCEN"
    : > "$TEST_DIR/out.txt"; : > "$TEST_DIR/err.txt"
}

assert() {
    local name="$1" condition="$2"
    if eval "$condition"; then
        PASS=$((PASS+1)); printf "  PASS  %s\n" "$name"
    else
        FAIL=$((FAIL+1))
        FAIL_DETAIL="${FAIL_DETAIL}\n  FAIL  ${name}\n        cond: ${condition}\n        out: $(cat "$TEST_DIR/out.txt" 2>/dev/null)\n        err: $(cat "$TEST_DIR/err.txt" 2>/dev/null)"
        printf "  FAIL  %s\n" "$name"
    fi
}

RUNTIME="$TEST_HOME/bin/.CheAppleMailMCP.runtime.json"
SIDECAR="$TEST_HOME/bin/.CheAppleMailMCP.version"
MARKER="$TEST_HOME/bin/.CheAppleMailMCP.fallback-tried"

# ============================================================
echo "Case 1: fresh install, pinned tag found, sha256 verified"
# ============================================================
reset_state
write_plugin_json "2.99.0"
write_api_response "$SCEN/api_pinned_response" "2.99.0"
write_mock_binary_content "MOCK-RUN-299"
write_matching_sha
run_wrapper
assert "exec'd the installed binary" "grep -q MOCK-RUN-299 $TEST_DIR/out.txt"
assert "sidecar records actual tag"  "[ \"\$(cat $SIDECAR)\" = 2.99.0 ]"
assert "runtime records actual (=sidecar) version" "grep -q '\"version_at_spawn\":\"2.99.0\"' $RUNTIME"
assert "no fallback marker" "[ ! -f $MARKER ]"
assert "no unverified note" "! grep -q unverified $TEST_DIR/err.txt"

# ============================================================
echo "Case 2: sha256 mismatch — reject download, keep old binary (#392/#393)"
# ============================================================
reset_state
seed_installed "OLD-RUN-298" "2.98.0"
write_plugin_json "2.99.0"
write_api_response "$SCEN/api_pinned_response" "2.99.0"
write_mock_binary_content "EVIL-RUN"
echo "0000000000000000000000000000000000000000000000000000000000000000" > "$SCEN/sha256_content"
run_wrapper
assert "sha mismatch named on stderr" "grep -q 'sha256 mismatch' $TEST_DIR/err.txt"
assert "old binary still runs" "grep -q OLD-RUN-298 $TEST_DIR/out.txt"
assert "sidecar untouched (old version)" "[ \"\$(cat $SIDECAR)\" = 2.98.0 ]"
assert "runtime records OLD version, not desired (#393)" "grep -q '\"version_at_spawn\":\"2.98.0\"' $RUNTIME"
assert "tmp cleaned up" "[ ! -f $TEST_HOME/bin/CheAppleMailMCP.tmp ]"

# ============================================================
echo "Case 3: no .sha256 asset — disclose, install anyway (backward compat)"
# ============================================================
reset_state
write_plugin_json "2.99.0"
write_api_response "$SCEN/api_pinned_response" "2.99.0"
write_mock_binary_content "MOCK-RUN-299"
# no sha256_content file => curl -f fails on the .sha256 URL
run_wrapper
assert "unverified note on stderr" "grep -q 'installing unverified' $TEST_DIR/err.txt"
assert "binary installed and exec'd" "grep -q MOCK-RUN-299 $TEST_DIR/out.txt"
assert "sidecar records tag" "[ \"\$(cat $SIDECAR)\" = 2.99.0 ]"

# ============================================================
echo "Case 4: binary download fails entirely — keep old, runtime honest (#393)"
# ============================================================
reset_state
seed_installed "OLD-RUN-298" "2.98.0"
write_plugin_json "2.99.0"
write_api_response "$SCEN/api_pinned_response" "2.99.0"
# no binary_content file => download curl fails (exit 22)
run_wrapper
assert "download-failed warning" "grep -q 'download failed, keeping existing binary' $TEST_DIR/err.txt"
assert "old binary still runs" "grep -q OLD-RUN-298 $TEST_DIR/out.txt"
assert "runtime records OLD installed version (#393 core)" "grep -q '\"version_at_spawn\":\"2.98.0\"' $RUNTIME"

# ============================================================
echo "Case 5: pinned tag missing — fallback to latest once, then guard the loop (#392)"
# ============================================================
reset_state
write_plugin_json "2.99.0"
# no api_pinned_response => pinned lookup fails => PIN_MISS
write_api_response "$SCEN/api_latest_response" "3.0.0"
write_mock_binary_content "MOCK-RUN-300"
write_matching_sha
run_wrapper
assert "run1: latest installed" "grep -q MOCK-RUN-300 $TEST_DIR/out.txt"
assert "run1: sidecar records latest tag" "[ \"\$(cat $SIDECAR)\" = 3.0.0 ]"
assert "run1: fallback marker holds the missing pin" "[ \"\$(cat $MARKER)\" = 2.99.0 ]"
# second spawn, same pin: must NOT re-download (marker guard) — remove scenario
# files so any curl attempt would fail loudly
rm -f "$SCEN/api_latest_response" "$SCEN/binary_content" "$SCEN/sha256_content"
: > "$TEST_DIR/out.txt"; : > "$TEST_DIR/err.txt"
run_wrapper
assert "run2: guard note printed" "grep -q 'unavailable on a previous spawn' $TEST_DIR/err.txt"
assert "run2: installed binary runs without re-download" "grep -q MOCK-RUN-300 $TEST_DIR/out.txt"
assert "run2: runtime records installed 3.0.0 (#393)" "grep -q '\"version_at_spawn\":\"3.0.0\"' $RUNTIME"

# ============================================================
echo "Case 6: pin changed — stale marker ignored and cleared on successful pinned fetch"
# ============================================================
reset_state
seed_installed "OLD-RUN-300" "3.0.0"
mkdir -p "$TEST_HOME/bin"
printf '2.99.0\n' > "$MARKER"
write_plugin_json "3.1.0"
write_api_response "$SCEN/api_pinned_response" "3.1.0"
write_mock_binary_content "MOCK-RUN-310"
write_matching_sha
run_wrapper
assert "new pin downloads despite old marker" "grep -q MOCK-RUN-310 $TEST_DIR/out.txt"
assert "sidecar records new tag" "[ \"\$(cat $SIDECAR)\" = 3.1.0 ]"
assert "marker cleared after successful pinned fetch" "[ ! -f $MARKER ]"

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
