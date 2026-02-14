#!/usr/bin/env bash
# Test: FTS5 MATCH injection prevention via episodic_fts5_escape
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

echo "=== Test: FTS5 MATCH escape ==="

# Test 1: Simple string — each token quoted
echo ""
echo "Test 1: Simple string"
result=$(episodic_fts5_escape "hello world")
assert_eq "Simple string per-token quoted" '"hello" "world"' "$result"

# Test 2: FTS5 operators are neutralized
echo ""
echo "Test 2: FTS5 operators neutralized"
result=$(episodic_fts5_escape "error OR warning")
assert_eq "OR neutralized" '"error" "OR" "warning"' "$result"

result=$(episodic_fts5_escape "test*")
assert_eq "Wildcard neutralized" '"test*"' "$result"

result=$(episodic_fts5_escape "col:value")
assert_eq "Column prefix neutralized" '"col:value"' "$result"

# Test 3: Embedded double quotes are escaped
echo ""
echo "Test 3: Embedded double quotes"
result=$(episodic_fts5_escape 'say "hello"')
assert_eq "Double quotes doubled" '"say" """hello"""' "$result"

# Test 4: Parentheses stripped (would cause FTS5 syntax error)
echo ""
echo "Test 4: Parentheses stripped"
result=$(episodic_fts5_escape "error (connection refused)")
assert_eq "Parens removed" '"error" "connection" "refused"' "$result"

# Test 5: Single token
echo ""
echo "Test 5: Single token"
result=$(episodic_fts5_escape "optimization")
assert_eq "Single token" '"optimization"' "$result"

# Test 6: Empty string
echo ""
echo "Test 6: Empty string"
result=$(episodic_fts5_escape "")
assert_eq "Empty string" '' "$result"

# Test 7: Integration - search with special chars doesn't crash
echo ""
echo "Test 7: Integration - search with special chars"
episodic_db_init "$EPISODIC_DB" >/dev/null 2>&1

# Insert test data
episodic_db_insert_session "s1" "proj" "/p" "/a" "/s" "Fix error OR warning" 5 3 2 "main" "2026-01-01T00:00:00Z" "2026-01-01T01:00:00Z" 30
summary_json='{"topics":["error handling"],"decisions":["use OR operator"],"dead_ends":[],"artifacts_created":[],"key_insights":["errors happen"],"summary":"Fixed error OR warning in the code"}'
episodic_db_insert_summary "s1" "$summary_json" "test-model"

# Search with FTS5 operators - should not crash
result=$(episodic_db_search "error OR warning" 10 2>/dev/null || echo "CRASH")
if [[ "$result" != "CRASH" ]]; then
    echo "  ✓ Search with OR doesn't crash"
    PASS=$((PASS + 1))
else
    echo "  ✗ Search with OR crashed"
    FAIL=$((FAIL + 1))
fi

# Search with unbalanced quote - should not crash
result=$(episodic_db_search '"unclosed' 10 2>/dev/null || echo "CRASH")
if [[ "$result" != "CRASH" ]]; then
    echo "  ✓ Search with unbalanced quote doesn't crash"
    PASS=$((PASS + 1))
else
    echo "  ✗ Search with unbalanced quote crashed"
    FAIL=$((FAIL + 1))
fi

# Search with parentheses - should not crash
result=$(episodic_db_search "error )" 10 2>/dev/null || echo "CRASH")
if [[ "$result" != "CRASH" ]]; then
    echo "  ✓ Search with ) doesn't crash"
    PASS=$((PASS + 1))
else
    echo "  ✗ Search with ) crashed"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
