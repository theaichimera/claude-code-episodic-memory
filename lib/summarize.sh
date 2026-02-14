#!/usr/bin/env bash
# episodic-memory: API call for structured session summaries

_EPISODIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_EPISODIC_LIB_DIR/config.sh"

# Generate a structured summary of a session transcript
# Input: cleaned transcript text (from episodic_extract)
# Output: JSON with topics, decisions, dead_ends, artifacts_created, key_insights, summary
episodic_summarize() {
    local transcript="$1"
    local model="${2:-$EPISODIC_SUMMARY_MODEL}"

    episodic_require_api_key || return 1

    if [[ -z "$transcript" || ${#transcript} -lt 50 ]]; then
        episodic_log "WARN" "Transcript too short to summarize (${#transcript} chars)"
        echo '{"topics":[],"decisions":[],"dead_ends":[],"artifacts_created":[],"key_insights":[],"summary":"Session too short to summarize."}'
        return 0
    fi

    # Cap transcript — 50K is plenty for Opus to understand the full session
    local max_for_summary=50000
    if [[ ${#transcript} -gt $max_for_summary ]]; then
        transcript="${transcript:0:$max_for_summary}"
    fi

    local system_prompt='You analyze Claude Code session transcripts and produce structured JSON summaries.
Output ONLY valid JSON with this exact schema:
{
  "topics": ["topic1", "topic2"],
  "decisions": ["decision1", "decision2"],
  "dead_ends": ["thing tried that did not work"],
  "artifacts_created": ["files or things created"],
  "key_insights": ["important learnings"],
  "summary": "2-4 sentence narrative of what happened in the session."
}
Rules:
- topics: 2-6 short phrases describing what the session was about
- decisions: key choices made and why (include the reasoning)
- dead_ends: approaches tried that failed or were abandoned
- artifacts_created: files, scripts, configs created or significantly modified
- key_insights: non-obvious learnings that would be useful in future sessions
- summary: concise narrative focusing on what was accomplished and why
- If a field has no entries, use an empty array []
- Output ONLY the JSON object, no markdown fences, no explanation'

    # Sanitize transcript: strip control chars that break JSON encoding
    # Keep tabs (\011) and newlines (\012, \015) — strip everything else 0x00-0x1F
    transcript=$(printf '%s' "$transcript" | tr -d '\000-\010\013\014\016-\037')

    # Build the request JSON
    # Support extended thinking when configured and model supports it
    local request_json
    if [[ "$EPISODIC_SUMMARY_THINKING" == "true" ]]; then
        local budget="${EPISODIC_SUMMARY_THINKING_BUDGET:-10000}"
        request_json=$(jq -n \
            --arg model "$model" \
            --arg system "$system_prompt" \
            --arg transcript "$transcript" \
            --argjson budget "$budget" \
            '{
                model: $model,
                max_tokens: 16000,
                thinking: {
                    type: "enabled",
                    budget_tokens: $budget
                },
                system: $system,
                messages: [{
                    role: "user",
                    content: ("Analyze the following Claude Code session transcript and produce a structured JSON summary. The transcript is delimited by <transcript> tags. Do NOT continue the conversation — only output the JSON summary.\n\n<transcript>\n" + $transcript + "\n</transcript>\n\nNow output ONLY the JSON summary object.")
                }]
            }')
    else
        request_json=$(jq -n \
            --arg model "$model" \
            --arg system "$system_prompt" \
            --arg transcript "$transcript" \
            '{
                model: $model,
                max_tokens: 4096,
                system: $system,
                messages: [{
                    role: "user",
                    content: ("Analyze the following Claude Code session transcript and produce a structured JSON summary. The transcript is delimited by <transcript> tags. Do NOT continue the conversation — only output the JSON summary.\n\n<transcript>\n" + $transcript + "\n</transcript>\n\nNow output ONLY the JSON summary object.")
                }]
            }')
    fi

    if [[ -z "$request_json" ]]; then
        episodic_log "ERROR" "Failed to build request JSON (transcript may contain invalid chars)"
        return 1
    fi

    episodic_log "INFO" "Calling $model (thinking=$EPISODIC_SUMMARY_THINKING) for summary..."

    local response
    response=$(curl -s --max-time 120 \
        https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$request_json" 2>/dev/null)

    if [[ $? -ne 0 || -z "$response" ]]; then
        episodic_log "ERROR" "API call failed (timeout or network error)"
        return 1
    fi

    # Check for API errors
    local error_type
    error_type=$(echo "$response" | jq -r '.error.type // empty' 2>/dev/null)
    if [[ -n "$error_type" ]]; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.error.message // "unknown error"' 2>/dev/null)
        episodic_log "ERROR" "API error ($model): $error_type - $error_msg"
        return 1
    fi

    # Extract the text content — handle both thinking and non-thinking responses
    # With thinking: content array has [{type:"thinking",...}, {type:"text",...}]
    # Without thinking: content array has [{type:"text",...}]
    local content
    content=$(echo "$response" | jq -r '[.content[] | select(.type == "text")] | last | .text // empty' 2>/dev/null)

    if [[ -z "$content" ]]; then
        episodic_log "ERROR" "No text content in API response"
        episodic_log "DEBUG" "Response keys: $(echo "$response" | jq -c 'keys' 2>/dev/null)"
        return 1
    fi

    # Log usage stats
    local input_tokens output_tokens
    input_tokens=$(echo "$response" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
    output_tokens=$(echo "$response" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
    episodic_log "INFO" "API usage: ${input_tokens} in / ${output_tokens} out ($model)"

    # Extract JSON from response — handle multiple formats:
    # 1. Raw JSON (ideal)
    # 2. ```json\n{...}\n```
    # 3. ```\n{...}\n```
    # 4. Text before/after JSON object
    local json_content=""

    # Strategy 1: Try parsing the whole content as JSON directly
    if echo "$content" | jq -e '.topics and .summary' >/dev/null 2>&1; then
        json_content="$content"
    fi

    # Strategy 2: Extract lines between { and } (handles fence-wrapped JSON)
    if [[ -z "$json_content" ]]; then
        json_content=$(echo "$content" | sed -n '/^{/,/^}/p')
    fi

    # Strategy 3: Strip all ``` lines and try again
    if [[ -z "$json_content" ]] || ! echo "$json_content" | jq -e '.topics' >/dev/null 2>&1; then
        json_content=$(echo "$content" | grep -v '^```' | sed '/^$/d')
    fi

    # Strategy 4: Extract everything between first { and last }
    if ! echo "$json_content" | jq -e '.topics and .summary' >/dev/null 2>&1; then
        json_content=$(echo "$content" | sed -n '/{/,/}/p' | sed 's/^[^{]*//' | sed 's/[^}]*$//')
    fi

    # Final validation
    if echo "$json_content" | jq -e '.topics and .summary' >/dev/null 2>&1; then
        echo "$json_content"
    else
        episodic_log "ERROR" "Model returned invalid summary JSON (${#content} chars)"
        return 1
    fi
}
