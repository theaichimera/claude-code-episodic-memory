#!/usr/bin/env bash
# Test: Failed summaries leave sessions in retryable state
set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export EPISODIC_DATA_DIR="$TEST_DIR"
export EPISODIC_DB="$TEST_DIR/test.db"
export EPISODIC_LOG="$TEST_DIR/test.log"
export EPISODIC_KNOWLEDGE_DIR="$TEST_DIR/knowledge"
export EPISODIC_ARCHIVE_DIR="$TEST_DIR/archives"

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

echo "=== Test: Archive retry on summary failure ==="

episodic_db_init "$EPISODIC_DB" >/dev/null 2>&1

# Test 1: Session with 'complete' status IS considered archived
echo ""
echo "Test 1: Complete session is archived"
episodic_db_insert_session "s1" "proj" "/p" "/a" "/s" "prompt" 5 3 2 "main" "2026-01-01T00:00:00Z" "2026-01-01T01:00:00Z" 30
episodic_db_update_log "s1" "complete"
if episodic_db_is_archived "s1"; then
    echo "  ✓ Complete session is archived"
    PASS=$((PASS + 1))
else
    echo "  ✗ Complete session should be archived"
    FAIL=$((FAIL + 1))
fi

# Test 2: Session with 'too_short' status IS considered archived
echo ""
echo "Test 2: Too-short session is archived"
episodic_db_insert_session "s2" "proj" "/p" "/a" "/s" "hi" 1 1 0 "main" "2026-01-01T00:00:00Z" "2026-01-01T00:01:00Z" 1
episodic_db_update_log "s2" "too_short"
if episodic_db_is_archived "s2"; then
    echo "  ✓ Too-short session is archived"
    PASS=$((PASS + 1))
else
    echo "  ✗ Too-short session should be archived"
    FAIL=$((FAIL + 1))
fi

# Test 3: Session with 'no_summary' status IS considered archived
echo ""
echo "Test 3: No-summary session is archived"
episodic_db_insert_session "s3" "proj" "/p" "/a" "/s" "prompt" 5 3 2 "main" "2026-01-01T00:00:00Z" "2026-01-01T01:00:00Z" 30
episodic_db_update_log "s3" "no_summary"
if episodic_db_is_archived "s3"; then
    echo "  ✓ No-summary session is archived"
    PASS=$((PASS + 1))
else
    echo "  ✗ No-summary session should be archived"
    FAIL=$((FAIL + 1))
fi

# Test 4: Session with 'summary_failed' status is NOT archived (will be retried)
echo ""
echo "Test 4: Failed summary is NOT archived (retryable)"
episodic_db_insert_session "s4" "proj" "/p" "/a" "/s" "prompt" 5 3 2 "main" "2026-01-01T00:00:00Z" "2026-01-01T01:00:00Z" 30
episodic_db_update_log "s4" "summary_failed"
if episodic_db_is_archived "s4"; then
    echo "  ✗ Failed session should NOT be archived"
    FAIL=$((FAIL + 1))
else
    echo "  ✓ Failed session is retryable"
    PASS=$((PASS + 1))
fi

# Test 5: Session with 'pending' status is NOT archived (will be retried)
echo ""
echo "Test 5: Pending session is NOT archived (retryable)"
episodic_db_insert_session "s5" "proj" "/p" "/a" "/s" "prompt" 5 3 2 "main" "2026-01-01T00:00:00Z" "2026-01-01T01:00:00Z" 30
episodic_db_update_log "s5" "pending"
if episodic_db_is_archived "s5"; then
    echo "  ✗ Pending session should NOT be archived"
    FAIL=$((FAIL + 1))
else
    echo "  ✓ Pending session is retryable"
    PASS=$((PASS + 1))
fi

# Test 6: Session with NO archive_log entry is NOT archived
echo ""
echo "Test 6: Session with no log entry is NOT archived"
episodic_db_insert_session "s6" "proj" "/p" "/a" "/s" "prompt" 5 3 2 "main" "2026-01-01T00:00:00Z" "2026-01-01T01:00:00Z" 30
# No episodic_db_update_log call
if episodic_db_is_archived "s6"; then
    echo "  ✗ Session without log entry should NOT be archived"
    FAIL=$((FAIL + 1))
else
    echo "  ✓ Session without log entry is retryable"
    PASS=$((PASS + 1))
fi

# Test 7: After updating status from failed to complete, session IS archived
echo ""
echo "Test 7: Retry success transitions to archived"
episodic_db_update_log "s4" "complete"
if episodic_db_is_archived "s4"; then
    echo "  ✓ Retried session is now archived"
    PASS=$((PASS + 1))
else
    echo "  ✗ Retried session should be archived after status update"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
