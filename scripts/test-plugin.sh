#!/bin/bash
# Run every shipped plugin suite; failures must propagate to make test (#337).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

required="plugin/tests/test-session-start-hook.sh"
[[ -f "$required" ]] || { echo "error: required plugin suite missing: $required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: plugin tests require jq on PATH" >&2; exit 1; }

shopt -s nullglob
shell_tests=(plugin/tests/test-*.sh)
python_tests=(plugin/tests/test-*.py)
if [[ ${#python_tests[@]} -gt 0 ]]; then
    command -v python3 >/dev/null 2>&1 || { echo "error: plugin Python tests require python3 on PATH" >&2; exit 1; }
fi

count=0
for test in "${shell_tests[@]}"; do
    echo "Running $test"
    /bin/bash "$test"
    count=$((count + 1))
done
# Bash 3.2 treats an empty array expansion as unset under set -u.
if [[ ${#python_tests[@]} -gt 0 ]]; then
    for test in "${python_tests[@]}"; do
        echo "Running $test"
        python3 "$test"
        count=$((count + 1))
    done
fi
echo "Plugin suites passed: $count"
