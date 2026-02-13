#!/usr/bin/env bash
# test-knowledge.sh: Test knowledge repo operations using a local bare git repo as fake remote
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DB="/tmp/episodic-test-$$.db"

# Temp dirs for this test
FAKE_REMOTE="/tmp/episodic-test-remote-$$.git"
KNOWLEDGE_DIR="/tmp/episodic-test-knowledge-$$"
SECOND_CLONE="/tmp/episodic-test-knowledge-clone2-$$"

# Override config
export EPISODIC_DB="$TEST_DB"
export EPISODIC_LOG="/tmp/episodic-test-$$.log"
export EPISODIC_ARCHIVE_DIR="/tmp/episodic-test-archives-$$"
export EPISODIC_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"
export EPISODIC_KNOWLEDGE_REPO="$FAKE_REMOTE"

source "$SCRIPT_DIR/../lib/knowledge.sh"

cleanup() {
    rm -f "$TEST_DB" "$EPISODIC_LOG"
    rm -rf "$EPISODIC_ARCHIVE_DIR"
    rm -rf "$FAKE_REMOTE"
    rm -rf "$KNOWLEDGE_DIR"
    rm -rf "$SECOND_CLONE"
}
trap cleanup EXIT

echo "=== test-knowledge ==="

# Setup: create a bare repo as fake remote
echo -n "  Setting up fake remote... "
git init --bare "$FAKE_REMOTE" >/dev/null 2>&1
# Create an initial commit so the bare repo has a default branch
TEMP_INIT="/tmp/episodic-test-init-$$"
git clone "$FAKE_REMOTE" "$TEMP_INIT" >/dev/null 2>&1
git -C "$TEMP_INIT" commit --allow-empty -m "Initial commit" >/dev/null 2>&1
git -C "$TEMP_INIT" push >/dev/null 2>&1
rm -rf "$TEMP_INIT"
echo "PASS"

# Test 1: Init knowledge repo (clone from fake remote)
echo -n "  1. Init knowledge repo... "
episodic_knowledge_init "$FAKE_REMOTE" >/dev/null 2>&1
if [[ -d "$KNOWLEDGE_DIR/.git" ]]; then
    echo "PASS"
else
    echo "FAIL: knowledge dir not created or not a git repo"
    exit 1
fi

# Test 2: Ensure project dir creates project/skills/ structure
echo -n "  2. Ensure project dir... "
project_dir=$(episodic_knowledge_ensure_project "testproject")
if [[ -d "$KNOWLEDGE_DIR/testproject/skills" ]]; then
    echo "PASS"
else
    echo "FAIL: testproject/skills/ not created"
    exit 1
fi

# Test 3: Write a skill
echo -n "  3. Write skill... "
skill_content="---
name: test-skill
project: testproject
generated: 2026-02-13
sessions: [s1, s2]
confidence: high
---

# Test Skill

This is a test skill with steps:
1. Do thing one
2. Do thing two"

episodic_knowledge_write_skill "testproject" "test-skill" "$skill_content"
if [[ -f "$KNOWLEDGE_DIR/testproject/skills/test-skill.md" ]]; then
    echo "PASS"
else
    echo "FAIL: skill file not created"
    exit 1
fi

# Test 4: Read skill back and verify content
echo -n "  4. Read skill... "
read_content=$(episodic_knowledge_read_skill "testproject" "test-skill")
if echo "$read_content" | grep -q "test-skill" && echo "$read_content" | grep -q "Do thing one"; then
    echo "PASS"
else
    echo "FAIL: read content doesn't match"
    exit 1
fi

# Test 5: List skills (write a second skill, verify count)
echo -n "  5. List skills... "
episodic_knowledge_write_skill "testproject" "second-skill" "---
name: second-skill
project: testproject
generated: 2026-02-13
sessions: [s3]
confidence: medium
---

# Second Skill

Another skill."

skill_list=$(episodic_knowledge_list_skills "testproject")
skill_count=$(echo "$skill_list" | wc -l | tr -d ' ')
if [[ "$skill_count" == "2" ]]; then
    echo "PASS ($skill_count skills)"
else
    echo "FAIL: expected 2 skills, got $skill_count"
    echo "  List: $skill_list"
    exit 1
fi

# Test 6: Write context
echo -n "  6. Write context... "
context_content="# testproject

This project is for testing the knowledge repo.

## Recent Activity
- Set up FTS5 search
- Analyzed API performance"

episodic_knowledge_write_context "testproject" "$context_content"
if [[ -f "$KNOWLEDGE_DIR/testproject/context.md" ]]; then
    read_context=$(episodic_knowledge_read_context "testproject")
    if echo "$read_context" | grep -q "API performance"; then
        echo "PASS"
    else
        echo "FAIL: context content doesn't match"
        exit 1
    fi
else
    echo "FAIL: context.md not created"
    exit 1
fi

# Test 7: Push changes (commit and push to fake remote)
echo -n "  7. Push changes... "
episodic_knowledge_push "Test commit from test-knowledge.sh" >/dev/null 2>&1
# Verify remote has the commit by checking the log in the bare repo
remote_log=$(git -C "$FAKE_REMOTE" log --oneline 2>/dev/null)
if echo "$remote_log" | grep -q "Test commit"; then
    echo "PASS"
else
    echo "FAIL: push didn't reach remote"
    echo "  Remote log: $remote_log"
    exit 1
fi

# Test 8: Pull changes (make a change in a second clone, push, then pull in first)
echo -n "  8. Pull changes... "
git clone "$FAKE_REMOTE" "$SECOND_CLONE" >/dev/null 2>&1
mkdir -p "$SECOND_CLONE/testproject/skills"
printf '%s\n' "---
name: remote-skill
project: testproject
generated: 2026-02-13
sessions: [s99]
confidence: low
---

# Remote Skill

This was added from another machine." > "$SECOND_CLONE/testproject/skills/remote-skill.md"
git -C "$SECOND_CLONE" add -A >/dev/null 2>&1
git -C "$SECOND_CLONE" commit -m "Add remote-skill from second clone" >/dev/null 2>&1
git -C "$SECOND_CLONE" push >/dev/null 2>&1

# Now pull in the first clone
episodic_knowledge_pull >/dev/null 2>&1
if [[ -f "$KNOWLEDGE_DIR/testproject/skills/remote-skill.md" ]]; then
    pulled_content=$(cat "$KNOWLEDGE_DIR/testproject/skills/remote-skill.md")
    if echo "$pulled_content" | grep -q "another machine"; then
        echo "PASS"
    else
        echo "FAIL: pulled content doesn't match"
        exit 1
    fi
else
    echo "FAIL: remote-skill.md not pulled"
    exit 1
fi

# Test 9: Is configured check
echo -n "  9. Is configured check... "
if episodic_knowledge_is_configured; then
    # Also verify it returns false when misconfigured
    saved_repo="$EPISODIC_KNOWLEDGE_REPO"
    saved_dir="$EPISODIC_KNOWLEDGE_DIR"
    export EPISODIC_KNOWLEDGE_REPO=""
    if ! episodic_knowledge_is_configured; then
        export EPISODIC_KNOWLEDGE_REPO="$saved_repo"
        export EPISODIC_KNOWLEDGE_DIR="$saved_dir"
        echo "PASS"
    else
        export EPISODIC_KNOWLEDGE_REPO="$saved_repo"
        export EPISODIC_KNOWLEDGE_DIR="$saved_dir"
        echo "FAIL: should return false when EPISODIC_KNOWLEDGE_REPO is empty"
        exit 1
    fi
else
    echo "FAIL: should return true when configured"
    exit 1
fi

# Test 10: Idempotency (run init again, verify it doesn't break)
echo -n "  10. Idempotency... "
episodic_knowledge_init "$FAKE_REMOTE" >/dev/null 2>&1
# Verify all previous data is still there
if [[ -f "$KNOWLEDGE_DIR/testproject/skills/test-skill.md" ]] && \
   [[ -f "$KNOWLEDGE_DIR/testproject/skills/second-skill.md" ]] && \
   [[ -f "$KNOWLEDGE_DIR/testproject/skills/remote-skill.md" ]] && \
   [[ -f "$KNOWLEDGE_DIR/testproject/context.md" ]]; then
    echo "PASS"
else
    echo "FAIL: data lost after re-init"
    exit 1
fi

echo "=== test-knowledge: ALL PASS ==="
