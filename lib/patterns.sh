#!/usr/bin/env bash
# project-intelligence: User behavioral pattern learning
# Extracts cross-project behavioral patterns from session transcripts and
# injects them as behavioral instructions at session start.

_EPISODIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_EPISODIC_LIB_DIR/config.sh"
source "$_EPISODIC_LIB_DIR/db.sh"
source "$_EPISODIC_LIB_DIR/extract.sh"

# Valid pattern categories (allowlist)
PI_PATTERNS_CATEGORIES="verification investigation methodology communication correction"

# ─── Storage Functions ────────────────────────────────────────────────

# Validate a category name against the allowlist.
# Usage: pi_patterns_validate_category <category>
# Returns 0 if valid, 1 if not.
pi_patterns_validate_category() {
    local cat="$1"
    local valid
    for valid in $PI_PATTERNS_CATEGORIES; do
        if [[ "$cat" == "$valid" ]]; then
            return 0
        fi
    done
    return 1
}

# Write (create or update) a pattern in the database.
# Usage: pi_patterns_write <id> <category> <name> <description> <evidence_json> <confidence> <weight> <session_count> <project_count> <behavioral_instruction>
pi_patterns_write() {
    local id="$1" category="$2" name="$3" description="$4"
    local evidence_json="$5" confidence="$6" weight="$7"
    local session_count="$8" project_count="$9" behavioral_instruction="${10}"

    # Validate category
    if ! pi_patterns_validate_category "$category"; then
        episodic_log "ERROR" "Invalid pattern category: $category"
        return 1
    fi

    # Sanitize pattern ID for filesystem safety
    id=$(episodic_sanitize_name "$id")
    if [[ -z "$id" || "$id" == "unnamed" ]]; then
        episodic_log "ERROR" "Invalid pattern ID"
        return 1
    fi

    # Validate numeric fields
    [[ "$session_count" =~ ^[0-9]+$ ]] || session_count=1
    [[ "$project_count" =~ ^[0-9]+$ ]] || project_count=1

    # Validate weight as decimal, cap at max
    if ! printf '%s' "$weight" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
        weight="1.0"
    fi
    # Cap weight at PI_PATTERNS_WEIGHT_CAP
    local cap="$PI_PATTERNS_WEIGHT_CAP"
    if awk "BEGIN { exit ($weight > $cap) ? 0 : 1 }" 2>/dev/null; then
        weight="$cap"
    fi

    # Validate confidence
    case "$confidence" in
        low|medium|high) ;;
        *) confidence="low" ;;
    esac

    # SQL-escape all text fields
    local safe_id safe_cat safe_name safe_desc safe_evidence safe_instruction
    safe_id=$(episodic_sql_escape "$id")
    safe_cat=$(episodic_sql_escape "$category")
    safe_name=$(episodic_sql_escape "$name")
    safe_desc=$(episodic_sql_escape "$description")
    safe_evidence=$(episodic_sql_escape "$evidence_json")
    safe_instruction=$(episodic_sql_escape "$behavioral_instruction")

    # Check if exists for first_seen preservation
    local db="$EPISODIC_DB"
    local exists
    exists=$(episodic_db_exec "SELECT count(*) FROM user_patterns WHERE id='$safe_id';")

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local sql_file
    sql_file=$(mktemp) || { echo "Failed to create temp file" >&2; return 1; }

    if [[ "$exists" -gt 0 ]]; then
        # Update existing pattern
        {
            printf ".timeout ${EPISODIC_BUSY_TIMEOUT}\n"
            printf "UPDATE user_patterns SET\n"
            printf "    category='%s',\n" "$safe_cat"
            printf "    name='%s',\n" "$safe_name"
            printf "    description='%s',\n" "$safe_desc"
            printf "    evidence='%s',\n" "$safe_evidence"
            printf "    confidence='%s',\n" "$confidence"
            printf "    weight=%s,\n" "$weight"
            printf "    session_count=%s,\n" "$session_count"
            printf "    project_count=%s,\n" "$project_count"
            printf "    last_seen='%s',\n" "$now"
            printf "    last_reinforced='%s',\n" "$now"
            printf "    behavioral_instruction='%s',\n" "$safe_instruction"
            printf "    status='active',\n"
            printf "    updated_at='%s'\n" "$now"
            printf "WHERE id='%s';\n" "$safe_id"
        } > "$sql_file"
    else
        # Insert new pattern
        {
            printf ".timeout ${EPISODIC_BUSY_TIMEOUT}\n"
            printf "INSERT INTO user_patterns (\n"
            printf "    id, category, name, description, evidence, confidence, weight,\n"
            printf "    session_count, project_count, first_seen, last_seen, last_reinforced,\n"
            printf "    behavioral_instruction, status, created_at, updated_at\n"
            printf ") VALUES (\n"
            printf "    '%s', '%s', '%s', '%s',\n" "$safe_id" "$safe_cat" "$safe_name" "$safe_desc"
            printf "    '%s', '%s', %s,\n" "$safe_evidence" "$confidence" "$weight"
            printf "    %s, %s, '%s', '%s', '%s',\n" "$session_count" "$project_count" "$now" "$now" "$now"
            printf "    '%s', 'active', '%s', '%s'\n" "$safe_instruction" "$now" "$now"
            printf ");\n"
        } > "$sql_file"
    fi

    sqlite3 "$db" < "$sql_file"
    rm -f "$sql_file"
    episodic_log "INFO" "Pattern written: $id (confidence=$confidence, weight=$weight)"
}

# Read a single pattern from the database.
# Usage: pi_patterns_read <id>
# Output: JSON object
pi_patterns_read() {
    local id="$1"
    local safe_id
    safe_id=$(episodic_sql_escape "$(episodic_sanitize_name "$id")")

    episodic_db_query_json "SELECT * FROM user_patterns WHERE id='$safe_id';"
}

# List patterns, optionally filtered by status and/or category.
# Usage: pi_patterns_list [--status active|dormant|retired] [--category NAME]
# Output: JSON array
pi_patterns_list() {
    local status_filter="" category_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status) status_filter="$2"; shift 2 ;;
            --category) category_filter="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local where_clause="WHERE 1=1"
    if [[ -n "$status_filter" ]]; then
        local safe_status
        safe_status=$(episodic_sql_escape "$status_filter")
        where_clause="$where_clause AND status='$safe_status'"
    fi
    if [[ -n "$category_filter" ]]; then
        if ! pi_patterns_validate_category "$category_filter"; then
            episodic_log "ERROR" "Invalid category filter: $category_filter"
            return 1
        fi
        local safe_cat
        safe_cat=$(episodic_sql_escape "$category_filter")
        where_clause="$where_clause AND category='$safe_cat'"
    fi

    episodic_db_query_json "SELECT id, category, name, confidence, weight, session_count, project_count, status, last_reinforced FROM user_patterns $where_clause ORDER BY weight DESC, last_reinforced DESC;"
}

# Add evidence for a pattern from a specific session.
# Usage: pi_patterns_add_evidence <pattern_id> <session_id> <project> <evidence_text>
pi_patterns_add_evidence() {
    local pattern_id="$1" session_id="$2" project="$3" evidence_text="$4"

    local safe_pid safe_sid safe_proj safe_text
    safe_pid=$(episodic_sql_escape "$(episodic_sanitize_name "$pattern_id")")
    safe_sid=$(episodic_sql_escape "$session_id")
    safe_proj=$(episodic_sql_escape "$project")
    safe_text=$(episodic_sql_escape "$evidence_text")

    local db="$EPISODIC_DB"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local sql_file
    sql_file=$(mktemp) || { echo "Failed to create temp file" >&2; return 1; }

    {
        printf ".timeout ${EPISODIC_BUSY_TIMEOUT}\n"
        printf "INSERT OR IGNORE INTO pattern_evidence (pattern_id, session_id, project, evidence_text, extracted_at)\n"
        printf "VALUES ('%s', '%s', '%s', '%s', '%s');\n" "$safe_pid" "$safe_sid" "$safe_proj" "$safe_text" "$now"
    } > "$sql_file"

    sqlite3 "$db" < "$sql_file"
    rm -f "$sql_file"
}

# Retire a pattern (set status to 'retired').
# Usage: pi_patterns_retire <id>
pi_patterns_retire() {
    local id="$1"
    local safe_id
    safe_id=$(episodic_sql_escape "$(episodic_sanitize_name "$id")")
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    episodic_db_exec "UPDATE user_patterns SET status='retired', updated_at='$now' WHERE id='$safe_id';"
    episodic_log "INFO" "Pattern retired: $id"
}

# Set a pattern to dormant status.
# Usage: pi_patterns_set_dormant <id>
pi_patterns_set_dormant() {
    local id="$1"
    local safe_id
    safe_id=$(episodic_sql_escape "$(episodic_sanitize_name "$id")")
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    episodic_db_exec "UPDATE user_patterns SET status='dormant', updated_at='$now' WHERE id='$safe_id';"
    episodic_log "INFO" "Pattern set dormant: $id"
}

# Boost a pattern's weight when seen in additional projects.
# +0.25 per additional project, capped at PI_PATTERNS_WEIGHT_CAP.
# Usage: pi_patterns_boost <id> <new_project_count>
pi_patterns_boost() {
    local id="$1"
    local project_count="$2"

    [[ "$project_count" =~ ^[0-9]+$ ]] || project_count=1

    local safe_id
    safe_id=$(episodic_sql_escape "$(episodic_sanitize_name "$id")")

    # Calculate new weight: base 1.0 + 0.25 per extra project
    local new_weight
    new_weight=$(awk "BEGIN { w = 1.0 + ($project_count - 1) * 0.25; cap = $PI_PATTERNS_WEIGHT_CAP; print (w > cap) ? cap : w }")

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    episodic_db_exec "UPDATE user_patterns SET weight=$new_weight, project_count=$project_count, updated_at='$now' WHERE id='$safe_id';"
    episodic_log "INFO" "Pattern boosted: $id (weight=$new_weight, projects=$project_count)"
}

# Calculate confidence from session count and project count.
# 1 session = low, 2-3 sessions = medium, 4+ sessions OR 2+ projects = high.
# Usage: pi_patterns_confidence <session_count> <project_count>
# Output: low|medium|high
pi_patterns_confidence() {
    local sessions="$1" projects="$2"
    [[ "$sessions" =~ ^[0-9]+$ ]] || sessions=1
    [[ "$projects" =~ ^[0-9]+$ ]] || projects=1

    if [[ $sessions -ge 4 ]] || [[ $projects -ge 2 ]]; then
        echo "high"
    elif [[ $sessions -ge 2 ]]; then
        echo "medium"
    else
        echo "low"
    fi
}

# Check and enforce dormancy on stale patterns.
# Patterns not reinforced within PI_PATTERNS_DORMANCY_DAYS become dormant.
# Usage: pi_patterns_enforce_dormancy
pi_patterns_enforce_dormancy() {
    local dormancy_days="$PI_PATTERNS_DORMANCY_DAYS"
    [[ "$dormancy_days" =~ ^[0-9]+$ ]] || dormancy_days=180

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # SQLite date arithmetic: datetime('now', '-N days')
    local dormant_count
    dormant_count=$(episodic_db_exec "
        UPDATE user_patterns
        SET status='dormant', updated_at='$now'
        WHERE status='active'
          AND last_reinforced < datetime('now', '-$dormancy_days days');
        SELECT changes();
    ")

    if [[ "${dormant_count:-0}" -gt 0 ]]; then
        episodic_log "INFO" "Enforced dormancy on $dormant_count patterns (>$dormancy_days days since reinforcement)"
    fi
}

# ─── Knowledge Repo Functions ─────────────────────────────────────────

# Write a pattern to the knowledge repo as a markdown file.
# Usage: pi_patterns_write_to_repo <id> <category> <name> <description> <behavioral_instruction> <confidence> <weight>
pi_patterns_write_to_repo() {
    local id="$1" category="$2" name="$3" description="$4"
    local instruction="$5" confidence="$6" weight="$7"

    local knowledge_dir="$EPISODIC_KNOWLEDGE_DIR"
    if [[ ! -d "$knowledge_dir" ]]; then
        episodic_log "WARN" "Knowledge dir not found, skipping repo write"
        return 0
    fi

    # Sanitize for path safety
    local safe_id safe_cat
    safe_id=$(episodic_sanitize_name "$id")
    safe_cat=$(episodic_sanitize_name "$category")

    local pattern_dir="$knowledge_dir/_user/patterns/$safe_cat"
    mkdir -p "$pattern_dir"

    local pattern_file="$pattern_dir/${safe_id}.md"

    # Refuse to write to symlinks
    if [[ -L "$pattern_file" ]]; then
        episodic_log "ERROR" "Refusing to write to symlink: $pattern_file"
        return 1
    fi

    local generated
    generated=$(date -u +"%Y-%m-%d")

    printf '%s\n' "---
name: ${name}
category: ${category}
confidence: ${confidence}
weight: ${weight}
generated: ${generated}
---

# ${name}

${description}

## Behavioral Instruction

${instruction}" > "$pattern_file"

    episodic_log "INFO" "Wrote pattern to repo: $pattern_file"
}

# Write the patterns.yaml index to the knowledge repo.
# Usage: pi_patterns_write_index
pi_patterns_write_index() {
    local knowledge_dir="$EPISODIC_KNOWLEDGE_DIR"
    if [[ ! -d "$knowledge_dir" ]]; then
        return 0
    fi

    local index_file="$knowledge_dir/_user/patterns.yaml"
    mkdir -p "$(dirname "$index_file")"

    # Refuse to write to symlinks
    if [[ -L "$index_file" ]]; then
        episodic_log "ERROR" "Refusing to write to symlink: $index_file"
        return 1
    fi

    local patterns_json
    patterns_json=$(pi_patterns_list --status active 2>/dev/null)

    if [[ -z "$patterns_json" || "$patterns_json" == "[]" ]]; then
        printf 'patterns: []\n' > "$index_file"
        return 0
    fi

    # Generate YAML from JSON
    {
        printf "# User Behavioral Patterns Index\n"
        printf "# Auto-generated by project-intelligence\n"
        printf "generated: %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf "patterns:\n"
        echo "$patterns_json" | jq -r '.[] | "  - id: \(.id)\n    name: \(.name)\n    category: \(.category)\n    confidence: \(.confidence)\n    weight: \(.weight)"'
    } > "$index_file"

    episodic_log "INFO" "Wrote patterns index: $index_file"
}

# ─── Extraction Pipeline ──────────────────────────────────────────────

# Load transcripts from ALL projects for cross-project pattern detection.
# Usage: pi_patterns_load_cross_project_transcripts [limit]
# Output: text block with project-tagged transcripts
pi_patterns_load_cross_project_transcripts() {
    local limit="${1:-$PI_PATTERNS_TRANSCRIPT_COUNT}"
    local max_per="${PI_PATTERNS_TRANSCRIPT_CHARS:-20000}"

    [[ "$limit" =~ ^[0-9]+$ ]] || limit=10
    [[ "$max_per" =~ ^[0-9]+$ ]] || max_per=20000

    local transcripts=""
    local loaded=0

    # Get recent sessions across ALL projects
    local session_rows
    session_rows=$(episodic_db_exec "SELECT id, project FROM sessions ORDER BY created_at DESC LIMIT $limit;" 2>/dev/null || true)

    if [[ -z "$session_rows" ]]; then
        echo "(No sessions found for pattern extraction)"
        return 1
    fi

    while IFS='|' read -r sid project; do
        [[ -z "$sid" ]] && continue

        # Try archive file
        local archive_file="$EPISODIC_ARCHIVE_DIR/$project/$sid.jsonl"
        if [[ -f "$archive_file" ]]; then
            local transcript
            transcript=$(episodic_extract "$archive_file" 2>/dev/null || true)
            if [[ -n "$transcript" && ${#transcript} -gt 100 ]]; then
                if [[ ${#transcript} -gt $max_per ]]; then
                    transcript="${transcript:0:$max_per}
[... truncated at ${max_per} chars ...]"
                fi
                transcripts+="### Session $sid (project: $project)"$'\n'"$transcript"$'\n\n'
                loaded=$((loaded + 1))
            fi
        fi
    done <<< "$session_rows"

    if [[ $loaded -eq 0 ]]; then
        echo "(No transcripts found for pattern extraction)"
        return 1
    fi

    episodic_log "INFO" "Loaded $loaded cross-project transcripts for pattern extraction (${#transcripts} chars)"
    echo "$transcripts"
}

# Load existing patterns as context for extraction.
# Usage: pi_patterns_load_existing
# Output: text block with existing patterns
pi_patterns_load_existing() {
    local patterns_json
    patterns_json=$(episodic_db_query_json "SELECT id, category, name, description, confidence, weight, session_count, project_count, behavioral_instruction, status FROM user_patterns WHERE status IN ('active','dormant') ORDER BY weight DESC;" 2>/dev/null)

    if [[ -z "$patterns_json" || "$patterns_json" == "[]" ]]; then
        echo "(No existing patterns)"
        return 0
    fi

    local text=""
    local count
    count=$(echo "$patterns_json" | jq 'length')

    local i
    for ((i = 0; i < count; i++)); do
        local pid pname pcat pconf pweight pstatus pinstruction
        pid=$(echo "$patterns_json" | jq -r ".[$i].id")
        pname=$(echo "$patterns_json" | jq -r ".[$i].name")
        pcat=$(echo "$patterns_json" | jq -r ".[$i].category")
        pconf=$(echo "$patterns_json" | jq -r ".[$i].confidence")
        pweight=$(echo "$patterns_json" | jq -r ".[$i].weight")
        pstatus=$(echo "$patterns_json" | jq -r ".[$i].status")
        pinstruction=$(echo "$patterns_json" | jq -r ".[$i].behavioral_instruction // \"\"")

        text+="- **$pid** [$pcat, $pconf, weight=$pweight, $pstatus]: $pname"$'\n'
        text+="  Instruction: $pinstruction"$'\n'
    done

    echo "$text"
}

# Call Opus to extract behavioral patterns from cross-project transcripts.
# Uses the same API call structure as synthesize.sh.
# Usage: pi_patterns_extract [--dry-run]
pi_patterns_extract() {
    local dry_run=""
    [[ "${1:-}" == "--dry-run" ]] && dry_run="true"

    # Load cross-project transcripts
    local transcripts
    transcripts=$(pi_patterns_load_cross_project_transcripts "$PI_PATTERNS_TRANSCRIPT_COUNT" 2>/dev/null) || true

    if [[ -z "$transcripts" || "$transcripts" == *"No transcripts found"* || "$transcripts" == *"No sessions found"* ]]; then
        episodic_log "INFO" "No transcripts available for pattern extraction"
        return 0
    fi

    # Load existing patterns
    local existing
    existing=$(pi_patterns_load_existing)

    if [[ "$dry_run" == "true" ]]; then
        echo "=== DRY RUN: Pattern Extraction ==="
        echo ""
        echo "Cross-project transcripts: ${#transcripts} chars"
        echo ""
        echo "Existing patterns:"
        echo "$existing"
        echo ""
        echo "Would call $PI_PATTERNS_MODEL API with ${PI_PATTERNS_THINKING_BUDGET} token thinking budget."
        return 0
    fi

    episodic_require_api_key || return 1

    local system_prompt
    system_prompt='You are analyzing Claude Code session transcripts to identify BEHAVIORAL PATTERNS of the user — how they think, verify, investigate, and communicate.

## What you are looking for

NOT project-specific knowledge (that is handled by skills). Instead, you seek CROSS-PROJECT behavioral patterns:

1. **Verification patterns**: How does the user validate claims? Do they always check independently?
2. **Investigation patterns**: What is their drill-down methodology? Broad→narrow? Compare→contrast?
3. **Methodology patterns**: Do they establish procedures before executing? Codify into reusable tools?
4. **Communication patterns**: How do they want results presented? Reports? Tables? Summaries?
5. **Correction patterns**: What common mistakes do they catch? What errors do they flag repeatedly?

## Output format

Output ONLY a valid JSON array:
[{
  "action": "create|update|retire",
  "id": "pattern-id-kebab-case",
  "category": "verification|investigation|methodology|communication|correction",
  "name": "Human-Readable Pattern Name",
  "description": "2-3 sentence description of the pattern with evidence from transcripts",
  "behavioral_instruction": "1-2 sentence instruction for Claude. This is the KEY field — it tells Claude what to DO differently. Be specific and actionable.",
  "confidence": "low|medium|high",
  "evidence": ["session-id-1", "session-id-2"],
  "projects": ["project1", "project2"]
}]

## Rules

1. CROSS-PROJECT patterns only. A pattern seen in one project that applies universally is valid. A pattern only relevant to one specific project is NOT (that belongs in project skills).
2. Each behavioral_instruction must be actionable — it should change Claude'\''s behavior, not just describe the user.
3. Evidence must reference real session IDs from the input.
4. Confidence: 1 session = low, 2-3 sessions = medium, 4+ sessions or 2+ projects = high.
5. When updating: preserve existing evidence, add new. When retiring: explain why in the description.
6. Quality over quantity — return empty array [] rather than produce vague patterns.
7. The behavioral_instruction should be ~100-150 tokens max. It will be injected into every session.
8. Do NOT include PII, credentials, or sensitive information in any field.'

    local user_prompt="Analyze these cross-project session transcripts and extract user behavioral patterns."

    if [[ -n "$existing" && "$existing" != *"No existing patterns"* ]]; then
        user_prompt+="

## Existing Patterns (update, retire, or leave alone)
$existing"
    fi

    user_prompt+="

## Session Transcripts (from multiple projects)
$transcripts

Generate the JSON array of pattern actions. Remember: cross-project behavioral patterns only, quality over quantity."

    # Sanitize for JSON encoding
    user_prompt=$(printf '%s' "$user_prompt" | tr -d '\000-\010\013\014\016-\037')

    local thinking_budget="$PI_PATTERNS_THINKING_BUDGET"

    local request_json
    request_json=$(jq -n \
        --arg model "$PI_PATTERNS_MODEL" \
        --arg system "$system_prompt" \
        --arg user "$user_prompt" \
        --argjson budget "$thinking_budget" \
        '{
            model: $model,
            max_tokens: ($budget + 8000),
            thinking: {
                type: "enabled",
                budget_tokens: $budget
            },
            system: $system,
            messages: [{
                role: "user",
                content: $user
            }]
        }')

    if [[ -z "$request_json" ]]; then
        episodic_log "ERROR" "Failed to build pattern extraction request JSON"
        return 1
    fi

    episodic_log "INFO" "Calling $PI_PATTERNS_MODEL (thinking=$thinking_budget) for pattern extraction..."

    local response
    response=$(curl -s --max-time 300 \
        "$EPISODIC_API_BASE_URL/v1/messages" \
        -H "x-api-key: $EPISODIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$request_json" 2>/dev/null)

    if [[ $? -ne 0 || -z "$response" ]]; then
        episodic_log "ERROR" "API call failed during pattern extraction"
        return 1
    fi

    # Check for API errors
    local error_type
    error_type=$(echo "$response" | jq -r '.error.type // empty' 2>/dev/null)
    if [[ -n "$error_type" ]]; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.error.message // "unknown error"' 2>/dev/null)
        episodic_log "ERROR" "API error during pattern extraction: $error_type - $error_msg"
        return 1
    fi

    # Extract text content (handle thinking response)
    local content
    content=$(echo "$response" | jq -r '[.content[] | select(.type == "text")] | last | .text // empty' 2>/dev/null)

    if [[ -z "$content" ]]; then
        episodic_log "ERROR" "No content in pattern extraction response"
        return 1
    fi

    # Log usage
    local input_tokens output_tokens
    input_tokens=$(echo "$response" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
    output_tokens=$(echo "$response" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
    episodic_log "INFO" "Pattern extraction API usage: ${input_tokens} in / ${output_tokens} out ($PI_PATTERNS_MODEL)"

    # Extract JSON — multi-strategy (same as synthesize.sh)
    local json_content=""

    # Strategy 1: Parse whole content as JSON array
    if echo "$content" | jq -e 'type == "array"' >/dev/null 2>&1; then
        json_content="$content"
    fi

    # Strategy 2: Extract from markdown fences
    if [[ -z "$json_content" ]]; then
        json_content=$(echo "$content" | sed 's/^```json//;s/^```//;s/```$//' | sed '/^$/d')
    fi

    # Strategy 3: Extract between first [ and last ]
    if ! echo "$json_content" | jq -e 'type == "array"' >/dev/null 2>&1; then
        json_content=$(echo "$content" | sed -n '/\[/,/\]/p')
    fi

    # Validate JSON array
    if ! echo "$json_content" | jq -e 'type == "array"' >/dev/null 2>&1; then
        episodic_log "ERROR" "Pattern extraction returned invalid JSON (${#content} chars)"
        return 1
    fi

    # Process results
    pi_patterns_process_extraction "$json_content"
}

# Process extracted patterns from Opus response.
# Handles create, update, and retire actions.
# Usage: pi_patterns_process_extraction <json_array>
pi_patterns_process_extraction() {
    local json_content="$1"

    local count
    count=$(echo "$json_content" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        episodic_log "INFO" "No patterns extracted"
        return 0
    fi

    local created=0 updated=0 retired=0

    local i
    for ((i = 0; i < count; i++)); do
        local action pid category pname description instruction confidence evidence_json projects_json
        action=$(echo "$json_content" | jq -r ".[$i].action // \"create\"")
        pid=$(echo "$json_content" | jq -r ".[$i].id")
        category=$(echo "$json_content" | jq -r ".[$i].category // \"methodology\"")
        pname=$(echo "$json_content" | jq -r ".[$i].name // \"\"")
        description=$(echo "$json_content" | jq -r ".[$i].description // \"\"")
        instruction=$(echo "$json_content" | jq -r ".[$i].behavioral_instruction // \"\"")
        confidence=$(echo "$json_content" | jq -r ".[$i].confidence // \"low\"")
        evidence_json=$(echo "$json_content" | jq -c ".[$i].evidence // []")
        projects_json=$(echo "$json_content" | jq -c ".[$i].projects // []")

        # Sanitize pattern ID
        pid=$(episodic_sanitize_name "$pid")
        if [[ -z "$pid" || "$pid" == "unnamed" ]]; then
            episodic_log "WARN" "Skipping pattern with invalid ID"
            continue
        fi

        # Validate category
        if ! pi_patterns_validate_category "$category"; then
            episodic_log "WARN" "Skipping pattern $pid with invalid category: $category"
            continue
        fi

        if [[ "$action" == "retire" ]]; then
            pi_patterns_retire "$pid"
            retired=$((retired + 1))
            continue
        fi

        # Count sessions and projects for this pattern
        local session_count project_count
        session_count=$(echo "$evidence_json" | jq 'length')
        project_count=$(echo "$projects_json" | jq 'length')
        [[ "$session_count" =~ ^[0-9]+$ ]] || session_count=1
        [[ "$project_count" =~ ^[0-9]+$ ]] || project_count=1
        [[ $session_count -lt 1 ]] && session_count=1
        [[ $project_count -lt 1 ]] && project_count=1

        # If updating, merge with existing evidence counts
        if [[ "$action" == "update" ]]; then
            local existing_sessions existing_projects
            existing_sessions=$(episodic_db_exec "SELECT session_count FROM user_patterns WHERE id='$(episodic_sql_escape "$pid")';" 2>/dev/null || echo "0")
            existing_projects=$(episodic_db_exec "SELECT project_count FROM user_patterns WHERE id='$(episodic_sql_escape "$pid")';" 2>/dev/null || echo "0")
            [[ "$existing_sessions" =~ ^[0-9]+$ ]] || existing_sessions=0
            [[ "$existing_projects" =~ ^[0-9]+$ ]] || existing_projects=0

            # Take the max of old + new evidence
            session_count=$(( existing_sessions > session_count ? existing_sessions : session_count ))
            project_count=$(( existing_projects > project_count ? existing_projects : project_count ))
        fi

        # Calculate confidence from counts
        confidence=$(pi_patterns_confidence "$session_count" "$project_count")

        # Calculate weight: 1.0 + 0.25 per extra project
        local weight
        weight=$(awk "BEGIN { w = 1.0 + ($project_count - 1) * 0.25; cap = $PI_PATTERNS_WEIGHT_CAP; print (w > cap) ? cap : w }")

        # Write pattern
        pi_patterns_write "$pid" "$category" "$pname" "$description" "$evidence_json" "$confidence" "$weight" "$session_count" "$project_count" "$instruction"

        # Write to knowledge repo
        pi_patterns_write_to_repo "$pid" "$category" "$pname" "$description" "$instruction" "$confidence" "$weight"

        # Add evidence entries
        local j evidence_count
        evidence_count=$(echo "$evidence_json" | jq 'length')
        for ((j = 0; j < evidence_count; j++)); do
            local eid
            eid=$(echo "$evidence_json" | jq -r ".[$j]")
            if [[ -n "$eid" && "$eid" != "null" ]]; then
                # Determine project from session
                local eproj
                eproj=$(episodic_db_exec "SELECT project FROM sessions WHERE id='$(episodic_sql_escape "$eid")';" 2>/dev/null || echo "unknown")
                pi_patterns_add_evidence "$pid" "$eid" "${eproj:-unknown}" "Extracted from session transcript"
            fi
        done

        if [[ "$action" == "update" ]]; then
            updated=$((updated + 1))
        else
            created=$((created + 1))
        fi
    done

    # Write patterns index
    pi_patterns_write_index

    # Log extraction
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    episodic_db_exec "INSERT INTO pattern_extraction_log (extracted_at, session_count, patterns_created, patterns_updated, patterns_retired, model) VALUES ('$now', $PI_PATTERNS_TRANSCRIPT_COUNT, $created, $updated, $retired, '$(episodic_sql_escape "$PI_PATTERNS_MODEL")');"

    # Enforce dormancy on stale patterns
    pi_patterns_enforce_dormancy

    episodic_log "INFO" "Pattern extraction complete: $created created, $updated updated, $retired retired"
    echo "Pattern extraction complete: $created created, $updated updated, $retired retired"
}

# ─── Context Injection ────────────────────────────────────────────────

# Generate context injection text for active patterns.
# Outputs behavioral instructions for top-weighted active patterns.
# Usage: pi_patterns_generate_context
# Output: markdown text block
pi_patterns_generate_context() {
    local max_inject="$PI_PATTERNS_MAX_INJECT"
    [[ "$max_inject" =~ ^[0-9]+$ ]] || max_inject=8

    local patterns_json
    patterns_json=$(episodic_db_query_json "SELECT id, category, name, confidence, behavioral_instruction FROM user_patterns WHERE status='active' AND behavioral_instruction IS NOT NULL AND behavioral_instruction != '' ORDER BY weight DESC, last_reinforced DESC LIMIT $max_inject;" 2>/dev/null)

    if [[ -z "$patterns_json" || "$patterns_json" == "[]" ]]; then
        return 0
    fi

    local count
    count=$(echo "$patterns_json" | jq 'length')
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    echo "## User Behavioral Patterns"
    echo ""

    local i
    for ((i = 0; i < count; i++)); do
        local pid pcat pname pconf pinstruction
        pid=$(echo "$patterns_json" | jq -r ".[$i].id")
        pcat=$(echo "$patterns_json" | jq -r ".[$i].category")
        pname=$(echo "$patterns_json" | jq -r ".[$i].name")
        pconf=$(echo "$patterns_json" | jq -r ".[$i].confidence")
        pinstruction=$(echo "$patterns_json" | jq -r ".[$i].behavioral_instruction")

        echo "### ${pname} [${pcat}, ${pconf}]"
        echo "$pinstruction"
        echo ""
    done
}

# ─── Auto-Extraction Trigger ─────────────────────────────────────────

# Check if extraction should run and trigger it if threshold met.
# Called from on-session-start.sh. Counts total sessions since last extraction.
# Usage: pi_patterns_maybe_extract
pi_patterns_maybe_extract() {
    # Skip during backfill
    if [[ "${EPISODIC_BACKFILL_MODE:-}" == "true" ]]; then
        episodic_log "INFO" "Skipping auto pattern extraction during backfill"
        return 0
    fi

    local extract_every="$PI_PATTERNS_EXTRACT_EVERY"
    [[ "$extract_every" =~ ^[0-9]+$ ]] || extract_every=5

    # Count sessions since last extraction
    local last_extraction
    last_extraction=$(episodic_db_exec "SELECT MAX(extracted_at) FROM pattern_extraction_log;" 2>/dev/null || true)

    local sessions_since
    if [[ -z "$last_extraction" || "$last_extraction" == "" ]]; then
        # Never extracted — count all sessions
        sessions_since=$(episodic_db_exec "SELECT count(*) FROM sessions;" 2>/dev/null || echo "0")
    else
        local safe_last
        safe_last=$(episodic_sql_escape "$last_extraction")
        sessions_since=$(episodic_db_exec "SELECT count(*) FROM sessions WHERE archived_at > '$safe_last';" 2>/dev/null || echo "0")
    fi

    if [[ "${sessions_since:-0}" -ge "$extract_every" ]]; then
        episodic_log "INFO" "Auto pattern extraction triggered ($sessions_since sessions since last extraction)"

        # Run extraction in background
        (
            pi_patterns_extract 2>/dev/null
            if [[ $? -eq 0 ]]; then
                episodic_log "INFO" "Auto pattern extraction completed"
            else
                episodic_log "WARN" "Auto pattern extraction failed"
            fi
        ) &

        episodic_log "INFO" "Auto pattern extraction spawned in background (PID $!)"
    fi
}

# ─── Backfill ─────────────────────────────────────────────────────────

# Backfill: run pattern extraction across all existing sessions.
# Usage: pi_patterns_backfill [--dry-run]
pi_patterns_backfill() {
    local dry_run=""
    [[ "${1:-}" == "--dry-run" ]] && dry_run="--dry-run"

    echo "Running pattern extraction across all sessions..."

    # Use higher transcript count for backfill
    local orig_count="$PI_PATTERNS_TRANSCRIPT_COUNT"
    PI_PATTERNS_TRANSCRIPT_COUNT=20

    pi_patterns_extract $dry_run
    local rc=$?

    PI_PATTERNS_TRANSCRIPT_COUNT="$orig_count"
    return $rc
}

# ─── Stats ────────────────────────────────────────────────────────────

# Show pattern statistics.
# Usage: pi_patterns_stats
pi_patterns_stats() {
    local total active dormant retired
    total=$(episodic_db_exec "SELECT count(*) FROM user_patterns;" 2>/dev/null || echo "0")
    active=$(episodic_db_exec "SELECT count(*) FROM user_patterns WHERE status='active';" 2>/dev/null || echo "0")
    dormant=$(episodic_db_exec "SELECT count(*) FROM user_patterns WHERE status='dormant';" 2>/dev/null || echo "0")
    retired=$(episodic_db_exec "SELECT count(*) FROM user_patterns WHERE status='retired';" 2>/dev/null || echo "0")

    local evidence_count
    evidence_count=$(episodic_db_exec "SELECT count(*) FROM pattern_evidence;" 2>/dev/null || echo "0")

    local extraction_count
    extraction_count=$(episodic_db_exec "SELECT count(*) FROM pattern_extraction_log;" 2>/dev/null || echo "0")

    local last_extraction
    last_extraction=$(episodic_db_exec "SELECT MAX(extracted_at) FROM pattern_extraction_log;" 2>/dev/null || echo "never")

    local high_conf
    high_conf=$(episodic_db_exec "SELECT count(*) FROM user_patterns WHERE confidence='high' AND status='active';" 2>/dev/null || echo "0")

    echo "Pattern Statistics"
    echo "══════════════════════════════"
    echo "Total patterns:     $total"
    echo "  Active:           $active"
    echo "  Dormant:          $dormant"
    echo "  Retired:          $retired"
    echo "  High confidence:  $high_conf"
    echo ""
    echo "Evidence entries:   $evidence_count"
    echo "Extractions run:    $extraction_count"
    echo "Last extraction:    ${last_extraction:-never}"
}
