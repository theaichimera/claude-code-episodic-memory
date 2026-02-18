#!/usr/bin/env bash
# episodic-memory: Opus skill generation logic (v2)
# Reads raw session transcripts (not just summaries) to produce deep, actionable skills.

_EPISODIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_EPISODIC_LIB_DIR/config.sh"
source "$_EPISODIC_LIB_DIR/db.sh"
source "$_EPISODIC_LIB_DIR/knowledge.sh"
source "$_EPISODIC_LIB_DIR/extract.sh"

# All defaults (EPISODIC_OPUS_MODEL, EPISODIC_SYNTHESIZE_EVERY, etc.)
# are set in config.sh — the single source of truth for configuration.

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
source: synthesized
---

${body}
EOF
}

# Write skill files from a JSON array of skills
# Input JSON format: [{"name":"skill-name","confidence":"high","body":"markdown content","sessions":["id1","id2"],"action":"create|update|delete"}]
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

    local written=0
    local deleted=0
    local i
    for ((i = 0; i < count; i++)); do
        local name action confidence body sessions_csv
        name=$(echo "$skills_json" | jq -r ".[$i].name")
        action=$(echo "$skills_json" | jq -r ".[$i].action // \"create\"")
        confidence=$(echo "$skills_json" | jq -r ".[$i].confidence // \"medium\"")
        body=$(echo "$skills_json" | jq -r ".[$i].body")
        sessions_csv=$(echo "$skills_json" | jq -r ".[$i].sessions // [] | join(\", \")")

        # Sanitize skill name from LLM output to prevent path traversal
        name=$(episodic_sanitize_name "$name")
        if [[ -z "$name" || "$name" == "unnamed" ]]; then
            episodic_log "WARN" "Skipping skill with invalid name"
            continue
        fi

        if [[ "$action" == "delete" ]]; then
            local skill_file="$EPISODIC_KNOWLEDGE_DIR/$project/skills/${name}.md"
            if [[ -f "$skill_file" && ! -L "$skill_file" ]]; then
                rm -f "$skill_file"
                episodic_log "INFO" "Deleted skill: $name (contradicted by new evidence)"
                deleted=$((deleted + 1))
            fi
            continue
        fi

        local formatted
        formatted=$(episodic_synthesize_format_skill "$name" "$project" "$sessions_csv" "$confidence" "$body")

        episodic_knowledge_write_skill "$project" "$name" "$formatted"
        written=$((written + 1))
    done

    episodic_log "INFO" "Skills for $project: $written written, $deleted deleted"
}

# Load raw transcripts from JSONL archives for recent sessions
# Falls back to archive directory listing if DB query returns no results
# Usage: episodic_synthesize_load_transcripts <project> [limit]
# Output: text block with session transcripts
episodic_synthesize_load_transcripts() {
    local project="$1"
    local limit="${2:-$EPISODIC_SYNTHESIZE_TRANSCRIPT_COUNT}"
    local max_per="${EPISODIC_SYNTHESIZE_TRANSCRIPT_CHARS:-30000}"

    # Validate numeric params
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=5
    [[ "$max_per" =~ ^[0-9]+$ ]] || max_per=30000

    local transcripts=""
    local loaded=0

    # Strategy 1: Query DB for session IDs, find archive files
    local safe_project
    safe_project=$(episodic_sql_escape "$project")
    local session_ids
    session_ids=$(episodic_db_exec "SELECT id FROM sessions WHERE project='$safe_project' ORDER BY created_at DESC LIMIT $limit;" 2>/dev/null || true)

    if [[ -n "$session_ids" ]]; then
        while IFS= read -r sid; do
            [[ -z "$sid" ]] && continue
            local archive_file="$EPISODIC_ARCHIVE_DIR/$project/$sid.jsonl"
            if [[ -f "$archive_file" ]]; then
                local transcript
                transcript=$(episodic_extract "$archive_file" 2>/dev/null || true)
                if [[ -n "$transcript" && ${#transcript} -gt 100 ]]; then
                    # Cap per transcript
                    if [[ ${#transcript} -gt $max_per ]]; then
                        transcript="${transcript:0:$max_per}
[... transcript truncated at ${max_per} chars ...]"
                    fi
                    transcripts+="### Session $sid"$'\n'"$transcript"$'\n\n'
                    loaded=$((loaded + 1))
                fi
            fi
        done <<< "$session_ids"
    fi

    # Strategy 2: Fall back to listing archive directory by mtime
    if [[ $loaded -eq 0 ]]; then
        local archive_dir="$EPISODIC_ARCHIVE_DIR/$project"
        if [[ -d "$archive_dir" ]]; then
            while IFS= read -r archive_file; do
                [[ -z "$archive_file" ]] && continue
                [[ $loaded -ge $limit ]] && break
                local sid
                sid=$(basename "$archive_file" .jsonl)
                local transcript
                transcript=$(episodic_extract "$archive_file" 2>/dev/null || true)
                if [[ -n "$transcript" && ${#transcript} -gt 100 ]]; then
                    if [[ ${#transcript} -gt $max_per ]]; then
                        transcript="${transcript:0:$max_per}
[... transcript truncated at ${max_per} chars ...]"
                    fi
                    transcripts+="### Session $sid"$'\n'"$transcript"$'\n\n'
                    loaded=$((loaded + 1))
                fi
            done < <(ls -t "$archive_dir"/*.jsonl 2>/dev/null | head -"$limit")
        fi
    fi

    if [[ $loaded -eq 0 ]]; then
        echo "(No transcripts found for $project)"
        return 1
    fi

    episodic_log "INFO" "Loaded $loaded transcripts for $project synthesis (${#transcripts} chars total)"
    echo "$transcripts"
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

# Load recent sessions summaries for a project (lighter-weight than transcripts)
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
# Uses raw transcripts (primary) + summaries (secondary) for maximum detail.
# Extended thinking enabled for deeper analysis.
# Usage: episodic_synthesize <project> [--dry-run]
episodic_synthesize() {
    local project="$1"
    local dry_run="${2:-}"

    if [[ -z "$project" ]]; then
        episodic_log "ERROR" "No project specified for synthesis"
        return 1
    fi

    # Load raw transcripts (primary input — this is where the real detail lives)
    local transcripts=""
    transcripts=$(episodic_synthesize_load_transcripts "$project" "$EPISODIC_SYNTHESIZE_TRANSCRIPT_COUNT" 2>/dev/null) || true

    # Load session summaries (secondary — covers older sessions beyond transcript window)
    local sessions_text
    sessions_text=$(episodic_synthesize_load_sessions "$project" 15) || true

    # Need at least one of these
    if [[ -z "$transcripts" && (-z "$sessions_text" || "$sessions_text" == *"No sessions found"*) ]]; then
        episodic_log "INFO" "No sessions to synthesize for $project"
        return 0
    fi

    # Load existing skills
    local existing_skills
    existing_skills=$(episodic_synthesize_load_existing "$project")

    if [[ "$dry_run" == "--dry-run" ]]; then
        echo "=== DRY RUN: Synthesis for $project ==="
        echo ""
        if [[ -n "$transcripts" ]]; then
            echo "Raw transcripts loaded: $(echo "$transcripts" | grep -c '^### Session') sessions (${#transcripts} chars)"
        else
            echo "No raw transcripts available"
        fi
        echo ""
        echo "Session summaries:"
        echo "$sessions_text"
        echo ""
        echo "Existing skills:"
        echo "$existing_skills"
        echo ""
        echo "Would call $EPISODIC_OPUS_MODEL API with ${EPISODIC_SYNTHESIZE_THINKING_BUDGET} token thinking budget."
        return 0
    fi

    # Require API key for actual synthesis
    episodic_require_api_key || return 1

    local system_prompt
    system_prompt='You are a senior engineer extracting reusable operational knowledge from Claude Code session transcripts.

You produce SKILLS — concise reference documents that prevent future sessions from re-learning things. Skills are injected into Claude Code sessions as startup context.

## What makes a good skill

A GOOD skill has ALL of these:
- A clear trigger condition: "When you encounter X..." or "Before doing Y..."
- Exact commands, file paths, config values, or API calls tested in the sessions
- At least one specific gotcha or failure mode discovered through actual work
- Decision criteria when multiple approaches exist: "Use A when X, use B when Y"

A BAD skill (DO NOT produce these):
- Vague advice: "Consider caching for performance"
- Documentation restating: "Express uses middleware for request handling"
- Summary disguised as skill: "We deployed to ECS and configured auto-scaling"
- Generic patterns anyone could guess: "Always write tests" or "Use version control"

## Output format

Output ONLY a valid JSON array:
[{
  "action": "create|update|delete",
  "name": "skill-name-kebab-case",
  "confidence": "high|medium|low",
  "body": "Full markdown body following the structure below",
  "sessions": ["session-id-1", "session-id-2"]
}]

## Required skill body structure

Every skill body MUST follow this template:

```
# <Descriptive Title>

## When to use
<Specific trigger: when does this knowledge apply? Be precise.>

## What to do
<Numbered steps with EXACT commands, file paths, config values.
Not "check the config" but "edit src/config/db.ts, set pool.max to 20".
Not "deploy the service" but "run: aws ecs update-service --cluster my-cluster --service my-service --force-new-deployment">

## Gotchas
<Bullet list of specific failure modes discovered in sessions.
Each gotcha must cite something actually encountered, not theoretical.
Example: "- Setting LOG_LEVEL=DEBUG in prod causes $25K/yr in CloudWatch costs (discovered session abc123)">

## Why
<1-2 sentences on the underlying mechanism. Why does this approach work? What is the root cause?>
```

## Rules

1. QUALITY OVER QUANTITY. One excellent skill beats five mediocre ones. Return empty array [] rather than produce vague skills.
2. If you cannot include at least one specific command, file path, or config value — the skill is not ready. Skip it.
3. Every gotcha must reference something actually encountered in the sessions, not hypothetical.
4. When updating existing skills: ADD new details, gotchas, and edge cases. Preserve existing specific details. Increment knowledge, do not flatten it.
5. When new evidence contradicts an existing skill, return action "delete" for the old one and optionally "create" a corrected replacement.
6. Merge overlapping topics into one comprehensive skill. Do not create 3 skills about deployment when one thorough one is better.
7. Confidence: 3+ sessions confirming = high, 2 = medium, 1 = low.
8. Session IDs in the "sessions" array must be real IDs from the input, not made up.'

    # Build user prompt with transcripts (primary) and summaries (secondary)
    local user_prompt="Analyze these sessions for project '$project' and generate, update, or delete skills.

READ THE RAW TRANSCRIPTS CAREFULLY — they contain the specific commands, errors, file paths, and debugging steps that make skills valuable. The summaries are for broader context only."

    if [[ -n "$transcripts" && "$transcripts" != *"No transcripts found"* ]]; then
        user_prompt+="

## Raw Session Transcripts (PRIMARY — mine these for specific details)
$transcripts"
    fi

    if [[ -n "$sessions_text" && "$sessions_text" != *"No sessions found"* ]]; then
        user_prompt+="

## Session Summaries (SECONDARY — for broader pattern coverage)
$sessions_text"
    fi

    user_prompt+="

## Existing Skills (update, delete, or leave alone)
$existing_skills

Generate the JSON array of skill actions. Remember: quality over quantity. Empty array is better than vague skills."

    # Sanitize for JSON encoding
    user_prompt=$(printf '%s' "$user_prompt" | tr -d '\000-\010\013\014\016-\037')

    local thinking_budget="$EPISODIC_SYNTHESIZE_THINKING_BUDGET"

    local request_json
    request_json=$(jq -n \
        --arg model "$EPISODIC_OPUS_MODEL" \
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
        episodic_log "ERROR" "Failed to build synthesis request JSON"
        return 1
    fi

    episodic_log "INFO" "Calling $EPISODIC_OPUS_MODEL (thinking=$thinking_budget) for synthesis of $project..."

    local response
    response=$(curl -s --max-time 300 \
        "$EPISODIC_API_BASE_URL/v1/messages" \
        -H "x-api-key: $EPISODIC_API_KEY" \
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

    # Extract text content (handle thinking response)
    local content
    content=$(echo "$response" | jq -r '[.content[] | select(.type == "text")] | last | .text // empty' 2>/dev/null)

    if [[ -z "$content" ]]; then
        episodic_log "ERROR" "No content in Opus response"
        return 1
    fi

    # Log usage stats
    local input_tokens output_tokens
    input_tokens=$(echo "$response" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
    output_tokens=$(echo "$response" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
    episodic_log "INFO" "Synthesis API usage: ${input_tokens} in / ${output_tokens} out ($EPISODIC_OPUS_MODEL)"

    # Extract JSON from response — handle multiple formats
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
        episodic_log "ERROR" "Opus returned invalid skills JSON (${#content} chars)"
        return 1
    fi

    local skill_count
    skill_count=$(echo "$json_content" | jq 'length')
    episodic_log "INFO" "Opus returned $skill_count skill actions for $project"

    # Write skills (handles create, update, delete)
    episodic_synthesize_write_skills "$project" "$json_content"

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
