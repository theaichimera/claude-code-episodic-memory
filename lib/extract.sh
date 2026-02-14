#!/usr/bin/env bash
# episodic-memory: JSONL message extraction and filtering

_EPISODIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_EPISODIC_LIB_DIR/config.sh"

# Extract relevant messages from a JSONL session file
# Filters out progress events, file-history-snapshots, and system noise
# Outputs a cleaned text suitable for summarization
episodic_extract() {
    local jsonl_path="$1"
    local max_chars="${2:-$EPISODIC_MAX_EXTRACT_CHARS}"

    if [[ ! -f "$jsonl_path" ]]; then
        echo "ERROR: File not found: $jsonl_path" >&2
        return 1
    fi

    # Extract user and assistant messages, skip progress/snapshot/system
    # Write to temp file to avoid SIGPIPE issues with large outputs
    local tmpfile
    tmpfile=$(mktemp)
    trap 'rm -f "$tmpfile"' RETURN

    jq -r '
        select(.type == "user" or .type == "assistant") |
        if .type == "user" then
            "USER: " + (
                if (.message.content | type) == "string" then
                    .message.content
                elif (.message.content | type) == "array" then
                    [.message.content[] |
                        if type == "string" then .
                        elif .type == "text" then .text
                        elif .type == "tool_result" then
                            "tool_result: " + (if (.content | type) == "string" then .content else (.content // "" | tostring) end)
                        else ""
                        end
                    ] | join(" ")
                elif .data != null then
                    if (.data | type) == "string" then .data
                    else (.data | tostring)
                    end
                else
                    ""
                end
            )
        elif .type == "assistant" then
            "ASSISTANT: " + (
                if .message.content == null then ""
                elif (.message.content | type) == "string" then
                    .message.content
                elif (.message.content | type) == "array" then
                    [.message.content[] |
                        if .type == "text" then .text
                        elif .type == "tool_use" then
                            "tool:" + .name + "(" + (.input | tostring | .[0:200]) + ")"
                        elif .type == "thinking" then ""
                        else ""
                        end
                    ] | map(select(. != "")) | join(" ")
                else ""
                end
            )
        else ""
        end
    ' "$jsonl_path" > "$tmpfile" 2>/dev/null || true

    # Output (truncation is handled by the caller — summarize.sh caps at 50K)
    if [[ -f "$tmpfile" && -s "$tmpfile" ]]; then
        cat "$tmpfile"
    fi
}

# Extract metadata from a JSONL session file
# Returns JSON: {session_id, first_prompt, message_count, user_count, assistant_count, git_branch, created_at, modified_at}
episodic_extract_metadata() {
    local jsonl_path="$1"

    if [[ ! -f "$jsonl_path" ]]; then
        echo "ERROR: File not found: $jsonl_path" >&2
        return 1
    fi

    jq -s -r '
        # Count message types
        (map(select(.type == "user")) | length) as $user_count |
        (map(select(.type == "assistant")) | length) as $assistant_count |
        length as $total |

        # Get session ID from first message that has one
        (map(select(.sessionId != null)) | first // {} | .sessionId // "unknown") as $session_id |

        # Get git branch
        (map(select(.gitBranch != null)) | first // {} | .gitBranch // "") as $git_branch |

        # Get first user message as first_prompt
        (map(select(.type == "user")) | first // {} |
            if .message.content != null then
                if (.message.content | type) == "string" then .message.content
                elif (.message.content | type) == "array" then
                    [.message.content[] |
                        if type == "string" then .
                        elif .type == "text" then .text
                        else ""
                        end
                    ] | join(" ")
                else ""
                end
            elif .data != null then
                if (.data | type) == "string" then .data
                else ""
                end
            else ""
            end
        ) as $first_prompt |

        # Get timestamps
        (map(select(.timestamp != null)) | sort_by(.timestamp) | first // {} | .timestamp // "") as $created |
        (map(select(.timestamp != null)) | sort_by(.timestamp) | last // {} | .timestamp // "") as $modified |

        {
            session_id: $session_id,
            first_prompt: ($first_prompt | .[0:500]),
            message_count: $total,
            user_message_count: $user_count,
            assistant_message_count: $assistant_count,
            git_branch: $git_branch,
            created_at: $created,
            modified_at: $modified
        }
    ' "$jsonl_path" 2>/dev/null
}
