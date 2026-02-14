#!/usr/bin/env bash
# test-project-name.sh: Verify project name derivation handles dashes correctly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export EPISODIC_DB="/tmp/episodic-test-$$.db"
export EPISODIC_LOG="/tmp/episodic-test-$$.log"
export EPISODIC_ARCHIVE_DIR="/tmp/episodic-test-archives-$$"

source "$SCRIPT_DIR/../lib/config.sh"

# Use a base dir whose name has no dashes (avoids path ambiguity in tests)
TMPBASE="/tmp/eptest$$"

cleanup() {
    rm -f "$EPISODIC_DB" "$EPISODIC_LOG"
    rm -rf "$EPISODIC_ARCHIVE_DIR" "$TMPBASE"
}
trap cleanup EXIT

echo "=== test-project-name ==="

# Test 1: Simple project name (no dashes in final component)
echo -n "  1. Simple project name... "
mkdir -p "$TMPBASE/simple"
result=$(episodic_project_from_path "-tmp-eptest$$-simple")
if [[ "$result" == "simple" ]]; then
    echo "PASS ($result)"
else
    echo "FAIL: expected 'simple', got '$result'"
    exit 1
fi

# Test 2: Multi-dash project name (e.g., my-cool-app)
echo -n "  2. Multi-dash project name... "
mkdir -p "$TMPBASE/my-cool-app"
result=$(episodic_project_from_path "-tmp-eptest$$-my-cool-app")
if [[ "$result" == "my-cool-app" ]]; then
    echo "PASS ($result)"
else
    echo "FAIL: expected 'my-cool-app', got '$result'"
    exit 1
fi

# Test 3: Deeply nested project with dashes
echo -n "  3. Deeply nested with dashes... "
mkdir -p "$TMPBASE/sub/claude-code-episodic-memory"
result=$(episodic_project_from_path "-tmp-eptest$$-sub-claude-code-episodic-memory")
if [[ "$result" == "claude-code-episodic-memory" ]]; then
    echo "PASS ($result)"
else
    echo "FAIL: expected 'claude-code-episodic-memory', got '$result'"
    exit 1
fi

# Test 4: episodic_project_from_cwd uses basename
echo -n "  4. episodic_project_from_cwd... "
CWD="$TMPBASE/my-cool-app"
result=$(episodic_project_from_cwd)
if [[ "$result" == "my-cool-app" ]]; then
    echo "PASS ($result)"
else
    echo "FAIL: expected 'my-cool-app', got '$result'"
    exit 1
fi

# Test 5: Fallback when filesystem path doesn't exist
echo -n "  5. Fallback for non-existent path... "
result=$(episodic_project_from_path "-nonexistent-zzz-foo-bar")
# Should fall back to last segment
if [[ "$result" == "bar" ]]; then
    echo "PASS ($result)"
else
    echo "FAIL: expected 'bar', got '$result'"
    exit 1
fi

# Test 6: Exact match (directory exists at exact reconstructed path)
echo -n "  6. Exact path match... "
mkdir -p "$TMPBASE/exactmatch"
result=$(episodic_project_from_path "-tmp-eptest$$-exactmatch")
if [[ "$result" == "exactmatch" ]]; then
    echo "PASS ($result)"
else
    echo "FAIL: expected 'exactmatch', got '$result'"
    exit 1
fi

echo "=== test-project-name: ALL PASS ==="
