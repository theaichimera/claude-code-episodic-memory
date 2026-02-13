#!/usr/bin/env bash
# run-all.sh: Execute all tests, exit non-zero on any failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running all episodic-memory tests..."
echo ""

passed=0
failed=0
tests=("test-init" "test-archive" "test-query" "test-roundtrip" "test-knowledge" "test-synthesize" "test-index")

for test in "${tests[@]}"; do
    if bash "$SCRIPT_DIR/$test.sh"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        echo "FAILED: $test"
    fi
    echo ""
done

echo "════════════════════════════════════"
echo "Results: $passed passed, $failed failed"
echo "════════════════════════════════════"

[[ $failed -eq 0 ]]
