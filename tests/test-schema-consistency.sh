#!/usr/bin/env bash
# test-schema-consistency.sh: Verify documents schema is defined in one place with correct constraints
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DB="/tmp/episodic-test-schema-$$.db"

export EPISODIC_DB="$TEST_DB"
export EPISODIC_LOG="/tmp/episodic-test-$$.log"
export EPISODIC_ARCHIVE_DIR="/tmp/episodic-test-archives-$$"

source "$SCRIPT_DIR/../lib/db.sh"
source "$SCRIPT_DIR/../lib/index.sh"

cleanup() { rm -f "$TEST_DB" "$EPISODIC_LOG"; rm -rf "$EPISODIC_ARCHIVE_DIR"; }
trap cleanup EXIT

echo "=== test-schema-consistency ==="

# Test 1: Create via db.sh, verify documents table exists
echo -n "  1. Documents table created by db_init... "
episodic_db_init "$TEST_DB"
tbl=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='documents';")
if [[ "$tbl" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: documents table not created"
    exit 1
fi

# Test 2: indexed_at is NOT NULL
echo -n "  2. indexed_at is NOT NULL... "
notnull=$(sqlite3 "$TEST_DB" "PRAGMA table_info(documents);" | grep '|indexed_at|' | cut -d'|' -f4)
if [[ "$notnull" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: indexed_at should be NOT NULL, got notnull=$notnull"
    exit 1
fi

# Test 3: documents_fts exists
echo -n "  3. documents_fts exists... "
fts=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='documents_fts';")
if [[ "$fts" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: documents_fts not found"
    exit 1
fi

# Test 4: episodic_db_init_documents is idempotent (calls db_init again)
echo -n "  4. episodic_db_init_documents idempotent... "
episodic_db_init_documents "$TEST_DB"
tbl2=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='documents';")
if [[ "$tbl2" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi

echo "=== test-schema-consistency: ALL PASS ==="
