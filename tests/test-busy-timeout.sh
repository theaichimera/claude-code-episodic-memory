#!/usr/bin/env bash
# Test: SQLite busy_timeout is applied via wrapper functions
set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export EPISODIC_DATA_DIR="$TEST_DIR"
export EPISODIC_DB="$TEST_DIR/test.db"
export EPISODIC_LOG_FILE="$TEST_DIR/test.log"
export EPISODIC_KNOWLEDGE_DIR="$TEST_DIR/knowledge"
export EPISODIC_BUSY_TIMEOUT=3000

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

echo "=== Test: SQLite busy_timeout ==="

# Test 1: episodic_db_exec sets busy_timeout and runs queries
echo ""
echo "Test 1: episodic_db_exec works with busy_timeout"
episodic_db_init "$EPISODIC_DB" >/dev/null 2>&1
result=$(episodic_db_exec "SELECT count(*) FROM sessions;" "$EPISODIC_DB")
assert_eq "Session count returns 0" "0" "$result"

# Test 2: episodic_db_exec_multi works with heredoc
echo ""
echo "Test 2: episodic_db_exec_multi handles multi-statement blocks"
episodic_db_exec_multi "$EPISODIC_DB" <<'SQL'
INSERT INTO sessions (id, project, created_at) VALUES ('t1', 'testproj', datetime('now'));
INSERT INTO sessions (id, project, created_at) VALUES ('t2', 'testproj', datetime('now'));
SQL
result=$(episodic_db_exec "SELECT count(*) FROM sessions;" "$EPISODIC_DB")
assert_eq "Two rows inserted via exec_multi" "2" "$result"

# Test 3: episodic_db_query_json returns valid JSON
echo ""
echo "Test 3: episodic_db_query_json returns JSON"
json_result=$(episodic_db_query_json "SELECT id, project FROM sessions ORDER BY id;" "$EPISODIC_DB")
id_count=$(echo "$json_result" | jq length)
assert_eq "JSON result has 2 entries" "2" "$id_count"
first_id=$(echo "$json_result" | jq -r '.[0].id')
assert_eq "First id is t1" "t1" "$first_id"

# Test 4: Custom EPISODIC_BUSY_TIMEOUT is respected
echo ""
echo "Test 4: Custom busy_timeout value is used"
# We verify by checking that the PRAGMA is sent (indirectly by ensuring it doesn't error)
export EPISODIC_BUSY_TIMEOUT=100
result=$(episodic_db_exec "SELECT count(*) FROM sessions;" "$EPISODIC_DB")
assert_eq "Query works with custom timeout" "2" "$result"

# Test 5: No raw sqlite3 calls remain in lib/ and bin/ (outside wrappers and tests)
echo ""
echo "Test 5: No raw sqlite3 calls outside wrappers"
raw_calls=$(grep -rn 'sqlite3 ' "$SCRIPT_DIR/../lib/" "$SCRIPT_DIR/../bin/" 2>/dev/null \
    | grep -v 'episodic_db_exec\|episodic_db_query_json\|episodic_db_exec_multi' \
    | grep -v '# .*sqlite3' \
    | grep -v 'command -v sqlite3' \
    | grep -v 'sqlite3 --version' \
    | grep -v 'db\.sh:.*sqlite3 ' \
    || true)
if [[ -z "$raw_calls" ]]; then
    echo "  ✓ No raw sqlite3 calls found outside wrappers"
    PASS=$((PASS + 1))
else
    echo "  ✗ Found raw sqlite3 calls:"
    echo "$raw_calls"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
