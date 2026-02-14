#!/usr/bin/env bash
# test-query.sh: Test FTS5 search and BM25 ranking
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

echo "=== test-query ==="

# Initialize DB
episodic_db_init "$TEST_DB" >/dev/null 2>&1

# Insert test data
echo -n "  Inserting test sessions... "

# Session 1: FTS5 focused
episodic_db_insert_session "s1" "myproject" "/Users/test/myproject" "" "" \
    "Set up FTS5 search for episodic memory" 20 10 10 "main" "2024-02-01T10:00:00Z" "2024-02-01T11:00:00Z" 60

summary1='{"topics":["FTS5 search","episodic memory","SQLite"],"decisions":["Use FTS5 over vector embeddings for simplicity"],"dead_ends":["Tried FAISS but too complex"],"artifacts_created":["lib/db.sh","bin/episodic-query"],"key_insights":["Porter stemming handles synonyms well"],"summary":"Built FTS5 search system for episodic memory using SQLite."}'
episodic_db_insert_summary "s1" "$summary1" "haiku"
episodic_db_update_log "s1" "complete"

# Session 2: API performance focused
episodic_db_insert_session "s2" "webapp" "/Users/test/webapp" "" "" \
    "Analyze API costs for project" 30 15 15 "feature-branch" "2024-02-02T10:00:00Z" "2024-02-02T12:00:00Z" 120

summary2='{"topics":["API performance","cost optimization","data processing"],"decisions":["Reduce processing frequency to save costs"],"dead_ends":["Tried switching to batch mode but latency issues"],"artifacts_created":["config/api-config.json"],"key_insights":["API performance varies by endpoint and tier, $50K/yr"],"summary":"Analyzed API performance for webapp data processing. Found $50K/yr spend on migration project."}'
episodic_db_insert_summary "s2" "$summary2" "haiku"
episodic_db_update_log "s2" "complete"

# Session 3: Unrelated session
episodic_db_insert_session "s3" "dashboard" "/Users/test/dashboard" "" "" \
    "Fix authentication bug" 15 8 7 "fix-auth" "2024-02-03T10:00:00Z" "2024-02-03T10:30:00Z" 30

summary3='{"topics":["authentication","OAuth","bug fix"],"decisions":["Switch to refresh token rotation"],"dead_ends":[],"artifacts_created":["auth/handler.ts"],"key_insights":["Refresh tokens must be rotated on each use"],"summary":"Fixed OAuth authentication bug by implementing refresh token rotation."}'
episodic_db_insert_summary "s3" "$summary3" "haiku"
episodic_db_update_log "s3" "complete"

echo "PASS (3 sessions inserted)"

# Test 1: Basic FTS5 search
echo -n "  Searching 'FTS5 search'... "
results=$(episodic_db_search "FTS5 search" 10)
first_id=$(echo "$results" | jq -r '.[0].id // empty')
if [[ "$first_id" == "s1" ]]; then
    echo "PASS (top result: s1)"
else
    echo "FAIL: expected s1 as top result, got: $first_id"
    echo "  Results: $results"
    exit 1
fi

# Test 2: API performance search
echo -n "  Searching 'API performance'... "
results=$(episodic_db_search "API performance" 10)
first_id=$(echo "$results" | jq -r '.[0].id // empty')
if [[ "$first_id" == "s2" ]]; then
    echo "PASS (top result: s2)"
else
    echo "FAIL: expected s2 as top result, got: $first_id"
    exit 1
fi

# Test 3: Search returns multiple results
echo -n "  Search result count... "
result_count=$(echo "$results" | jq 'length')
if [[ "$result_count" -ge 1 ]]; then
    echo "PASS ($result_count results)"
else
    echo "FAIL: expected >= 1 results"
    exit 1
fi

# Test 4: Authentication search finds s3
echo -n "  Searching 'OAuth authentication'... "
results=$(episodic_db_search "OAuth authentication" 10)
first_id=$(echo "$results" | jq -r '.[0].id // empty')
if [[ "$first_id" == "s3" ]]; then
    echo "PASS (top result: s3)"
else
    echo "FAIL: expected s3, got: $first_id"
    exit 1
fi

# Test 5: Recent sessions query
echo -n "  Recent sessions for 'myproject'... "
recent=$(episodic_db_recent "myproject" 5)
recent_count=$(echo "$recent" | jq 'length')
if [[ "$recent_count" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: expected 1, got $recent_count"
    exit 1
fi

# Test 6: Session count
echo -n "  Total session count... "
total=$(episodic_db_count)
if [[ "$total" == "3" ]]; then
    echo "PASS"
else
    echo "FAIL: expected 3, got $total"
    exit 1
fi

# Test 7: is_archived check
echo -n "  Checking is_archived... "
if episodic_db_is_archived "s1" && ! episodic_db_is_archived "s999"; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi

# Test 8: CLI query tool
echo -n "  CLI query tool... "
cli_output=$("$SCRIPT_DIR/../bin/episodic-query" --json "FTS5" 2>/dev/null)
cli_id=$(echo "$cli_output" | jq -r '.[0].id // empty')
if [[ "$cli_id" == "s1" ]]; then
    echo "PASS"
else
    echo "FAIL: CLI returned: $cli_output"
    exit 1
fi

# Test 9: CLI recent mode
echo -n "  CLI recent mode... "
cli_recent=$("$SCRIPT_DIR/../bin/episodic-query" --json --recent 2 2>/dev/null)
cli_recent_count=$(echo "$cli_recent" | jq 'length')
if [[ "$cli_recent_count" -ge 1 ]]; then
    echo "PASS ($cli_recent_count results)"
else
    echo "FAIL"
    exit 1
fi

echo "=== test-query: ALL PASS ==="
