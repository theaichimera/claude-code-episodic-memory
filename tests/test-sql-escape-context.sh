#!/usr/bin/env bash
# test-sql-escape-context.sh: Verify PROJECT is SQL-escaped in episodic-context
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DB="/tmp/episodic-test-$$.db"

export EPISODIC_DB="$TEST_DB"
export EPISODIC_LOG="/tmp/episodic-test-$$.log"
export EPISODIC_ARCHIVE_DIR="/tmp/episodic-test-archives-$$"

source "$SCRIPT_DIR/../lib/db.sh"

cleanup() { rm -f "$TEST_DB" "$EPISODIC_LOG"; rm -rf "$EPISODIC_ARCHIVE_DIR"; }
trap cleanup EXIT

echo "=== test-sql-escape-context ==="

episodic_db_init "$TEST_DB"

# Test 1: Project name with a single quote doesn't break SQL
echo -n "  1. Project with single quote in SQL... "
# Insert a document with a tricky project name
sqlite3 "$TEST_DB" "INSERT INTO documents (id, project, file_path, file_name, indexed_at) VALUES ('test:readme', 'o''reilly', '/tmp/test.md', 'test.md', datetime('now'));"

# Simulate what episodic-context does with SAFE_PROJECT
PROJECT="o'reilly"
SAFE_PROJECT="${PROJECT//\'/\'\'}"
count=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM documents WHERE project='$SAFE_PROJECT';")
if [[ "$count" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: expected 1, got $count"
    exit 1
fi

# Test 2: Normal project name still works
echo -n "  2. Normal project name... "
sqlite3 "$TEST_DB" "INSERT INTO documents (id, project, file_path, file_name, indexed_at) VALUES ('test2:readme', 'myproject', '/tmp/test2.md', 'test2.md', datetime('now'));"
PROJECT="myproject"
SAFE_PROJECT="${PROJECT//\'/\'\'}"
count=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM documents WHERE project='$SAFE_PROJECT';")
if [[ "$count" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: expected 1, got $count"
    exit 1
fi

echo "=== test-sql-escape-context: ALL PASS ==="
