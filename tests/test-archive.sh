#!/usr/bin/env bash
# test-archive.sh: Archive a session, verify metadata and summary
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

echo "=== test-archive ==="

# Initialize DB
episodic_db_init "$TEST_DB" >/dev/null 2>&1

# Test 1: Extract metadata
echo -n "  Extracting metadata... "
metadata=$(episodic_extract_metadata "$FIXTURE")
session_id=$(echo "$metadata" | jq -r '.session_id')
first_prompt=$(echo "$metadata" | jq -r '.first_prompt')
user_count=$(echo "$metadata" | jq -r '.user_message_count')
assistant_count=$(echo "$metadata" | jq -r '.assistant_message_count')

if [[ "$session_id" == "test-session-001" ]]; then
    echo "PASS (session_id=$session_id)"
else
    echo "FAIL: expected test-session-001, got $session_id"
    exit 1
fi

# Test 2: Check message counts
echo -n "  Checking message counts... "
if [[ "$user_count" == "4" && "$assistant_count" == "4" ]]; then
    echo "PASS (user=$user_count, assistant=$assistant_count)"
else
    echo "FAIL: expected user=4, assistant=4, got user=$user_count, assistant=$assistant_count"
    exit 1
fi

# Test 3: Check first prompt extraction
echo -n "  Checking first prompt... "
if echo "$first_prompt" | grep -q "FTS5"; then
    echo "PASS"
else
    echo "FAIL: first prompt doesn't contain 'FTS5': $first_prompt"
    exit 1
fi

# Test 4: Extract transcript
echo -n "  Extracting transcript... "
transcript=$(episodic_extract "$FIXTURE")
if [[ ${#transcript} -gt 100 ]]; then
    echo "PASS (${#transcript} chars)"
else
    echo "FAIL: transcript too short (${#transcript} chars)"
    exit 1
fi

# Test 5: Transcript contains user and assistant messages
echo -n "  Checking transcript content... "
if echo "$transcript" | grep -q "USER:" && echo "$transcript" | grep -q "ASSISTANT:"; then
    echo "PASS"
else
    echo "FAIL: transcript missing USER: or ASSISTANT: markers"
    exit 1
fi

# Test 6: Transcript filters out progress/snapshot events
echo -n "  Checking noise filtering... "
if echo "$transcript" | grep -q "file-history-snapshot"; then
    echo "FAIL: transcript contains file-history-snapshot"
    exit 1
else
    echo "PASS"
fi

# Test 7: Archive without summary (no API key needed)
echo -n "  Archiving (metadata only)... "
"$SCRIPT_DIR/../bin/episodic-archive" --no-summary "$FIXTURE" >/dev/null 2>&1
count=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM sessions;")
if [[ "$count" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: expected 1 session, got $count"
    exit 1
fi

# Test 8: Verify session data
echo -n "  Verifying stored data... "
stored_project=$(sqlite3 "$TEST_DB" "SELECT project FROM sessions WHERE id='test-session-001';")
stored_branch=$(sqlite3 "$TEST_DB" "SELECT git_branch FROM sessions WHERE id='test-session-001';")
# Project is derived from parent dir name, which for the fixture is "fixtures"
if [[ -n "$stored_project" && "$stored_branch" == "main" ]]; then
    echo "PASS (project=$stored_project, branch=$stored_branch)"
else
    echo "FAIL: project=$stored_project, branch=$stored_branch"
    exit 1
fi

# Test 9: Archive is idempotent
echo -n "  Testing idempotency... "
"$SCRIPT_DIR/../bin/episodic-archive" --no-summary "$FIXTURE" >/dev/null 2>&1
count2=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM sessions;")
if [[ "$count2" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: duplicate created, count=$count2"
    exit 1
fi

# Test 10: Verify archive file copied
echo -n "  Checking archive copy... "
if ls "$EPISODIC_ARCHIVE_DIR"/*/sample-session.jsonl &>/dev/null; then
    echo "PASS"
else
    echo "FAIL: archive file not found in $EPISODIC_ARCHIVE_DIR"
    exit 1
fi

echo "=== test-archive: ALL PASS ==="
