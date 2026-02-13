#!/usr/bin/env bash
# episodic-memory: Opus skill generation logic
# Analyzes sessions and generates project-specific skills (structured prompts/playbooks).

_EPISODIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_EPISODIC_LIB_DIR/config.sh"
source "$_EPISODIC_LIB_DIR/db.sh"
source "$_EPISODIC_LIB_DIR/knowledge.sh"

EPISODIC_OPUS_MODEL="${EPISODIC_OPUS_MODEL:-claude-opus-4-6-20260205}"
EPISODIC_SYNTHESIZE_EVERY="${EPISODIC_SYNTHESIZE_EVERY:-5}"

# Generate a skill Markdown file with YAML frontmatter
# Usage: episodic_synthesize_format_skill <name> <project> <session_ids_csv> <confidence> <body>
episodic_synthesize_format_skill() {
    local name="$1"
    local project="$2"
    local session_ids="$3"
    local confidence="$4"
    local body="$5"
    local generated
    generated=$(date -u +"%Y-%m-%d")

    cat <<EOF
---
name: ${name}
project: ${project}
generated: ${generated}
sessions: [${session_ids}]
confidence: ${confidence}
---

${body}
EOF
}

# Write skill files from a JSON array of skills
# Input JSON format: [{"name":"skill-name","confidence":"high","body":"markdown content","sessions":["id1","id2"]}]
# Usage: episodic_synthesize_write_skills <project> <skills_json>
episodic_synthesize_write_skills() {
    local project="$1"
    local skills_json="$2"

    local count
    count=$(echo "$skills_json" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        episodic_log "INFO" "No skills to write for $project"
        return 0
    fi

    local i
    for ((i = 0; i < count; i++)); do
        local name confidence body sessions_csv
        name=$(echo "$skills_json" | jq -r ".[$i].name")
        confidence=$(echo "$skills_json" | jq -r ".[$i].confidence // \"medium\"")
        body=$(echo "$skills_json" | jq -r ".[$i].body")
        sessions_csv=$(echo "$skills_json" | jq -r ".[$i].sessions // [] | join(\", \")")

        local formatted
        formatted=$(episodic_synthesize_format_skill "$name" "$project" "$sessions_csv" "$confidence" "$body")

        episodic_knowledge_write_skill "$project" "$name" "$formatted"
    done

    episodic_log "INFO" "Wrote $count skills for $project"
}

# Load existing skills for a project as context for Opus
# Usage: episodic_synthesize_load_existing <project>
# Output: text block with all existing skills
episodic_synthesize_load_existing() {
    local project="$1"
    local skills_text=""

    local skills
    skills=$(episodic_knowledge_list_skills "$project")

    if [[ -z "$skills" ]]; then
        echo "(No existing skills)"
        return 0
    fi

    while IFS= read -r skill_name; do
        local content
        content=$(episodic_knowledge_read_skill "$project" "$skill_name" 2>/dev/null || true)
        if [[ -n "$content" ]]; then
            skills_text+="### $skill_name.md"$'\n'"$content"$'\n\n'
        fi
    done <<< "$skills"

    echo "$skills_text"
}

# Load recent sessions for a project as context for Opus
# Usage: episodic_synthesize_load_sessions <project> [limit]
# Output: text block with session summaries
episodic_synthesize_load_sessions() {
    local project="$1"
    local limit="${2:-10}"

    local sessions
    sessions=$(episodic_db_recent "$project" "$limit")

    if [[ -z "$sessions" || "$sessions" == "[]" ]]; then
        echo "(No sessions found for $project)"
        return 1
    fi

    local count
    count=$(echo "$sessions" | jq 'length')
    local sessions_text=""

    local i
    for ((i = 0; i < count; i++)); do
        local id created summary topics decisions insights
        id=$(echo "$sessions" | jq -r ".[$i].id")
        created=$(echo "$sessions" | jq -r ".[$i].created_at")
        summary=$(echo "$sessions" | jq -r ".[$i].summary // \"\"")
        topics=$(echo "$sessions" | jq -r ".[$i].topics // \"\"")
        decisions=$(echo "$sessions" | jq -r ".[$i].decisions // \"\"")
        insights=$(echo "$sessions" | jq -r ".[$i].key_insights // \"\"")

        sessions_text+="## Session $id ($created)"$'\n'
        sessions_text+="Topics: $topics"$'\n'
        sessions_text+="Summary: $summary"$'\n'
        sessions_text+="Decisions: $decisions"$'\n'
        sessions_text+="Insights: $insights"$'\n\n'
    done

    echo "$sessions_text"
}

# Call Opus to synthesize skills from sessions
# Usage: episodic_synthesize <project> [--dry-run]
episodic_synthesize() {
    local project="$1"
    local dry_run="${2:-}"

    if [[ -z "$project" ]]; then
        episodic_log "ERROR" "No project specified for synthesis"
        return 1
    fi

    # Load session context
    local sessions_text
    sessions_text=$(episodic_synthesize_load_sessions "$project" 10)
    if [[ $? -ne 0 ]]; then
        episodic_log "INFO" "No sessions to synthesize for $project"
        return 0
    fi

    # Load existing skills
    local existing_skills
    existing_skills=$(episodic_synthesize_load_existing "$project")

    if [[ "$dry_run" == "--dry-run" ]]; then
        echo "=== DRY RUN: Synthesis for $project ==="
        echo ""
        echo "Sessions to analyze:"
        echo "$sessions_text"
        echo ""
        echo "Existing skills:"
        echo "$existing_skills"
        echo ""
        echo "Would call Opus API to generate skills."
        return 0
    fi

    # Require API key for actual synthesis
    episodic_require_api_key || return 1

    local system_prompt='You analyze Claude Code session histories and generate reusable project-specific skills.

Output ONLY valid JSON array with this schema:
[{
  "name": "skill-name-kebab-case",
  "confidence": "high|medium|low",
  "body": "Full markdown body of the skill (instructions, steps, context)",
  "sessions": ["session-id-1", "session-id-2"]
}]

Rules:
- Each skill captures a recurring pattern, workflow, or lesson learned
- Skills should be actionable instructions, not just observations
- Update existing skills if the sessions provide new information
- Set confidence based on how many sessions support the pattern (1=low, 2=medium, 3+=high)
- Use kebab-case for skill names
- The body should be practical Markdown with numbered steps where appropriate
- If no new skills are warranted, return an empty array []'

    local user_prompt="Analyze these sessions for project '$project' and generate/update skills.

## Recent Sessions
$sessions_text

## Existing Skills
$existing_skills

Generate a JSON array of new or updated skills."

    local request_json
    request_json=$(jq -n \
        --arg model "$EPISODIC_OPUS_MODEL" \
        --arg system "$system_prompt" \
        --arg user "$user_prompt" \
        '{
            model: $model,
            max_tokens: 4096,
            system: $system,
            messages: [{
                role: "user",
                content: $user
            }]
        }')

    local response
    response=$(curl -s --max-time 120 \
        https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$request_json" 2>/dev/null)

    if [[ $? -ne 0 || -z "$response" ]]; then
        episodic_log "ERROR" "Opus API call failed during synthesis"
        return 1
    fi

    # Check for API errors
    local error_type
    error_type=$(echo "$response" | jq -r '.error.type // empty' 2>/dev/null)
    if [[ -n "$error_type" ]]; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.error.message // "unknown error"' 2>/dev/null)
        episodic_log "ERROR" "Opus API error: $error_type - $error_msg"
        return 1
    fi

    # Extract content
    local content
    content=$(echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null)

    if [[ -z "$content" ]]; then
        episodic_log "ERROR" "No content in Opus response"
        return 1
    fi

    # Strip markdown fences if present
    content=$(echo "$content" | sed 's/^```json//;s/^```//;s/```$//' | sed '/^$/d')

    # Validate JSON array
    if ! echo "$content" | jq -e 'type == "array"' >/dev/null 2>&1; then
        episodic_log "ERROR" "Opus returned invalid skills JSON"
        episodic_log "DEBUG" "Raw content: $content"
        return 1
    fi

    # Write skills
    episodic_synthesize_write_skills "$project" "$content"

    # Push changes
    episodic_knowledge_push "Synthesize skills for $project"
}

# Check if synthesis should run and trigger it if threshold met
# Called after each archive. Runs in background if triggered.
# Usage: episodic_maybe_synthesize <project>
episodic_maybe_synthesize() {
    local project="$1"

    # Skip during backfill
    if [[ "${EPISODIC_BACKFILL_MODE:-}" == "true" ]]; then
        episodic_log "INFO" "Skipping auto-synthesis during backfill"
        return 0
    fi

    local count
    count=$(episodic_db_sessions_since_synthesis "$project")

    if [[ "$count" -ge "$EPISODIC_SYNTHESIZE_EVERY" ]]; then
        episodic_log "INFO" "Auto-synthesis triggered for $project ($count sessions since last synthesis)"

        # Run synthesis in background
        (
            episodic_synthesize "$project" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                episodic_db_log_synthesis "$project" "$count"
                episodic_log "INFO" "Auto-synthesis completed for $project"
            else
                episodic_log "WARN" "Auto-synthesis failed for $project"
            fi
        ) &

        episodic_log "INFO" "Auto-synthesis spawned in background (PID $!)"
    fi
}
