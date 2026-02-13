#!/usr/bin/env bash
# test-knowledge-init-env.sh: Verify .env update works cross-platform (no macOS sed -i '')
set -euo pipefail

TMPDIR_TEST="/tmp/episodic-test-env-$$"
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

echo "=== test-knowledge-init-env ==="

mkdir -p "$TMPDIR_TEST"

# Test 1: Update existing EPISODIC_KNOWLEDGE_REPO line
echo -n "  1. Update existing .env line... "
cat > "$TMPDIR_TEST/.env" <<'ENVFILE'
EPISODIC_KNOWLEDGE_REPO="git@old.example.com:user/old.git"
OTHER_VAR="keep-this"
ENVFILE

REPO_URL="git@github.com:user/new-repo.git"
ENV_FILE="$TMPDIR_TEST/.env"

# Replicate the logic from episodic-knowledge-init
if [[ -f "$ENV_FILE" ]] && grep -q "EPISODIC_KNOWLEDGE_REPO" "$ENV_FILE" 2>/dev/null; then
    local_tmp=$(mktemp)
    sed "s|^EPISODIC_KNOWLEDGE_REPO=.*|EPISODIC_KNOWLEDGE_REPO=\"$REPO_URL\"|" "$ENV_FILE" > "$local_tmp" && mv "$local_tmp" "$ENV_FILE"
fi

if grep -q "git@github.com:user/new-repo.git" "$ENV_FILE" && grep -q 'OTHER_VAR="keep-this"' "$ENV_FILE"; then
    echo "PASS"
else
    echo "FAIL"
    cat "$ENV_FILE"
    exit 1
fi

# Test 2: Append when line doesn't exist
echo -n "  2. Append to .env when missing... "
cat > "$TMPDIR_TEST/.env2" <<'ENVFILE'
OTHER_VAR="something"
ENVFILE

ENV_FILE="$TMPDIR_TEST/.env2"
if ! grep -q "EPISODIC_KNOWLEDGE_REPO" "$ENV_FILE" 2>/dev/null; then
    echo "EPISODIC_KNOWLEDGE_REPO=\"$REPO_URL\"" >> "$ENV_FILE"
fi

if grep -q "EPISODIC_KNOWLEDGE_REPO=\"git@github.com:user/new-repo.git\"" "$ENV_FILE" && grep -q 'OTHER_VAR="something"' "$ENV_FILE"; then
    echo "PASS"
else
    echo "FAIL"
    cat "$ENV_FILE"
    exit 1
fi

echo "=== test-knowledge-init-env: ALL PASS ==="
