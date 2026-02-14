#!/usr/bin/env bash
# test-config-defaults.sh: Verify config defaults are consistent after sourcing all modules
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export EPISODIC_DB="/tmp/episodic-test-$$.db"
export EPISODIC_LOG="/tmp/episodic-test-$$.log"

# Unset any env overrides to test pure defaults
unset EPISODIC_OPUS_MODEL EPISODIC_SUMMARY_MODEL EPISODIC_SYNTHESIZE_EVERY 2>/dev/null || true

# Source config (the single source of truth) then synthesize (which used to re-declare)
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/synthesize.sh"

cleanup() { rm -f "$EPISODIC_DB" "$EPISODIC_LOG"; }
trap cleanup EXIT

echo "=== test-config-defaults ==="

# Test 1: EPISODIC_OPUS_MODEL should be opus 4.6
echo -n "  1. EPISODIC_OPUS_MODEL default... "
if [[ "$EPISODIC_OPUS_MODEL" == "claude-opus-4-6" ]]; then
    echo "PASS ($EPISODIC_OPUS_MODEL)"
else
    echo "FAIL: expected claude-opus-4-6, got $EPISODIC_OPUS_MODEL"
    exit 1
fi

# Test 2: EPISODIC_SUMMARY_MODEL should be haiku 4.5
echo -n "  2. EPISODIC_SUMMARY_MODEL default... "
if [[ "$EPISODIC_SUMMARY_MODEL" == "claude-haiku-4-5-20251001" ]]; then
    echo "PASS ($EPISODIC_SUMMARY_MODEL)"
else
    echo "FAIL: expected claude-haiku-4-5-20251001, got $EPISODIC_SUMMARY_MODEL"
    exit 1
fi

# Test 3: EPISODIC_SYNTHESIZE_EVERY should be 2
echo -n "  3. EPISODIC_SYNTHESIZE_EVERY default... "
if [[ "$EPISODIC_SYNTHESIZE_EVERY" == "2" ]]; then
    echo "PASS ($EPISODIC_SYNTHESIZE_EVERY)"
else
    echo "FAIL: expected 2, got $EPISODIC_SYNTHESIZE_EVERY"
    exit 1
fi

# Test 4: Env override still works
echo -n "  4. Env override takes precedence... "
(
    export EPISODIC_OPUS_MODEL="custom-model"
    source "$SCRIPT_DIR/../lib/config.sh"
    if [[ "$EPISODIC_OPUS_MODEL" == "custom-model" ]]; then
        echo "PASS"
    else
        echo "FAIL: override not respected, got $EPISODIC_OPUS_MODEL"
        exit 1
    fi
)

echo "=== test-config-defaults: ALL PASS ==="
