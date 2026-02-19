#!/usr/bin/env bash
# Test suite for activity intelligence
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Use temp database for testing
export PI_DB="/tmp/test-activity-$$.db"
export PI_ROOT="$PROJECT_DIR"
export PI_ACTIVITY_GATHER_DAYS=30
export PI_ACTIVITY_GITHUB_ORG=""

source "$PROJECT_DIR/lib/activity.sh"

PASSED=0
FAILED=0
TOTAL=0

pass() { PASSED=$((PASSED+1)); TOTAL=$((TOTAL+1)); echo "  ✓ $1"; }
fail() { FAILED=$((FAILED+1)); TOTAL=$((TOTAL+1)); echo "  ✗ $1: $2"; }

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$msg"
    else
        fail "$msg" "expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local actual="$1" expected="$2" msg="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        pass "$msg"
    else
        fail "$msg" "expected to contain '$expected' in '$actual'"
    fi
}

cleanup() {
    rm -f "$PI_DB" "/tmp/test-activity-$$"*
}
trap cleanup EXIT

echo "=== Activity Intelligence Tests ==="
echo ""

# Initialize
episodic_db_init
echo "Database initialized at $PI_DB"
echo ""

# ─── Test: Schema creation ────────────────────────────────
echo "--- Schema Tests ---"

count=$(episodic_db_exec "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='activities';")
assert_eq "$count" "1" "activities table created"

count=$(episodic_db_exec "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='activity_sources';")
assert_eq "$count" "1" "activity_sources table created"

count=$(episodic_db_exec "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='activities_fts';")
assert_eq "$count" "1" "activities_fts virtual table created"

# Idempotent re-init
episodic_db_init
count=$(episodic_db_exec "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='activities';")
assert_eq "$count" "1" "idempotent re-init preserves tables"

echo ""

# ─── Test: Source management ──────────────────────────────
echo "--- Source Management Tests ---"

pi_activity_add_source "testuser" "test-user" "test-org" > /dev/null
count=$(episodic_db_exec "SELECT count(*) FROM activity_sources WHERE id='github:testuser';")
assert_eq "$count" "1" "add source creates record"

slug=$(episodic_db_exec "SELECT user_slug FROM activity_sources WHERE id='github:testuser';")
assert_eq "$slug" "test-user" "source has correct user_slug"

type=$(episodic_db_exec "SELECT source_type FROM activity_sources WHERE id='github:testuser';")
assert_eq "$type" "github" "source has correct type"

# List sources
result=$(pi_activity_list_sources "test-user")
assert_contains "$result" "testuser" "list sources returns the added source"

result=$(pi_activity_list_sources "nonexistent")
assert_eq "$result" "" "list sources for unknown user returns empty"

echo ""

# ─── Test: Activity insert via internal function ──────────
echo "--- Activity Insert Tests ---"

_pi_activity_upsert "issue_created" "github:testuser" "test-org/test-repo" "42" \
    "Fix the bug" "Some description" "https://github.com/test/42" "2026-02-15T10:00:00Z" "{}"

count=$(episodic_db_exec "SELECT count(*) FROM activities;")
assert_eq "$count" "1" "upsert creates activity record"

title=$(episodic_db_exec "SELECT title FROM activities WHERE id='github:testuser:issue_created:test-org/test-repo:42';")
assert_eq "$title" "Fix the bug" "activity has correct title"

project=$(episodic_db_exec "SELECT project FROM activities WHERE id='github:testuser:issue_created:test-org/test-repo:42';")
assert_eq "$project" "test-repo" "project derived from repo name"

# FTS entry created
fts_count=$(episodic_db_exec "SELECT count(*) FROM activities_fts WHERE activities_fts MATCH '\"bug\"';")
assert_eq "$fts_count" "1" "FTS entry created for activity"

# Upsert (update existing)
_pi_activity_upsert "issue_created" "github:testuser" "test-org/test-repo" "42" \
    "Fix the critical bug" "Updated description" "https://github.com/test/42" "2026-02-15T10:00:00Z" "{}"

count=$(episodic_db_exec "SELECT count(*) FROM activities;")
assert_eq "$count" "1" "upsert updates existing record (no duplicates)"

title=$(episodic_db_exec "SELECT title FROM activities WHERE id='github:testuser:issue_created:test-org/test-repo:42';")
assert_eq "$title" "Fix the critical bug" "upsert updates title"

echo ""

# ─── Test: Multiple activities ────────────────────────────
echo "--- Multiple Activities Tests ---"

_pi_activity_upsert "pr_created" "github:testuser" "test-org/another-repo" "10" \
    "Add feature X" "" "https://github.com/test/pr/10" "2026-02-16T10:00:00Z" "{}"

_pi_activity_upsert "commit" "github:testuser" "test-org/test-repo" "abc123" \
    "refactor: improve performance" "" "" "2026-02-17T10:00:00Z" "{}"

_pi_activity_upsert "issue_created" "github:testuser" "test-org/cost-engineering" "72" \
    "Migrate DynamoDB to S3+Athena" "Khoros cost optimization" "https://github.com/test/72" "2026-02-18T10:00:00Z" "{\"savings\":300000}"

count=$(episodic_db_exec "SELECT count(*) FROM activities;")
assert_eq "$count" "4" "multiple activities inserted"

echo ""

# ─── Test: Search ─────────────────────────────────────────
echo "--- Search Tests ---"

result=$(pi_activity_search "DynamoDB" "10" "")
assert_contains "$result" "DynamoDB" "search finds activity by title"

result=$(pi_activity_search "cost-engineering" "10" "")
assert_contains "$result" "cost-engineering" "search finds activity by repo"

result=$(pi_activity_search "nonexistent_query_xyz" "10" "")
if [[ -z "$result" || "$result" == "[]" ]]; then
    pass "search returns empty for no match"
else
    fail "search returns empty for no match" "got: $result"
fi

echo ""

# ─── Test: Recent ─────────────────────────────────────────
echo "--- Recent Activities Tests ---"

# Insert a very recent activity
_pi_activity_upsert "issue_created" "github:testuser" "test-org/fresh-repo" "99" \
    "Fresh issue today" "" "" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "{}"

result=$(pi_activity_recent "" "1" "10")
assert_contains "$result" "Fresh issue today" "recent returns today's activity"

result=$(pi_activity_recent "test-user" "1" "10")
assert_contains "$result" "Fresh issue today" "recent filters by user_slug"

result=$(pi_activity_recent "nonexistent-user" "1" "10")
if [[ -z "$result" || "$result" == "[]" ]]; then
    pass "recent returns empty for unknown user"
else
    fail "recent returns empty for unknown user" "got results"
fi

echo ""

# ─── Test: Report ─────────────────────────────────────────
echo "--- Report Tests ---"

result=$(pi_activity_report "test-user" "2026-02" "summary")
assert_contains "$result" "Activity Report" "report generates summary header"
assert_contains "$result" "issue_created" "report shows issue_created type"

result=$(pi_activity_report "test-user" "2026-02" "json")
if echo "$result" | jq . &>/dev/null; then
    pass "report json format is valid JSON"
else
    fail "report json format is valid JSON" "invalid JSON output"
fi

echo ""

# ─── Test: Context injection ──────────────────────────────
echo "--- Context Injection Tests ---"

result=$(pi_activity_generate_context "" "365")
assert_contains "$result" "Recent Activity" "context injection generates header"

result=$(pi_activity_generate_context "nonexistent-user" "1")
if [[ -z "$result" ]]; then
    pass "context injection returns empty for unknown user"
else
    fail "context injection returns empty for unknown user" "got: $result"
fi

echo ""

# ─── Test: SQL injection safety ───────────────────────────
echo "--- Security Tests ---"

# SQL injection in source name
pi_activity_add_source "test'; DROP TABLE activities; --" "safe-user" "" > /dev/null 2>&1 || true
count=$(episodic_db_exec "SELECT count(*) FROM activities;")
if [[ "$count" -ge 1 ]]; then
    pass "SQL injection in source name does not drop table"
else
    fail "SQL injection in source name does not drop table" "activities table appears dropped"
fi

# SQL injection in activity title
_pi_activity_upsert "issue_created" "github:testuser" "test-org/repo" "injection-test" \
    "Test'; DROP TABLE activities; --" "" "" "2026-02-19T10:00:00Z" "{}"
count=$(episodic_db_exec "SELECT count(*) FROM activities;")
if [[ "$count" -ge 1 ]]; then
    pass "SQL injection in activity title does not drop table"
else
    fail "SQL injection in activity title does not drop table" "activities table appears dropped"
fi

# FTS injection in search
result=$(pi_activity_search "test OR 1=1" "10" "")
pass "FTS injection does not crash search"

echo ""

# ─── Summary ──────────────────────────────────────────────
echo "==================================="
echo "Results: $PASSED passed, $FAILED failed (of $TOTAL)"
echo "==================================="

[[ "$FAILED" -eq 0 ]] || exit 1
