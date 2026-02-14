#!/usr/bin/env bash
# Test: Git rebase conflict markers are never committed
set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export EPISODIC_ROOT="$TEST_DIR"
export EPISODIC_DATA_DIR="$TEST_DIR"
export EPISODIC_DB="$TEST_DIR/test.db"
export EPISODIC_LOG="$TEST_DIR/test.log"
export EPISODIC_KNOWLEDGE_DIR="$TEST_DIR/knowledge"
export EPISODIC_KNOWLEDGE_REPO="file://$TEST_DIR/remote.git"
export EPISODIC_LOCK_TIMEOUT=3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/knowledge.sh"

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

# Set up a bare remote and clone it
git init --bare "$TEST_DIR/remote.git" >/dev/null 2>&1
git clone "$EPISODIC_KNOWLEDGE_REPO" "$EPISODIC_KNOWLEDGE_DIR" >/dev/null 2>&1
printf '{"version":1}\n' > "$EPISODIC_KNOWLEDGE_DIR/.episodic-config.json"
git -C "$EPISODIC_KNOWLEDGE_DIR" add -A >/dev/null 2>&1
git -C "$EPISODIC_KNOWLEDGE_DIR" commit -m "init" >/dev/null 2>&1
git -C "$EPISODIC_KNOWLEDGE_DIR" push >/dev/null 2>&1

echo "=== Test: Git conflict safety ==="

# Test 1: Recover from in-progress rebase
echo ""
echo "Test 1: Recover from in-progress rebase state"
# Simulate a stuck rebase by creating the marker directory
mkdir -p "$EPISODIC_KNOWLEDGE_DIR/.git/rebase-merge"
echo "1" > "$EPISODIC_KNOWLEDGE_DIR/.git/rebase-merge/msgnum"
episodic_knowledge_recover_repo
has_rebase=$(test -d "$EPISODIC_KNOWLEDGE_DIR/.git/rebase-merge" && echo "yes" || echo "no")
assert_eq "Rebase state cleaned up" "no" "$has_rebase"

# Test 2: Conflict markers detected and blocked
echo ""
echo "Test 2: Conflict markers detected"
echo "normal content" > "$EPISODIC_KNOWLEDGE_DIR/test-file.md"
git -C "$EPISODIC_KNOWLEDGE_DIR" add -A >/dev/null 2>&1
git -C "$EPISODIC_KNOWLEDGE_DIR" commit -m "add test file" >/dev/null 2>&1
git -C "$EPISODIC_KNOWLEDGE_DIR" push >/dev/null 2>&1

# Create conflict markers in a tracked file (simulate a failed merge)
cat > "$EPISODIC_KNOWLEDGE_DIR/test-file.md" <<'CONFLICT'
<<<<<<< HEAD
our version
=======
their version
>>>>>>> abc123
CONFLICT

# The recover function should detect and clean up
if episodic_knowledge_recover_repo 2>/dev/null; then
    echo "  ✗ Should have returned error for conflict markers"
    FAIL=$((FAIL + 1))
else
    echo "  ✓ Correctly detected conflict markers"
    PASS=$((PASS + 1))
fi

# Verify the file was reset
content=$(cat "$EPISODIC_KNOWLEDGE_DIR/test-file.md")
assert_eq "Conflict markers cleaned up" "normal content" "$content"

# Test 3: Sync both mode doesn't push conflict markers
echo ""
echo "Test 3: Sync 'both' mode blocks conflict marker commits"

# Create a second clone to create a real conflict
CLONE2="$TEST_DIR/knowledge2"
git clone "$EPISODIC_KNOWLEDGE_REPO" "$CLONE2" >/dev/null 2>&1

# Modify same file in both clones
echo "version A" > "$CLONE2/test-file.md"
git -C "$CLONE2" add -A >/dev/null 2>&1
git -C "$CLONE2" commit -m "change A" >/dev/null 2>&1
git -C "$CLONE2" push >/dev/null 2>&1

echo "version B" > "$EPISODIC_KNOWLEDGE_DIR/test-file.md"
git -C "$EPISODIC_KNOWLEDGE_DIR" add -A >/dev/null 2>&1
git -C "$EPISODIC_KNOWLEDGE_DIR" commit -m "change B" >/dev/null 2>&1

# Sync should handle the conflict gracefully
episodic_knowledge_sync both 2>/dev/null || true

# Verify no conflict markers were committed
last_commit_content=$(git -C "$EPISODIC_KNOWLEDGE_DIR" show HEAD:test-file.md 2>/dev/null || echo "")
has_markers=$(echo "$last_commit_content" | grep -c '<<<<<<' || true)
assert_eq "No conflict markers in last commit" "0" "$has_markers"

# Test 4: Recovery function cleans up stuck rebase-apply dir
echo ""
echo "Test 4: Recovery handles rebase-apply dir"
mkdir -p "$EPISODIC_KNOWLEDGE_DIR/.git/rebase-apply"
episodic_knowledge_recover_repo
has_rebase=$(test -d "$EPISODIC_KNOWLEDGE_DIR/.git/rebase-apply" && echo "yes" || echo "no")
assert_eq "rebase-apply dir cleaned up" "no" "$has_rebase"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
