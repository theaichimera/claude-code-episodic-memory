#!/usr/bin/env bash
# Test: Large text handling via temp files in SQL operations
set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export EPISODIC_DATA_DIR="$TEST_DIR"
export EPISODIC_DB="$TEST_DIR/test.db"
export EPISODIC_LOG="$TEST_DIR/test.log"
export EPISODIC_KNOWLEDGE_DIR="$TEST_DIR/knowledge"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/db.sh"
source "$SCRIPT_DIR/../lib/index.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc: expected '${expected:0:60}...', got '${actual:0:60}...'"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Test: Large text SQL operations ==="

episodic_db_init "$EPISODIC_DB" >/dev/null 2>&1

# Test 1: Insert and retrieve a large summary via temp file
echo ""
echo "Test 1: Large summary text round-trip"
# Create a session first
sqlite3 "$EPISODIC_DB" "INSERT INTO sessions (id, project, created_at, first_prompt) VALUES ('big1', 'testproj', datetime('now'), 'test prompt');"

# Generate a 50KB summary text
large_summary=""
for i in $(seq 1 500); do
    large_summary+="This is line $i of a very large summary text that tests the temp file SQL path. "
done
large_summary_len=${#large_summary}
echo "  (generated ${large_summary_len} chars of summary text)"

summary_json=$(jq -n --arg sum "$large_summary" '{
    topics: ["large-text-test", "temp-file-sql"],
    decisions: ["use temp files for large SQL"],
    dead_ends: [],
    artifacts_created: [],
    key_insights: ["temp files bypass bash limits"],
    summary: $sum
}')

episodic_db_insert_summary "big1" "$summary_json" "test-model"
retrieved=$(sqlite3 "$EPISODIC_DB" "SELECT length(summary) FROM summaries WHERE session_id='big1';")
assert_eq "Summary stored with correct length" "$large_summary_len" "$retrieved"

# Test 2: Large document text via index_file temp file path
echo ""
echo "Test 2: Large document indexing round-trip"
mkdir -p "$TEST_DIR/knowledge/testproj"
large_doc="$TEST_DIR/knowledge/testproj/large-doc.md"

# Generate a 80KB document
{
    echo "# Large Test Document"
    echo ""
    for i in $(seq 1 1000); do
        echo "Section $i: This is a paragraph of text in a large document that tests the temp file path for SQL insertion. It contains enough content to exceed typical heredoc limits."
    done
} > "$large_doc"

large_doc_size=$(wc -c < "$large_doc" | tr -d ' ')
echo "  (created ${large_doc_size} byte test document)"

episodic_index_file "$large_doc" "testproj"
stored_size=$(sqlite3 "$EPISODIC_DB" "SELECT length(extracted_text) FROM documents WHERE project='testproj';")
assert_eq "Document text stored (non-zero length)" "true" "$([[ "$stored_size" -gt 1000 ]] && echo true || echo false)"

# Test 3: Text with single quotes in large payload
echo ""
echo "Test 3: Large text with quotes"
sqlite3 "$EPISODIC_DB" "INSERT INTO sessions (id, project, created_at, first_prompt) VALUES ('big2', 'testproj', datetime('now'), 'another test');"

quote_text="It's a test with O'Brien's code that can't fail. "
large_quote_text=""
for i in $(seq 1 500); do
    large_quote_text+="$quote_text"
done

quote_json=$(jq -n --arg sum "$large_quote_text" '{
    topics: ["quote-test"],
    decisions: [],
    dead_ends: [],
    artifacts_created: [],
    key_insights: [],
    summary: $sum
}')

episodic_db_insert_summary "big2" "$quote_json" "test-model"
retrieved_len=$(sqlite3 "$EPISODIC_DB" "SELECT length(summary) FROM summaries WHERE session_id='big2';")
expected_len=${#large_quote_text}
assert_eq "Quoted text stored with correct length" "$expected_len" "$retrieved_len"

# Test 4: Temp files are cleaned up
echo ""
echo "Test 4: No temp files leaked"
# Count temp files before and after an operation
before=$(ls /tmp/tmp.* 2>/dev/null | wc -l || echo 0)
sqlite3 "$EPISODIC_DB" "INSERT INTO sessions (id, project, created_at, first_prompt) VALUES ('big3', 'testproj', datetime('now'), 'temp test');"
small_json='{"topics":["t"],"decisions":[],"dead_ends":[],"artifacts_created":[],"key_insights":[],"summary":"small"}'
episodic_db_insert_summary "big3" "$small_json" "test-model"
after=$(ls /tmp/tmp.* 2>/dev/null | wc -l || echo 0)
# Should not have accumulated temp files (trap RETURN cleans them)
assert_eq "No temp file leak" "true" "$([[ "$after" -le "$((before + 0))" ]] && echo true || echo false)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
