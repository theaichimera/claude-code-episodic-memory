#!/usr/bin/env bash
# Test: Git lockfile mechanism for knowledge repo operations
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
# Create initial commit so push works
printf '{"version":1}\n' > "$EPISODIC_KNOWLEDGE_DIR/.episodic-config.json"
git -C "$EPISODIC_KNOWLEDGE_DIR" add -A >/dev/null 2>&1
git -C "$EPISODIC_KNOWLEDGE_DIR" commit -m "init" >/dev/null 2>&1
git -C "$EPISODIC_KNOWLEDGE_DIR" push >/dev/null 2>&1

echo "=== Test: Git lockfile ==="

# Test 1: Lock acquisition succeeds
echo ""
echo "Test 1: Lock acquisition"
episodic_knowledge_lock
assert_eq "Lock dir exists" "true" "$(test -d "$EPISODIC_KNOWLEDGE_LOCK" && echo true || echo false)"
assert_eq "PID file contains our PID" "$$" "$(cat "$EPISODIC_KNOWLEDGE_LOCK/pid")"
episodic_knowledge_unlock
assert_eq "Lock dir removed after unlock" "false" "$(test -d "$EPISODIC_KNOWLEDGE_LOCK" && echo true || echo false)"

# Test 2: Stale lock is broken when holder is dead
echo ""
echo "Test 2: Stale lock detection"
mkdir -p "$EPISODIC_KNOWLEDGE_LOCK"
echo "99999999" > "$EPISODIC_KNOWLEDGE_LOCK/pid"  # non-existent PID
episodic_knowledge_lock
assert_eq "Stale lock broken, new lock acquired" "$$" "$(cat "$EPISODIC_KNOWLEDGE_LOCK/pid")"
episodic_knowledge_unlock

# Test 3: Lock times out on active holder
echo ""
echo "Test 3: Lock timeout"
mkdir -p "$EPISODIC_KNOWLEDGE_LOCK"
echo "$$" > "$EPISODIC_KNOWLEDGE_LOCK/pid"  # our own PID (still running)
export EPISODIC_LOCK_TIMEOUT=1
if episodic_knowledge_lock 2>/dev/null; then
    echo "  ✗ Should have timed out"
    FAIL=$((FAIL + 1))
else
    echo "  ✓ Lock correctly timed out"
    PASS=$((PASS + 1))
fi
rm -rf "$EPISODIC_KNOWLEDGE_LOCK"
export EPISODIC_LOCK_TIMEOUT=3

# Test 4: Push acquires and releases lock
echo ""
echo "Test 4: Push uses lock"
mkdir -p "$EPISODIC_KNOWLEDGE_DIR/testproj/skills"
echo "test content" > "$EPISODIC_KNOWLEDGE_DIR/testproj/skills/test.md"
episodic_knowledge_push "test commit" >/dev/null 2>&1
assert_eq "Lock released after push" "false" "$(test -d "$EPISODIC_KNOWLEDGE_LOCK" && echo true || echo false)"

# Test 5: Pull acquires and releases lock
echo ""
echo "Test 5: Pull uses lock"
episodic_knowledge_pull >/dev/null 2>&1
assert_eq "Lock released after pull" "false" "$(test -d "$EPISODIC_KNOWLEDGE_LOCK" && echo true || echo false)"

# Test 6: Lock is released even on error (trap RETURN)
echo ""
echo "Test 6: Lock released on error path"
# Create a situation where push will fail (corrupt remote temporarily)
mv "$TEST_DIR/remote.git" "$TEST_DIR/remote.git.bak"
echo "new stuff" > "$EPISODIC_KNOWLEDGE_DIR/testproj/skills/test2.md"
episodic_knowledge_push "will fail" 2>/dev/null || true
assert_eq "Lock released after failed push" "false" "$(test -d "$EPISODIC_KNOWLEDGE_LOCK" && echo true || echo false)"
mv "$TEST_DIR/remote.git.bak" "$TEST_DIR/remote.git"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
