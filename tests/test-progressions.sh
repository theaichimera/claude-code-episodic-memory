#!/usr/bin/env bash
# test-progressions.sh: Test progression tracking library functions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_KNOWLEDGE="/tmp/episodic-test-progressions-$$"

# Override config
export EPISODIC_DB="/tmp/episodic-test-progressions-$$.db"
export EPISODIC_LOG="/tmp/episodic-test-progressions-$$.log"
export EPISODIC_KNOWLEDGE_DIR="$TEST_KNOWLEDGE"

source "$SCRIPT_DIR/../lib/progression.sh"

cleanup() {
    rm -f "$EPISODIC_DB" "$EPISODIC_LOG"
    rm -rf "$TEST_KNOWLEDGE"
}
trap cleanup EXIT

mkdir -p "$TEST_KNOWLEDGE"

echo "=== test-progressions ==="

# Test 1: Create a progression
echo -n "  1. Create progression... "
dir=$(pi_progression_create "testproject" "ECS Task Placement")
if [[ -d "$dir" ]] && [[ -f "$dir/progression.yaml" ]]; then
    # Verify YAML content
    topic=$(_pi_yaml_get "$dir/progression.yaml" "topic")
    status=$(_pi_yaml_get "$dir/progression.yaml" "status")
    if [[ "$topic" == "ECS Task Placement" && "$status" == "active" ]]; then
        echo "PASS"
    else
        echo "FAIL: unexpected yaml content (topic=$topic, status=$status)"
        exit 1
    fi
else
    echo "FAIL: directory or yaml not created"
    exit 1
fi

# Test 2: Create is idempotent
echo -n "  2. Create is idempotent... "
dir2=$(pi_progression_create "testproject" "ECS Task Placement")
if [[ "$dir" == "$dir2" ]]; then
    echo "PASS"
else
    echo "FAIL: different directory returned on second create"
    exit 1
fi

# Test 3: Add a baseline document
echo -n "  3. Add baseline document... "
content_file=$(mktemp)
printf '# Initial Analysis\n\nThe ECS cluster uses spread placement.\n' > "$content_file"
doc_path=$(pi_progression_add "testproject" "ECS Task Placement" 0 "Initial Analysis" "baseline" "$content_file")
rm -f "$content_file"
if [[ -f "$doc_path" ]]; then
    # Check filename format
    expected_name="00_initial-analysis.md"
    actual_name=$(basename "$doc_path")
    if [[ "$actual_name" == "$expected_name" ]]; then
        # Check content was copied
        if grep -q "spread placement" "$doc_path"; then
            echo "PASS"
        else
            echo "FAIL: content not copied correctly"
            exit 1
        fi
    else
        echo "FAIL: expected $expected_name, got $actual_name"
        exit 1
    fi
else
    echo "FAIL: document file not created"
    exit 1
fi

# Test 4: Add a deepening document
echo -n "  4. Add deepening document... "
doc_path2=$(pi_progression_add "testproject" "ECS Task Placement" 1 "Cost Analysis" "deepening")
if [[ -f "$doc_path2" ]]; then
    actual_name=$(basename "$doc_path2")
    if [[ "$actual_name" == "01_cost-analysis.md" ]]; then
        echo "PASS"
    else
        echo "FAIL: expected 01_cost-analysis.md, got $actual_name"
        exit 1
    fi
else
    echo "FAIL: document file not created"
    exit 1
fi

# Test 5: Add a correction document
echo -n "  5. Add correction document... "
correction_file=$(mktemp)
printf '# Corrected Cost\n\nActual DynamoDB cost is $3.9K, not $387K.\n' > "$correction_file"
doc_path3=$(pi_progression_add "testproject" "ECS Task Placement" 2 "CUR Validation" "correction" "$correction_file")
rm -f "$correction_file"
if [[ -f "$doc_path3" ]]; then
    echo "PASS"
else
    echo "FAIL: correction document not created"
    exit 1
fi

# Test 6: Mark correction relationship
echo -n "  6. Mark correction... "
pi_progression_mark_correction "testproject" "ECS Task Placement" 2 1
yaml_file="$dir/progression.yaml"
# Check that doc 02 has corrects: "01"
if grep -A5 'id: "02"' "$yaml_file" | grep -q 'corrects: "01"'; then
    # Check that doc 01 has superseded_by: "02"
    if grep -A6 'id: "01"' "$yaml_file" | grep -q 'superseded_by: "02"'; then
        # Check corrections list
        if grep -q "doc_02 corrects doc_01" "$yaml_file"; then
            echo "PASS"
        else
            echo "FAIL: corrections list not updated"
            cat "$yaml_file"
            exit 1
        fi
    else
        echo "FAIL: superseded_by not set on doc 01"
        cat "$yaml_file"
        exit 1
    fi
else
    echo "FAIL: corrects not set on doc 02"
    cat "$yaml_file"
    exit 1
fi

# Test 7: List progressions
echo -n "  7. List progressions... "
# Create a second progression
pi_progression_create "testproject" "DynamoDB Costs" >/dev/null
listing=$(pi_progression_list "testproject")
count=$(echo "$listing" | wc -l | tr -d ' ')
if [[ "$count" == "2" ]]; then
    # Check both are listed
    if echo "$listing" | grep -q "ecs-task-placement" && echo "$listing" | grep -q "dynamodb-costs"; then
        echo "PASS ($count progressions)"
    else
        echo "FAIL: expected both progressions in listing"
        echo "  Listing: $listing"
        exit 1
    fi
else
    echo "FAIL: expected 2 progressions, got $count"
    echo "  Listing: $listing"
    exit 1
fi

# Test 8: Status display (get)
echo -n "  8. Get progression details... "
yaml_output=$(pi_progression_get "testproject" "ECS Task Placement")
if echo "$yaml_output" | grep -q "topic:" && echo "$yaml_output" | grep -q "documents:"; then
    echo "PASS"
else
    echo "FAIL: get did not return expected yaml"
    exit 1
fi

# Test 9: Conclude a progression
echo -n "  9. Conclude progression... "
pi_progression_update_status "testproject" "DynamoDB Costs" "concluded"
concluded_status=$(_pi_yaml_get "$TEST_KNOWLEDGE/testproject/progressions/dynamodb-costs/progression.yaml" "status")
if [[ "$concluded_status" == "concluded" ]]; then
    echo "PASS"
else
    echo "FAIL: status not updated to concluded (got: $concluded_status)"
    exit 1
fi

# Test 10: Park a progression
echo -n "  10. Park progression... "
# Create a third one to park
pi_progression_create "testproject" "Lambda Timeouts" >/dev/null
pi_progression_update_status "testproject" "Lambda Timeouts" "parked"
parked_status=$(_pi_yaml_get "$TEST_KNOWLEDGE/testproject/progressions/lambda-timeouts/progression.yaml" "status")
if [[ "$parked_status" == "parked" ]]; then
    echo "PASS"
else
    echo "FAIL: status not updated to parked (got: $parked_status)"
    exit 1
fi

# Test 11: Get active progressions (should only return active ones)
echo -n "  11. Get active progressions... "
active=$(pi_progression_get_active "testproject")
active_count=$(echo "$active" | grep -c "active" || true)
if [[ "$active_count" == "1" ]]; then
    if echo "$active" | grep -q "ecs-task-placement"; then
        echo "PASS (1 active)"
    else
        echo "FAIL: wrong progression returned as active"
        echo "  Active: $active"
        exit 1
    fi
else
    echo "FAIL: expected 1 active progression, got $active_count"
    echo "  Active: $active"
    exit 1
fi

# Test 12: Context generation (only active progressions)
echo -n "  12. Context generation... "
context=$(pi_progression_generate_context "testproject")
if echo "$context" | grep -q "Active Progressions"; then
    # Should include ECS (active) but not DynamoDB (concluded) or Lambda (parked)
    if echo "$context" | grep -q "ECS Task Placement"; then
        if ! echo "$context" | grep -q "DynamoDB Costs" && ! echo "$context" | grep -q "Lambda Timeouts"; then
            echo "PASS"
        else
            echo "FAIL: context includes non-active progressions"
            echo "  Context: $context"
            exit 1
        fi
    else
        echo "FAIL: context missing active progression"
        echo "  Context: $context"
        exit 1
    fi
else
    echo "FAIL: no Active Progressions header"
    echo "  Context: $context"
    exit 1
fi

# Test 13: Topic slug generation
echo -n "  13. Topic slug generation... "
slug1=$(_pi_topic_to_slug "ECS Task Placement Strategy")
slug2=$(_pi_topic_to_slug "DynamoDB Cost Analysis!!!")
slug3=$(_pi_topic_to_slug "simple")
if [[ "$slug1" == "ecs-task-placement-strategy" && "$slug2" == "dynamodb-cost-analysis" && "$slug3" == "simple" ]]; then
    echo "PASS"
else
    echo "FAIL: unexpected slugs ($slug1, $slug2, $slug3)"
    exit 1
fi

# Test 14: Invalid status rejected
echo -n "  14. Invalid status rejected... "
if pi_progression_update_status "testproject" "ECS Task Placement" "invalid" 2>/dev/null; then
    echo "FAIL: should have rejected invalid status"
    exit 1
else
    echo "PASS"
fi

# Test 15: Add document via stdin
echo -n "  15. Add document via stdin... "
doc_stdin=$(echo "# From Stdin" | pi_progression_add "testproject" "ECS Task Placement" 3 "Stdin Doc" "deepening" "-")
if [[ -f "$doc_stdin" ]] && grep -q "From Stdin" "$doc_stdin"; then
    echo "PASS"
else
    echo "FAIL: stdin document not created correctly"
    exit 1
fi

# Test 16: Document count in context
echo -n "  16. Document count in context... "
context2=$(pi_progression_generate_context "testproject")
if echo "$context2" | grep -q "4 documents"; then
    echo "PASS"
else
    echo "FAIL: expected '4 documents' in context"
    echo "  Context: $context2"
    exit 1
fi

# Test 17: Project with no progressions returns empty
echo -n "  17. Empty project returns nothing... "
empty_list=$(pi_progression_list "nonexistent-project")
if [[ -z "$empty_list" ]]; then
    echo "PASS"
else
    echo "FAIL: expected empty output for nonexistent project"
    exit 1
fi

# Test 18: Missing args rejected
echo -n "  18. Missing args rejected... "
if pi_progression_create "" "" 2>/dev/null; then
    echo "FAIL: should have rejected empty args"
    exit 1
else
    echo "PASS"
fi

echo "=== test-progressions: ALL PASS ==="
