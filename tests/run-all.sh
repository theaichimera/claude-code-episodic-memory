#!/usr/bin/env bash
# run-all.sh: Execute all tests, exit non-zero on any failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running all episodic-memory tests..."
echo ""

passed=0
failed=0
tests=("test-project-name" "test-init" "test-archive" "test-query" "test-roundtrip" "test-knowledge" "test-synthesize" "test-index")

regression_tests=(
    "test-busy-timeout"
    "test-git-lockfile"
    "test-sql-escape"
    "test-large-text-sql"
    "test-config-defaults"
    "test-content-hash"
    "test-schema-consistency"
    "test-sql-escape-context"
    "test-knowledge-init-env"
    "test-archive-retry"
    "test-fts5-escape"
    "test-insert-session-escape"
    "test-git-conflict-safety"
)

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
echo "Core tests: $passed passed, $failed failed"
echo "════════════════════════════════════"
echo ""

reg_passed=0
reg_failed=0

echo "Running regression tests..."
echo ""

for test in "${regression_tests[@]}"; do
    if bash "$SCRIPT_DIR/$test.sh"; then
        reg_passed=$((reg_passed + 1))
    else
        reg_failed=$((reg_failed + 1))
        echo "FAILED: $test"
    fi
    echo ""
done

echo "════════════════════════════════════"
echo "Core tests:       $passed passed, $failed failed"
echo "Regression tests: $reg_passed passed, $reg_failed failed"
echo "Total:            $((passed + reg_passed)) passed, $((failed + reg_failed)) failed"
echo "════════════════════════════════════"

[[ $((failed + reg_failed)) -eq 0 ]]
