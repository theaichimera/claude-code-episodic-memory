#!/usr/bin/env bash
# Test: User behavioral patterns — storage, injection, security
set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export EPISODIC_DB="$TEST_DIR/test.db"
export EPISODIC_LOG="$TEST_DIR/test.log"
export EPISODIC_KNOWLEDGE_DIR="$TEST_DIR/knowledge"
export EPISODIC_ARCHIVE_DIR="$TEST_DIR/archives"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/patterns.sh"

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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc: '$needle' not found in output"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc: '$needle' found in output but shouldn't be"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Test: User behavioral patterns ==="

# Initialize DB
episodic_db_init "$EPISODIC_DB" >/dev/null 2>&1

# ─── Storage Tests ────────────────────────────────────────────────────

echo ""
echo "Test 1: Write and read a pattern"
pi_patterns_write "trust-but-verify" "verification" "Trust-but-Verify" \
    "User always requests independent verification" '["sess1","sess2"]' \
    "high" "1.5" "4" "2" \
    "When presenting facts, proactively include verification commands."
result=$(pi_patterns_read "trust-but-verify")
name=$(echo "$result" | jq -r '.[0].name')
assert_eq "Pattern name matches" "Trust-but-Verify" "$name"

echo ""
echo "Test 2: Pattern category stored correctly"
cat=$(echo "$result" | jq -r '.[0].category')
assert_eq "Category is verification" "verification" "$cat"

echo ""
echo "Test 3: Confidence stored correctly"
conf=$(echo "$result" | jq -r '.[0].confidence')
assert_eq "Confidence is high" "high" "$conf"

echo ""
echo "Test 4: Weight stored correctly"
weight=$(echo "$result" | jq -r '.[0].weight')
assert_eq "Weight is 1.5" "1.5" "$weight"

echo ""
echo "Test 5: Write second pattern and list both"
pi_patterns_write "drill-down" "investigation" "Drill-Down Pattern" \
    "Broad overview then deep dive" '["sess3"]' \
    "medium" "1.0" "2" "1" \
    "Structure responses: broad overview then deep dive each anomaly."
list=$(pi_patterns_list --status active)
count=$(echo "$list" | jq 'length')
assert_eq "Two active patterns" "2" "$count"

echo ""
echo "Test 6: List filters by category"
list=$(pi_patterns_list --category verification)
count=$(echo "$list" | jq 'length')
assert_eq "One verification pattern" "1" "$count"

echo ""
echo "Test 7: Update existing pattern preserves first_seen"
first_seen=$(pi_patterns_read "trust-but-verify" | jq -r '.[0].first_seen')
sleep 1
pi_patterns_write "trust-but-verify" "verification" "Trust-but-Verify Updated" \
    "Updated description" '["sess1","sess2","sess4"]' \
    "high" "1.75" "5" "3" \
    "Updated instruction."
new_first_seen=$(pi_patterns_read "trust-but-verify" | jq -r '.[0].first_seen')
assert_eq "First seen preserved on update" "$first_seen" "$new_first_seen"

echo ""
echo "Test 8: Add evidence for a pattern"
pi_patterns_add_evidence "trust-but-verify" "sess1" "project-a" "User asked for verification"
evidence=$(episodic_db_query_json "SELECT * FROM pattern_evidence WHERE pattern_id='trust-but-verify';")
ev_count=$(echo "$evidence" | jq 'length')
assert_eq "One evidence entry" "1" "$ev_count"

echo ""
echo "Test 9: Retire a pattern"
pi_patterns_retire "drill-down"
status=$(pi_patterns_read "drill-down" | jq -r '.[0].status')
assert_eq "Pattern retired" "retired" "$status"

echo ""
echo "Test 10: Retired patterns excluded from active list"
list=$(pi_patterns_list --status active)
count=$(echo "$list" | jq 'length')
assert_eq "Only one active pattern" "1" "$count"

echo ""
echo "Test 11: Dormancy enforcement"
# Set a pattern's last_reinforced to 200 days ago
sqlite3 "$EPISODIC_DB" "UPDATE user_patterns SET status='active', last_reinforced=datetime('now','-200 days') WHERE id='drill-down';"
pi_patterns_enforce_dormancy
status=$(pi_patterns_read "drill-down" | jq -r '.[0].status')
assert_eq "Pattern made dormant" "dormant" "$status"

echo ""
echo "Test 12: Confidence calculation"
conf=$(pi_patterns_confidence 1 1)
assert_eq "1 session 1 project = low" "low" "$conf"
conf=$(pi_patterns_confidence 2 1)
assert_eq "2 sessions 1 project = medium" "medium" "$conf"
conf=$(pi_patterns_confidence 4 1)
assert_eq "4 sessions 1 project = high" "high" "$conf"
conf=$(pi_patterns_confidence 1 2)
assert_eq "1 session 2 projects = high" "high" "$conf"

echo ""
echo "Test 13: Weight boost with cap"
pi_patterns_write "test-boost" "methodology" "Test Boost" \
    "Testing weight boost" '[]' "low" "1.0" "1" "1" "Test instruction"
pi_patterns_boost "test-boost" 5
weight=$(pi_patterns_read "test-boost" | jq -r '.[0].weight')
assert_eq "Weight boosted to cap 2.0" "2.0" "$weight"

# ─── Context Injection Tests ──────────────────────────────────────────

echo ""
echo "Test 14: Context injection includes active patterns"
# Ensure trust-but-verify is active
context=$(pi_patterns_generate_context)
assert_contains "Context has heading" "User Behavioral Patterns" "$context"
assert_contains "Context has pattern name" "Trust-but-Verify" "$context"

echo ""
echo "Test 15: Context injection excludes retired/dormant patterns"
assert_not_contains "Drill-Down excluded (dormant)" "Drill-Down Pattern" "$context"

echo ""
echo "Test 16: Pattern extraction log works"
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
episodic_db_exec "INSERT INTO pattern_extraction_log (extracted_at, session_count, patterns_created, patterns_updated, patterns_retired, model) VALUES ('$now', 10, 3, 1, 0, 'test-model');"
log_count=$(episodic_db_exec "SELECT count(*) FROM pattern_extraction_log;")
assert_eq "Extraction log entry" "1" "$log_count"

# ─── Security Tests ───────────────────────────────────────────────────

echo ""
echo "Test 17: SQL injection in pattern ID"
pi_patterns_write "normal-id" "verification" "Normal" "Desc" '[]' "low" "1.0" "1" "1" "Instruction"
# Attempt SQL injection via pattern ID
result=$(pi_patterns_read "'; DROP TABLE user_patterns; --" 2>/dev/null || echo "[]")
# Table should still exist
count=$(episodic_db_exec "SELECT count(*) FROM user_patterns;" 2>/dev/null)
if [[ "$count" -gt 0 ]]; then
    echo "  ✓ SQL injection in ID prevented (table intact)"
    PASS=$((PASS + 1))
else
    echo "  ✗ SQL injection succeeded — table dropped!"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Test 18: Path traversal in pattern ID"
pi_patterns_write "../../../etc/passwd" "verification" "Traversal Test" "Desc" '[]' "low" "1.0" "1" "1" "Test"
# Check that the sanitized ID was stored, not the traversal attempt
stored_id=$(episodic_db_exec "SELECT id FROM user_patterns WHERE name='Traversal Test';")
assert_not_contains "No path separators in stored ID" "/" "$stored_id"
assert_not_contains "No parent dir refs in stored ID" ".." "$stored_id"

echo ""
echo "Test 19: Invalid category rejected"
result=$(pi_patterns_write "bad-cat" "malicious" "Bad Category" "Desc" '[]' "low" "1.0" "1" "1" "Test" 2>&1 || true)
count=$(episodic_db_exec "SELECT count(*) FROM user_patterns WHERE id='bad-cat';")
assert_eq "Invalid category rejected" "0" "$count"

echo ""
echo "Test 20: Symlink protection for knowledge repo writes"
mkdir -p "$TEST_DIR/knowledge/_user/patterns/verification"
# Create a symlink target
echo "sensitive" > "$TEST_DIR/sensitive.txt"
ln -sf "$TEST_DIR/sensitive.txt" "$TEST_DIR/knowledge/_user/patterns/verification/evil-link.md"
# Try to write to it
result=$(pi_patterns_write_to_repo "evil-link" "verification" "Evil" "Desc" "Instruction" "low" "1.0" 2>&1 || true)
# Verify the sensitive file was not overwritten
content=$(cat "$TEST_DIR/sensitive.txt")
assert_eq "Symlink not followed" "sensitive" "$content"

echo ""
echo "Test 21: Weight cap enforcement"
pi_patterns_write "weight-test" "methodology" "Weight Test" "Desc" '[]' "low" "999.9" "1" "1" "Test"
weight=$(pi_patterns_read "weight-test" | jq -r '.[0].weight')
assert_eq "Weight capped at 2.0" "2.0" "$weight"

echo ""
echo "Test 22: Stats function runs without error"
stats_output=$(pi_patterns_stats 2>&1)
assert_contains "Stats shows total" "Total patterns" "$stats_output"
assert_contains "Stats shows active" "Active" "$stats_output"

echo ""
echo "═══════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
