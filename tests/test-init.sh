#!/usr/bin/env bash
# test-init.sh: Verify database creation and idempotency
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DB="/tmp/episodic-test-$$.db"

# Override config
export EPISODIC_DB="$TEST_DB"
export EPISODIC_LOG="/tmp/episodic-test-$$.log"
export EPISODIC_ARCHIVE_DIR="/tmp/episodic-test-archives-$$"

source "$SCRIPT_DIR/../lib/db.sh"

cleanup() {
    rm -f "$TEST_DB" "$EPISODIC_LOG"
    rm -rf "$EPISODIC_ARCHIVE_DIR"
}
trap cleanup EXIT

echo "=== test-init ==="

# Test 1: Create database
echo -n "  Creating database... "
episodic_db_init "$TEST_DB"
if [[ -f "$TEST_DB" ]]; then
    echo "PASS"
else
    echo "FAIL: database file not created"
    exit 1
fi

# Test 2: Verify tables exist
echo -n "  Checking tables... "
tables=$(sqlite3 "$TEST_DB" ".tables")
for table in sessions summaries archive_log sessions_fts; do
    if ! echo "$tables" | grep -q "$table"; then
        echo "FAIL: table '$table' not found. Got: $tables"
        exit 1
    fi
done
echo "PASS (sessions, summaries, archive_log, sessions_fts)"

# Test 3: Verify schema columns
echo -n "  Checking sessions schema... "
cols=$(sqlite3 "$TEST_DB" "PRAGMA table_info(sessions);" | cut -d'|' -f2 | tr '\n' ',')
for col in id project project_path archive_path first_prompt message_count created_at; do
    if ! echo "$cols" | grep -q "$col"; then
        echo "FAIL: column '$col' not found"
        exit 1
    fi
done
echo "PASS"

# Test 4: Verify FTS5
echo -n "  Checking FTS5 virtual table... "
fts_count=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM sessions_fts;")
if [[ "$fts_count" == "0" ]]; then
    echo "PASS (empty FTS5 table exists)"
else
    echo "FAIL: unexpected FTS5 count: $fts_count"
    exit 1
fi

# Test 5: Idempotency - run init again
echo -n "  Testing idempotency... "
episodic_db_init "$TEST_DB"
tables2=$(sqlite3 "$TEST_DB" ".tables")
if [[ "$tables" == "$tables2" ]]; then
    echo "PASS"
else
    echo "FAIL: schema changed on second init"
    exit 1
fi

# Test 6: Verify index
echo -n "  Checking index... "
idx=$(sqlite3 "$TEST_DB" ".indices sessions" 2>/dev/null)
if echo "$idx" | grep -q "idx_sessions_project_created"; then
    echo "PASS"
else
    echo "FAIL: index not found"
    exit 1
fi

echo "=== test-init: ALL PASS ==="
