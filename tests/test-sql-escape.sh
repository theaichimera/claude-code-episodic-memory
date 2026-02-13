#!/usr/bin/env bash
# Test: Centralized SQL escaping function
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

echo "=== Test: SQL escape function ==="

# Test 1: Normal string unchanged
echo ""
echo "Test 1: Normal string passes through"
result=$(episodic_sql_escape "hello world")
assert_eq "No quotes unchanged" "hello world" "$result"

# Test 2: Single quotes are doubled
echo ""
echo "Test 2: Single quotes escaped"
result=$(episodic_sql_escape "O'Brien")
assert_eq "Single quote doubled" "O''Brien" "$result"

# Test 3: Multiple single quotes
echo ""
echo "Test 3: Multiple quotes"
result=$(episodic_sql_escape "it's a 'test' isn't it")
assert_eq "All quotes doubled" "it''s a ''test'' isn''t it" "$result"

# Test 4: Empty string
echo ""
echo "Test 4: Empty string"
result=$(episodic_sql_escape "")
assert_eq "Empty string ok" "" "$result"

# Test 5: String with no special chars
echo ""
echo "Test 5: No special chars"
result=$(episodic_sql_escape "abc 123 def")
assert_eq "Plain string ok" "abc 123 def" "$result"

# Test 6: Data with quotes can be inserted and retrieved
echo ""
echo "Test 6: Round-trip with quotes in data"
episodic_db_init "$EPISODIC_DB" >/dev/null 2>&1
safe_prompt=$(episodic_sql_escape "Fix the O'Brien bug in user's code")
sqlite3 "$EPISODIC_DB" "INSERT INTO sessions (id, project, created_at, first_prompt) VALUES ('t1', 'test', datetime('now'), '$safe_prompt');"
retrieved=$(sqlite3 "$EPISODIC_DB" "SELECT first_prompt FROM sessions WHERE id='t1';")
assert_eq "Data round-trips correctly" "Fix the O'Brien bug in user's code" "$retrieved"

# Test 7: No inline escaping remains in lib/ (except the function definition)
echo ""
echo "Test 7: No inline escaping patterns in lib/ or bin/"
# Look for the raw pattern: //\'/ which is the bash single-quote escape idiom
inline_matches=$(grep -rn "//\\\\'" "$SCRIPT_DIR/../lib/" "$SCRIPT_DIR/../bin/" 2>/dev/null \
    | grep -v 'episodic_sql_escape' \
    | grep -v "printf " \
    || true)
if [[ -z "$inline_matches" ]]; then
    echo "  ✓ No inline escaping outside function"
    PASS=$((PASS + 1))
else
    echo "  ✗ Found inline escaping:"
    echo "$inline_matches"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
