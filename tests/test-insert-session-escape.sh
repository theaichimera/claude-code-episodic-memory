#!/usr/bin/env bash
# Test: All fields in episodic_db_insert_session are properly SQL-escaped
set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export EPISODIC_DATA_DIR="$TEST_DIR"
export EPISODIC_DB="$TEST_DIR/test.db"
export EPISODIC_LOG="$TEST_DIR/test.log"
export EPISODIC_KNOWLEDGE_DIR="$TEST_DIR/knowledge"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/db.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc: expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Test: episodic_db_insert_session escaping ==="

episodic_db_init "$EPISODIC_DB" >/dev/null 2>&1

# Test 1: Insert with single quotes in project name and git branch
echo ""
echo "Test 1: Single quotes in project, git_branch, and paths"
episodic_db_insert_session \
    "test-id-1" \
    "it's-a-project" \
    "/home/user/it's-a-project" \
    "/archives/it's-a-project/test.jsonl" \
    "/source/it's-here.jsonl" \
    "Fix the user's bug" \
    10 5 5 \
    "fix/user's-branch" \
    "2026-01-01T00:00:00Z" \
    "2026-01-01T01:00:00Z" \
    60

result=$(episodic_db_exec "SELECT project FROM sessions WHERE id='test-id-1';" "$EPISODIC_DB")
assert_eq "Project with quote stored correctly" "it's-a-project" "$result"

result=$(episodic_db_exec "SELECT git_branch FROM sessions WHERE id='test-id-1';" "$EPISODIC_DB")
assert_eq "Git branch with quote stored correctly" "fix/user's-branch" "$result"

result=$(episodic_db_exec "SELECT first_prompt FROM sessions WHERE id='test-id-1';" "$EPISODIC_DB")
assert_eq "First prompt with quote stored correctly" "Fix the user's bug" "$result"

result=$(episodic_db_exec "SELECT project_path FROM sessions WHERE id='test-id-1';" "$EPISODIC_DB")
assert_eq "Project path with quote stored correctly" "/home/user/it's-a-project" "$result"

# Test 2: Non-numeric values in numeric fields are defaulted to 0
echo ""
echo "Test 2: Non-numeric values in numeric fields default to 0"
episodic_db_insert_session \
    "test-id-2" \
    "testproj" \
    "/path" \
    "/archive" \
    "/source" \
    "prompt" \
    "not-a-number" "abc" "def" \
    "main" \
    "2026-01-01T00:00:00Z" \
    "2026-01-01T01:00:00Z" \
    "xyz"

result=$(episodic_db_exec "SELECT message_count FROM sessions WHERE id='test-id-2';" "$EPISODIC_DB")
assert_eq "Non-numeric message_count defaults to 0" "0" "$result"

result=$(episodic_db_exec "SELECT duration_minutes FROM sessions WHERE id='test-id-2';" "$EPISODIC_DB")
assert_eq "Non-numeric duration defaults to 0" "0" "$result"

# Test 3: Session ID with quotes
echo ""
echo "Test 3: Session ID with single quotes"
episodic_db_insert_session \
    "id'with'quotes" \
    "proj" \
    "/path" \
    "/archive" \
    "/source" \
    "prompt" \
    5 3 2 \
    "main" \
    "2026-01-01T00:00:00Z" \
    "2026-01-01T01:00:00Z" \
    30

count=$(episodic_db_exec "SELECT count(*) FROM sessions WHERE id='id''with''quotes';" "$EPISODIC_DB")
assert_eq "Session with quoted ID is stored" "1" "$count"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
