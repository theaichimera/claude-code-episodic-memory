#!/usr/bin/env bash
# test-content-hash.sh: Verify content hashing works cross-platform
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export EPISODIC_DB="/tmp/episodic-test-$$.db"
export EPISODIC_LOG="/tmp/episodic-test-$$.log"

source "$SCRIPT_DIR/../lib/index.sh"

TMPFILE="/tmp/episodic-hash-test-$$"
cleanup() { rm -f "$TMPFILE" "$EPISODIC_DB" "$EPISODIC_LOG"; }
trap cleanup EXIT

echo "=== test-content-hash ==="

# Test 1: Hash is a valid 64-char hex string
echo -n "  1. Hash format... "
echo "hello world" > "$TMPFILE"
hash=$(episodic_index_content_hash "$TMPFILE")
if [[ ${#hash} -eq 64 ]] && [[ "$hash" =~ ^[0-9a-f]+$ ]]; then
    echo "PASS ($hash)"
else
    echo "FAIL: invalid hash format: '$hash'"
    exit 1
fi

# Test 2: Same content produces same hash
echo -n "  2. Deterministic... "
hash2=$(episodic_index_content_hash "$TMPFILE")
if [[ "$hash" == "$hash2" ]]; then
    echo "PASS"
else
    echo "FAIL: hashes differ for same content"
    exit 1
fi

# Test 3: Different content produces different hash
echo -n "  3. Different content, different hash... "
echo "different content" > "$TMPFILE"
hash3=$(episodic_index_content_hash "$TMPFILE")
if [[ "$hash" != "$hash3" ]]; then
    echo "PASS"
else
    echo "FAIL: hashes should differ"
    exit 1
fi

echo "=== test-content-hash: ALL PASS ==="
