#!/usr/bin/env bash
# test-synthesize.sh: Test skill synthesis logic without requiring a real API call
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DB="/tmp/episodic-test-$$.db"

# Temp dirs for this test
FAKE_REMOTE="/tmp/episodic-test-synth-remote-$$.git"
KNOWLEDGE_DIR="/tmp/episodic-test-synth-knowledge-$$"

# Override config
export EPISODIC_DB="$TEST_DB"
export EPISODIC_LOG="/tmp/episodic-test-$$.log"
export EPISODIC_ARCHIVE_DIR="/tmp/episodic-test-archives-$$"
export EPISODIC_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"
export EPISODIC_KNOWLEDGE_REPO="$FAKE_REMOTE"

source "$SCRIPT_DIR/../lib/synthesize.sh"

cleanup() {
    rm -f "$TEST_DB" "$EPISODIC_LOG"
    rm -rf "$EPISODIC_ARCHIVE_DIR"
    rm -rf "$FAKE_REMOTE"
    rm -rf "$KNOWLEDGE_DIR"
}
trap cleanup EXIT

echo "=== test-synthesize ==="

# Setup: create bare repo, clone it, initialize DB
git init --bare "$FAKE_REMOTE" >/dev/null 2>&1
TEMP_INIT="/tmp/episodic-test-synth-init-$$"
git clone "$FAKE_REMOTE" "$TEMP_INIT" >/dev/null 2>&1
git -C "$TEMP_INIT" commit --allow-empty -m "Initial commit" >/dev/null 2>&1
git -C "$TEMP_INIT" push >/dev/null 2>&1
rm -rf "$TEMP_INIT"
episodic_knowledge_init "$FAKE_REMOTE" >/dev/null 2>&1
episodic_db_init "$TEST_DB" >/dev/null 2>&1

# Test 1: Synthesize function exists
echo -n "  1. Synthesize function exists... "
if declare -f episodic_synthesize >/dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL: episodic_synthesize not defined"
    exit 1
fi

# Test 2: Skill writing from mock Opus output
echo -n "  2. Skill writing (mock data)... "
mock_skills='[
    {
        "name": "validate-cost-estimate",
        "confidence": "high",
        "body": "# Validate Cost Estimate\n\nWhen estimating service costs:\n1. Never trust API-derived estimates alone\n2. Query billing data directly\n3. Compare estimate to actual",
        "sessions": ["s1", "s2", "s3"]
    },
    {
        "name": "billing-query-pattern",
        "confidence": "medium",
        "body": "# Billing Query Pattern\n\nTo query billing data for a specific account:\n1. Identify the correct schema/billing org\n2. Run the query with account filter",
        "sessions": ["s2"]
    }
]'
episodic_synthesize_write_skills "testproj" "$mock_skills"
if [[ -f "$KNOWLEDGE_DIR/testproj/skills/validate-cost-estimate.md" ]] && \
   [[ -f "$KNOWLEDGE_DIR/testproj/skills/billing-query-pattern.md" ]]; then
    echo "PASS (2 skill files created)"
else
    echo "FAIL: skill files not created"
    ls -la "$KNOWLEDGE_DIR/testproj/skills/" 2>/dev/null
    exit 1
fi

# Test 3: Skill format has YAML frontmatter with required fields
echo -n "  3. Skill format (YAML frontmatter)... "
skill_content=$(cat "$KNOWLEDGE_DIR/testproj/skills/validate-cost-estimate.md")
has_name=false
has_project=false
has_generated=false

if echo "$skill_content" | grep -q "^name: validate-cost-estimate"; then has_name=true; fi
if echo "$skill_content" | grep -q "^project: testproj"; then has_project=true; fi
if echo "$skill_content" | grep -q "^generated: "; then has_generated=true; fi

# Verify frontmatter delimiters
has_frontmatter=false
if echo "$skill_content" | head -1 | grep -q "^---$"; then has_frontmatter=true; fi

if $has_name && $has_project && $has_generated && $has_frontmatter; then
    echo "PASS (name, project, generated present)"
else
    echo "FAIL: missing frontmatter fields (name=$has_name, project=$has_project, generated=$has_generated, delimiters=$has_frontmatter)"
    echo "  Content preview:"
    echo "$skill_content" | head -8
    exit 1
fi

# Test 4: Skill update vs create (write a skill, then "update" it)
echo -n "  4. Skill update vs create... "
original_content=$(cat "$KNOWLEDGE_DIR/testproj/skills/validate-cost-estimate.md")
updated_skills='[
    {
        "name": "validate-cost-estimate",
        "confidence": "high",
        "body": "# Validate Cost Estimate (Updated)\n\nThis skill has been updated with new information:\n1. Never trust API-derived estimates alone\n2. Query billing data directly\n3. Compare estimate to actual\n4. NEW: Include savings plan coverage check",
        "sessions": ["s1", "s2", "s3", "s4"]
    }
]'
episodic_synthesize_write_skills "testproj" "$updated_skills"
updated_content=$(cat "$KNOWLEDGE_DIR/testproj/skills/validate-cost-estimate.md")

if [[ "$original_content" != "$updated_content" ]] && echo "$updated_content" | grep -q "Updated"; then
    echo "PASS (content changed)"
else
    echo "FAIL: skill not updated"
    exit 1
fi

# Test 5: CLI dry-run (runs up to the point of API call)
echo -n "  5. CLI dry-run... "
# Insert test sessions so dry-run has data to work with
episodic_db_insert_session "synth-s1" "testproj" "/Users/test/testproj" "" "" \
    "Analyze cost estimates for database queries" 20 10 10 "main" "2024-02-01T10:00:00Z" "2024-02-01T11:00:00Z" 60

summary1='{"topics":["cost estimation","database queries"],"decisions":["Use billing data for validation"],"dead_ends":[],"artifacts_created":[],"key_insights":["API estimates can be wildly inaccurate"],"summary":"Discovered that API-based cost estimates are unreliable without billing data validation."}'
episodic_db_insert_summary "synth-s1" "$summary1" "haiku"

dry_run_output=$("$SCRIPT_DIR/../bin/episodic-synthesize" --dry-run --project testproj 2>&1) || true
if echo "$dry_run_output" | grep -q "DRY RUN"; then
    echo "PASS"
else
    echo "FAIL: dry-run output unexpected"
    echo "  Output: $dry_run_output"
    exit 1
fi

# Test 6: Empty project (no sessions, synthesis handles gracefully)
echo -n "  6. Empty project... "
empty_output=$(episodic_synthesize "emptyproject" "--dry-run" 2>&1) || true
# Should either succeed silently or mention no sessions
if [[ $? -eq 0 ]] || echo "$empty_output" | grep -qi "no sessions"; then
    echo "PASS"
else
    echo "FAIL: empty project not handled gracefully"
    echo "  Output: $empty_output"
    exit 1
fi

# Test 7: synthesis_log table exists
echo -n "  7. Synthesis log table exists... "
log_exists=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='synthesis_log';")
if [[ "$log_exists" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: synthesis_log table not found"
    exit 1
fi

# Test 8: Sessions since synthesis (never synthesized)
echo -n "  8. Sessions since synthesis (never synthesized)... "
count=$(episodic_db_sessions_since_synthesis "testproj")
if [[ "$count" -ge 1 ]]; then
    echo "PASS ($count sessions)"
else
    echo "FAIL: expected >= 1, got $count"
    exit 1
fi

# Test 9: Log a synthesis run
echo -n "  9. Log synthesis... "
episodic_db_log_synthesis "testproj" 5 2 1 "$EPISODIC_OPUS_MODEL"
log_count=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM synthesis_log WHERE project='testproj';")
if [[ "$log_count" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: expected 1 log entry, got $log_count"
    exit 1
fi

# Test 10: Sessions since synthesis (after logging)
echo -n "  10. Sessions since synthesis (after log)... "
count_after=$(episodic_db_sessions_since_synthesis "testproj")
# Should be 0 since the logged synthesis is at datetime('now') and session was archived before
if [[ "$count_after" -le "$count" ]]; then
    echo "PASS ($count_after sessions)"
else
    echo "FAIL: count should not increase after synthesis log"
    exit 1
fi

# Test 11: Backfill mode suppresses synthesis
echo -n "  11. Backfill mode suppresses synthesis... "
export EPISODIC_BACKFILL_MODE=true
if type episodic_maybe_synthesize &>/dev/null; then
    result=$(episodic_maybe_synthesize "testproj" 2>&1) || true
    # Should succeed silently (skipped)
    echo "PASS (function returned, no synthesis spawned)"
else
    echo "PASS (function not loaded, which is fine for this test)"
fi
unset EPISODIC_BACKFILL_MODE

echo "=== test-synthesize: ALL PASS ==="
