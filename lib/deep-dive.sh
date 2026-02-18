#!/usr/bin/env bash
# episodic-memory: Deep dive — comprehensive codebase understanding
# Generates a structured analysis of what a project IS (architecture, patterns, stack).

_EPISODIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_EPISODIC_LIB_DIR/config.sh"

# Collect project context for deep-dive analysis
# Scans: tree structure, manifests, entry points, README, Dockerfiles, configs
# Usage: episodic_deep_dive_collect_context <project_path>
# Output: concatenated context string (truncated to 80K chars)
episodic_deep_dive_collect_context() {
    local project_path="$1"
    local context=""
    local max_chars=80000

    if [[ ! -d "$project_path" ]]; then
        episodic_log "ERROR" "Project path does not exist: $project_path"
        return 1
    fi

    # 1. Directory tree (depth 4, max 500 entries)
    context+="## Directory Structure"$'\n'
    context+="$(find "$project_path" -maxdepth 4 -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/__pycache__/*' -not -path '*/.venv/*' -not -path '*/target/*' -not -path '*/dist/*' -not -path '*/.next/*' -not -path '*/build/*' 2>/dev/null | head -500 | sed "s|^$project_path/||")"$'\n\n'

    # 2. Manifests / dependency files
    local manifests=(
        "package.json"
        "requirements.txt"
        "Pipfile"
        "pyproject.toml"
        "Cargo.toml"
        "go.mod"
        "Gemfile"
        "pom.xml"
        "build.gradle"
        "composer.json"
        "mix.exs"
        "Makefile"
    )

    for manifest in "${manifests[@]}"; do
        local mpath="$project_path/$manifest"
        if [[ -f "$mpath" ]]; then
            context+="## $manifest"$'\n'
            context+="$(head -100 "$mpath")"$'\n\n'
        fi
    done

    # 3. Entry points
    local entry_patterns=(
        "src/index.*"
        "src/main.*"
        "src/app.*"
        "main.*"
        "app.*"
        "index.*"
        "server.*"
        "cmd/main.go"
        "src/lib.rs"
    )

    for pattern in "${entry_patterns[@]}"; do
        # Use find to handle glob in pattern
        while IFS= read -r entry_file; do
            [[ -f "$entry_file" ]] || continue
            # Skip large/binary files
            local fsize
            if stat -f%z "$entry_file" &>/dev/null; then
                fsize=$(stat -f%z "$entry_file")
            else
                fsize=$(stat -c%s "$entry_file" 2>/dev/null || echo 0)
            fi
            [[ "$fsize" -gt 50000 ]] && continue
            local rel_path="${entry_file#$project_path/}"
            context+="## Entry Point: $rel_path"$'\n'
            context+="$(head -150 "$entry_file")"$'\n\n'
        done < <(find "$project_path" -maxdepth 3 -path "$project_path/$pattern" 2>/dev/null | head -5)
    done

    # 4. README and docs
    for readme in README.md README.rst README.txt README; do
        if [[ -f "$project_path/$readme" ]]; then
            context+="## $readme"$'\n'
            context+="$(head -200 "$project_path/$readme")"$'\n\n'
            break
        fi
    done

    # 5. CLAUDE.md (project-specific instructions)
    if [[ -f "$project_path/CLAUDE.md" ]]; then
        context+="## CLAUDE.md"$'\n'
        context+="$(cat "$project_path/CLAUDE.md")"$'\n\n'
    fi

    # 6. Docker / CI config
    for cfg in Dockerfile docker-compose.yml docker-compose.yaml .github/workflows/ci.yml .github/workflows/ci.yaml .gitlab-ci.yml Procfile; do
        if [[ -f "$project_path/$cfg" ]]; then
            context+="## $cfg"$'\n'
            context+="$(head -80 "$project_path/$cfg")"$'\n\n'
        fi
    done

    # 7. Config files
    for cfg in tsconfig.json .eslintrc.json .prettierrc webpack.config.js vite.config.ts next.config.js setup.py setup.cfg; do
        if [[ -f "$project_path/$cfg" ]]; then
            context+="## $cfg"$'\n'
            context+="$(head -50 "$project_path/$cfg")"$'\n\n'
        fi
    done

    # Truncate to max chars
    if [[ ${#context} -gt $max_chars ]]; then
        context="${context:0:$max_chars}"
        context+=$'\n\n[... truncated at 80K chars ...]'
    fi

    echo "$context"
}

# Generate a deep-dive document via Opus API with extended thinking
# Usage: episodic_deep_dive_generate <project> <project_path> [--refresh]
# Output: markdown deep-dive document
episodic_deep_dive_generate() {
    local project="$1"
    local project_path="$2"
    local refresh="${3:-}"

    episodic_require_api_key || return 1

    local context
    context=$(episodic_deep_dive_collect_context "$project_path")
    if [[ -z "$context" ]]; then
        episodic_log "ERROR" "No context collected for $project"
        return 1
    fi

    # Sanitize context: strip control chars that break JSON encoding
    context=$(printf '%s' "$context" | tr -d '\000-\010\013\014\016-\037')

    local system_prompt='You are a senior software architect analyzing a codebase. Produce a comprehensive, structured deep-dive document in Markdown.

Your analysis MUST cover ALL of these sections (skip a section only if truly not applicable):

# <Project Name> — Deep Dive

## Overview
What this project does, its purpose, who uses it. 2-3 sentences.

## Tech Stack
Languages, frameworks, major libraries, runtime. Bullet list.

## Architecture
High-level architecture: monolith vs microservices, data flow, key components and how they interact. Include a simple ASCII diagram if helpful.

## Directory Structure
Explain the layout — what lives where and why. Not a raw tree, but a narrated guide.

## Entry Points
Where execution starts. Main files, CLI entry points, HTTP handlers, event handlers.

## Key Patterns
Design patterns, conventions, idioms used throughout the codebase. Anti-patterns to be aware of.

## Dependencies
Critical external dependencies and what they do. Any vendored or unusual deps.

## Deployment
How this gets deployed. CI/CD, infrastructure, environments.

## Development Workflow
How to run locally, test, build. Common dev tasks.

## Gotchas
Non-obvious things a new developer would trip over. Known issues, tech debt, quirks.

Rules:
- Be specific and concrete — reference actual file paths, function names, config values
- This is a reference document, not a tutorial. Be dense with information.
- Use code blocks for file paths, commands, and code snippets
- Keep total length between 1500-4000 words'

    local user_prompt
    if [[ "$refresh" == "--refresh" ]] && episodic_deep_dive_exists "$project"; then
        local previous
        previous=$(episodic_deep_dive_read "$project")
        user_prompt="Analyze this codebase context and UPDATE the existing deep-dive document. Focus on what has changed or been added since the last analysis. Add a '## Changes Since Last Analysis' section at the top.

## Previous Deep Dive
$previous

## Current Codebase Context
$context

Generate the updated deep-dive document."
    else
        user_prompt="Analyze this codebase context and generate a comprehensive deep-dive document.

## Codebase Context
$context

Generate the deep-dive document."
    fi

    local model="$EPISODIC_DEEP_DIVE_MODEL"
    local thinking_budget="$EPISODIC_DEEP_DIVE_THINKING_BUDGET"
    local timeout="$EPISODIC_DEEP_DIVE_TIMEOUT"

    local request_json
    request_json=$(jq -n \
        --arg model "$model" \
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
        episodic_log "ERROR" "Failed to build request JSON for deep-dive"
        return 1
    fi

    episodic_log "INFO" "Calling $model (thinking=$thinking_budget) for deep-dive of $project..."

    local response
    response=$(curl -s --max-time "$timeout" \
        "$EPISODIC_API_BASE_URL/v1/messages" \
        -H "x-api-key: $EPISODIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$request_json" 2>/dev/null)

    if [[ $? -ne 0 || -z "$response" ]]; then
        episodic_log "ERROR" "Deep-dive API call failed (timeout or network error)"
        return 1
    fi

    # Check for API errors
    local error_type
    error_type=$(echo "$response" | jq -r '.error.type // empty' 2>/dev/null)
    if [[ -n "$error_type" ]]; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.error.message // "unknown error"' 2>/dev/null)
        episodic_log "ERROR" "Deep-dive API error ($model): $error_type - $error_msg"
        return 1
    fi

    # Extract text content (handle thinking response)
    local content
    content=$(echo "$response" | jq -r '[.content[] | select(.type == "text")] | last | .text // empty' 2>/dev/null)

    if [[ -z "$content" ]]; then
        episodic_log "ERROR" "No text content in deep-dive API response"
        return 1
    fi

    # Log usage stats
    local input_tokens output_tokens
    input_tokens=$(echo "$response" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
    output_tokens=$(echo "$response" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
    episodic_log "INFO" "Deep-dive API usage: ${input_tokens} in / ${output_tokens} out ($model)"

    echo "$content"
}

# Write deep-dive document to knowledge directory with YAML frontmatter
# Usage: episodic_deep_dive_write <project> <content> <project_path> <model>
episodic_deep_dive_write() {
    local project="$1"
    local content="$2"
    local project_path="$3"
    local model="${4:-$EPISODIC_DEEP_DIVE_MODEL}"

    # Sanitize project name to prevent path traversal
    project=$(episodic_sanitize_name "$project")

    local dir="$EPISODIC_KNOWLEDGE_DIR/$project"
    mkdir -p -m 700 "$dir"

    local generated
    generated=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local target="$dir/deep-dive.md"

    # Refuse to write to symlinks
    if [[ -L "$target" ]]; then
        episodic_log "ERROR" "Refusing to write to symlink: $target"
        return 1
    fi

    # Use printf to avoid shell expansion of $content (which comes from LLM API)
    {
        printf '%s\n' "---"
        printf 'type: deep-dive\n'
        printf 'project: %s\n' "$project"
        printf 'generated: %s\n' "$generated"
        printf 'model: %s\n' "$model"
        printf 'project_path: %s\n' "$project_path"
        printf '%s\n\n' "---"
        printf '%s\n' "$content"
    } > "$target"

    episodic_log "INFO" "Wrote deep-dive for $project to $dir/deep-dive.md"
}

# Check if a deep-dive exists for a project
# Usage: episodic_deep_dive_exists <project>
# Returns: 0 if exists, 1 if not
episodic_deep_dive_exists() {
    local project="$1"
    project=$(episodic_sanitize_name "$project")
    [[ -f "$EPISODIC_KNOWLEDGE_DIR/$project/deep-dive.md" ]]
}

# Read deep-dive content, stripping YAML frontmatter
# Usage: episodic_deep_dive_read <project>
# Output: body of deep-dive.md without frontmatter
episodic_deep_dive_read() {
    local project="$1"
    project=$(episodic_sanitize_name "$project")
    local file="$EPISODIC_KNOWLEDGE_DIR/$project/deep-dive.md"

    if [[ ! -f "$file" ]]; then
        episodic_log "WARN" "No deep-dive found for $project"
        return 1
    fi

    # Strip YAML frontmatter (everything between first two --- lines)
    awk 'BEGIN{f=0} /^---$/{f++; next} f>=2' "$file"
}
