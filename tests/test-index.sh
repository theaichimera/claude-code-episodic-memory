#!/usr/bin/env bash
# test-index.sh: Test document indexing and search
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DB="/tmp/episodic-test-$$.db"
TEST_KNOWLEDGE="/tmp/episodic-test-knowledge-$$"

# Override config
export EPISODIC_DB="$TEST_DB"
export EPISODIC_LOG="/tmp/episodic-test-$$.log"
export EPISODIC_KNOWLEDGE_DIR="$TEST_KNOWLEDGE"

source "$SCRIPT_DIR/../lib/index.sh"

cleanup() {
    rm -f "$TEST_DB" "$EPISODIC_LOG"
    rm -rf "$TEST_KNOWLEDGE"
}
trap cleanup EXIT

echo "=== test-index ==="

# Initialize DB and document tables
episodic_db_init "$TEST_DB" >/dev/null 2>&1
episodic_db_init_documents "$TEST_DB"

# Set up test knowledge directory with a project
mkdir -p "$TEST_KNOWLEDGE/testproject"

# Test 1: Documents table created
echo -n "  1. Documents table created... "
tables=$(sqlite3 "$TEST_DB" ".tables")
if echo "$tables" | grep -q "documents"; then
    echo "PASS"
else
    echo "FAIL: documents table not found. Got: $tables"
    exit 1
fi

# Test 2: Documents FTS table created
echo -n "  2. Documents FTS table created... "
fts_exists=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='documents_fts';")
if [[ "$fts_exists" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: documents_fts table not found"
    exit 1
fi

# Test 3: Index a markdown file
echo -n "  3. Index a markdown file... "
cat > "$TEST_KNOWLEDGE/testproject/architecture-guide.md" <<'EOF'
# Architecture Guide

This document describes the system architecture for the widget platform.

## Components
- API Gateway handles all incoming requests
- Lambda functions process business logic
- DynamoDB stores session data

## Design Decisions
We chose serverless to minimize operational overhead.
EOF

episodic_index_file "$TEST_KNOWLEDGE/testproject/architecture-guide.md" "testproject" >/dev/null 2>&1
md_count=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM documents WHERE project='testproject' AND file_type='md';")
if [[ "$md_count" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: expected 1 markdown document, got $md_count"
    exit 1
fi

# Test 4: Index a Python file
echo -n "  4. Index a Python file... "
cat > "$TEST_KNOWLEDGE/testproject/data_processor.py" <<'EOF'
"""Data processor module for ETL pipeline."""

def process_batch(records):
    """Process a batch of records from the queue."""
    results = []
    for record in records:
        transformed = transform(record)
        results.append(transformed)
    return results

def transform(record):
    """Apply transformation rules to a single record."""
    return {
        "id": record["id"],
        "value": record["value"] * 2,
        "processed": True,
    }
EOF

episodic_index_file "$TEST_KNOWLEDGE/testproject/data_processor.py" "testproject" >/dev/null 2>&1
py_count=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM documents WHERE project='testproject' AND file_type='py';")
if [[ "$py_count" == "1" ]]; then
    echo "PASS"
else
    echo "FAIL: expected 1 python document, got $py_count"
    exit 1
fi

# Test 5: Search finds indexed document
echo -n "  5. Search finds indexed document... "
results=$(episodic_index_search "serverless architecture" 10)
first_title=$(echo "$results" | jq -r '.[0].title // empty')
if [[ "$first_title" == "Architecture guide" ]]; then
    echo "PASS"
else
    echo "FAIL: expected 'Architecture guide', got: $first_title"
    echo "  Results: $results"
    exit 1
fi

# Test 6: Skip unchanged file
echo -n "  6. Skip unchanged file... "
# Get the current indexed_at time
indexed_at_before=$(sqlite3 "$TEST_DB" "SELECT indexed_at FROM documents WHERE file_type='md';")
# Brief pause to ensure any re-index would get a different timestamp
sleep 1
episodic_index_file "$TEST_KNOWLEDGE/testproject/architecture-guide.md" "testproject" >/dev/null 2>&1
indexed_at_after=$(sqlite3 "$TEST_DB" "SELECT indexed_at FROM documents WHERE file_type='md';")
if [[ "$indexed_at_before" == "$indexed_at_after" ]]; then
    echo "PASS"
else
    echo "FAIL: file was re-indexed when it should have been skipped"
    exit 1
fi

# Test 7: Re-index changed file
echo -n "  7. Re-index changed file... "
sleep 1
cat >> "$TEST_KNOWLEDGE/testproject/architecture-guide.md" <<'EOF'

## New Section
Added Kubernetes orchestration for container workloads.
EOF

episodic_index_file "$TEST_KNOWLEDGE/testproject/architecture-guide.md" "testproject" >/dev/null 2>&1
new_text=$(sqlite3 "$TEST_DB" "SELECT extracted_text FROM documents WHERE file_type='md';")
if echo "$new_text" | grep -q "Kubernetes"; then
    echo "PASS"
else
    echo "FAIL: updated content not found in index"
    exit 1
fi

# Test 8: Cleanup removes missing files
echo -n "  8. Cleanup removes missing files... "
rm -f "$TEST_KNOWLEDGE/testproject/data_processor.py"
episodic_index_cleanup "testproject" >/dev/null 2>&1
py_count_after=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM documents WHERE project='testproject' AND file_type='py';")
fts_count_after=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM documents_fts WHERE doc_id LIKE '%data_processor%';")
if [[ "$py_count_after" == "0" && "$fts_count_after" == "0" ]]; then
    echo "PASS"
else
    echo "FAIL: expected 0 py docs after cleanup, got docs=$py_count_after fts=$fts_count_after"
    exit 1
fi

# Test 9: Index stats
echo -n "  9. Index stats... "
stats=$(episodic_index_stats)
total=$(echo "$stats" | jq -r '.total_documents')
has_project=$(echo "$stats" | jq -r '.by_project | length')
has_type=$(echo "$stats" | jq -r '.by_type | length')
total_size=$(echo "$stats" | jq -r '.total_size_bytes')
if [[ "$total" == "1" && "$has_project" -ge 1 && "$has_type" -ge 1 && "$total_size" -gt 0 ]]; then
    echo "PASS (total=$total, projects=$has_project, types=$has_type, size=$total_size)"
else
    echo "FAIL: unexpected stats: $stats"
    exit 1
fi

echo "=== test-index: ALL PASS ==="
