#!/usr/bin/env bash
# test-roundtrip.sh: Full capture → store → retrieve cycle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DB="/tmp/episodic-test-$$.db"
FIXTURE="$SCRIPT_DIR/fixtures/sample-session.jsonl"

# Override config
export EPISODIC_DB="$TEST_DB"
export EPISODIC_LOG="/tmp/episodic-test-$$.log"
export EPISODIC_ARCHIVE_DIR="/tmp/episodic-test-archives-$$"

source "$SCRIPT_DIR/../lib/db.sh"
source "$SCRIPT_DIR/../lib/extract.sh"

cleanup() {
    rm -f "$TEST_DB" "$EPISODIC_LOG"
    rm -rf "$EPISODIC_ARCHIVE_DIR"
}
trap cleanup EXIT

echo "=== test-roundtrip ==="

# Step 1: Initialize
echo -n "  Step 1: Init... "
"$SCRIPT_DIR/../bin/episodic-init" >/dev/null 2>&1
echo "PASS"

# Step 2: Archive with metadata only (no API key needed for test)
echo -n "  Step 2: Archive (metadata)... "
"$SCRIPT_DIR/../bin/episodic-archive" --no-summary "$FIXTURE" >/dev/null 2>&1
count=$(episodic_db_count)
if [[ "$count" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: expected 1 session, got $count"
    exit 1
fi

# Step 3: Manually insert a summary (simulating what Haiku would produce)
echo -n "  Step 3: Insert summary... "
summary='{"topics":["FTS5 search","episodic memory","API performance"],"decisions":["Use FTS5 over vector embeddings"],"dead_ends":["Considered FAISS but too complex"],"artifacts_created":["lib/db.sh","bin/episodic-query","config/api-config.json"],"key_insights":["Porter stemming handles synonyms","API performance varies by endpoint"],"summary":"Built FTS5 search for episodic memory and added API performance tracking."}'
episodic_db_insert_summary "test-session-001" "$summary" "test"
echo "PASS"

# Step 4: Search and verify
echo -n "  Step 4: Search 'FTS5'... "
results=$("$SCRIPT_DIR/../bin/episodic-query" --json "FTS5" 2>/dev/null)
found_id=$(echo "$results" | jq -r '.[0].id // empty')
if [[ "$found_id" == "test-session-001" ]]; then
    echo "PASS"
else
    echo "FAIL: expected test-session-001, got $found_id"
    exit 1
fi

# Step 5: Search for API performance
echo -n "  Step 5: Search 'API performance'... "
results2=$("$SCRIPT_DIR/../bin/episodic-query" --json "API performance" 2>/dev/null)
found_id2=$(echo "$results2" | jq -r '.[0].id // empty')
if [[ "$found_id2" == "test-session-001" ]]; then
    echo "PASS"
else
    echo "FAIL: expected test-session-001, got $found_id2"
    exit 1
fi

# Step 6: Verify summary content in results
echo -n "  Step 6: Verify summary content... "
summary_text=$(echo "$results" | jq -r '.[0].summary // empty')
if echo "$summary_text" | grep -q "FTS5"; then
    echo "PASS"
else
    echo "FAIL: summary doesn't contain 'FTS5': $summary_text"
    exit 1
fi

# Step 7: Verify decisions in results
echo -n "  Step 7: Verify decisions... "
decisions=$(echo "$results" | jq -r '.[0].decisions // empty')
if echo "$decisions" | grep -qi "FTS5\|vector"; then
    echo "PASS"
else
    echo "FAIL: decisions don't mention FTS5/vector: $decisions"
    exit 1
fi

# Step 8: Context generation
echo -n "  Step 8: Context generation... "
# The fixture uses project_dir based on the fixture path - derive it
stored_project=$(sqlite3 "$TEST_DB" "SELECT project FROM sessions LIMIT 1;")
context=$("$SCRIPT_DIR/../bin/episodic-context" --project "$stored_project" 2>/dev/null)
if [[ -n "$context" ]] && echo "$context" | grep -q "Recent Sessions"; then
    echo "PASS"
else
    echo "FAIL: context output unexpected: $context"
    exit 1
fi

# Step 9: Verify archive file exists
echo -n "  Step 9: Archive file... "
archive_count=$(find "$EPISODIC_ARCHIVE_DIR" -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$archive_count" -ge 1 ]]; then
    echo "PASS ($archive_count files)"
else
    echo "FAIL: no archive files found"
    exit 1
fi

echo "=== test-roundtrip: ALL PASS ==="
