#!/usr/bin/env bash
# episodic-memory: Knowledge repo git operations
# Manages a Git-backed per-project knowledge store for skills and context.

_EPISODIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_EPISODIC_LIB_DIR/config.sh"

# Check if knowledge repo is configured (has a remote URL set)
episodic_knowledge_is_configured() {
    [[ -n "${EPISODIC_KNOWLEDGE_REPO:-}" ]] && [[ -d "$EPISODIC_KNOWLEDGE_DIR/.git" ]]
}

# Initialize (clone) the knowledge repo from a remote URL
# Usage: episodic_knowledge_init <repo_url>
episodic_knowledge_init() {
    local repo_url="${1:-$EPISODIC_KNOWLEDGE_REPO}"

    if [[ -z "$repo_url" ]]; then
        episodic_log "ERROR" "No knowledge repo URL provided"
        return 1
    fi

    if [[ -d "$EPISODIC_KNOWLEDGE_DIR/.git" ]]; then
        episodic_log "INFO" "Knowledge repo already exists at $EPISODIC_KNOWLEDGE_DIR"
        # Verify remote matches
        local current_remote
        current_remote=$(git -C "$EPISODIC_KNOWLEDGE_DIR" remote get-url origin 2>/dev/null || true)
        if [[ "$current_remote" != "$repo_url" && -n "$current_remote" ]]; then
            episodic_log "WARN" "Knowledge repo remote mismatch: $current_remote != $repo_url"
        fi
        return 0
    fi

    mkdir -p "$(dirname "$EPISODIC_KNOWLEDGE_DIR")"
    episodic_log "INFO" "Cloning knowledge repo from $repo_url"

    if ! git clone "$repo_url" "$EPISODIC_KNOWLEDGE_DIR" 2>/dev/null; then
        episodic_log "ERROR" "Failed to clone knowledge repo from $repo_url"
        return 1
    fi

    # Create .episodic-config.json if it doesn't exist
    if [[ ! -f "$EPISODIC_KNOWLEDGE_DIR/.episodic-config.json" ]]; then
        printf '{"version":1,"projects":[]}\n' > "$EPISODIC_KNOWLEDGE_DIR/.episodic-config.json"
        git -C "$EPISODIC_KNOWLEDGE_DIR" add .episodic-config.json
        git -C "$EPISODIC_KNOWLEDGE_DIR" commit -m "Initialize episodic knowledge repo" 2>/dev/null || true
    fi

    export EPISODIC_KNOWLEDGE_REPO="$repo_url"
    episodic_log "INFO" "Knowledge repo initialized at $EPISODIC_KNOWLEDGE_DIR"
}

# Ensure a project directory exists in the knowledge repo
# Creates <project>/skills/ structure
# Usage: episodic_knowledge_ensure_project <project_name>
episodic_knowledge_ensure_project() {
    local project="$1"

    if [[ -z "$project" ]]; then
        episodic_log "ERROR" "No project name provided"
        return 1
    fi

    local project_dir="$EPISODIC_KNOWLEDGE_DIR/$project"
    local skills_dir="$project_dir/skills"

    if [[ ! -d "$skills_dir" ]]; then
        mkdir -p "$skills_dir"
        episodic_log "INFO" "Created project directory: $project_dir/skills/"
    fi

    echo "$project_dir"
}

# Write a skill file to the knowledge repo
# Usage: episodic_knowledge_write_skill <project> <skill_name> <content>
episodic_knowledge_write_skill() {
    local project="$1"
    local skill_name="$2"
    local content="$3"

    if [[ -z "$project" || -z "$skill_name" || -z "$content" ]]; then
        episodic_log "ERROR" "Missing arguments to write_skill"
        return 1
    fi

    local project_dir
    project_dir=$(episodic_knowledge_ensure_project "$project")
    local skill_file="$project_dir/skills/${skill_name}.md"

    printf '%s\n' "$content" > "$skill_file"
    episodic_log "INFO" "Wrote skill: $skill_file"
}

# Read a skill file from the knowledge repo
# Usage: episodic_knowledge_read_skill <project> <skill_name>
episodic_knowledge_read_skill() {
    local project="$1"
    local skill_name="$2"

    local skill_file="$EPISODIC_KNOWLEDGE_DIR/$project/skills/${skill_name}.md"

    if [[ ! -f "$skill_file" ]]; then
        episodic_log "WARN" "Skill not found: $skill_file"
        return 1
    fi

    cat "$skill_file"
}

# List all skills for a project
# Usage: episodic_knowledge_list_skills <project>
# Output: one skill name per line (without .md extension)
episodic_knowledge_list_skills() {
    local project="$1"
    local skills_dir="$EPISODIC_KNOWLEDGE_DIR/$project/skills"

    if [[ ! -d "$skills_dir" ]]; then
        return 0
    fi

    local skill_file
    for skill_file in "$skills_dir"/*.md; do
        [[ -f "$skill_file" ]] || continue
        basename "$skill_file" .md
    done
}

# Write the project context file
# Usage: episodic_knowledge_write_context <project> <content>
episodic_knowledge_write_context() {
    local project="$1"
    local content="$2"

    local project_dir
    project_dir=$(episodic_knowledge_ensure_project "$project")
    local context_file="$project_dir/context.md"

    printf '%s\n' "$content" > "$context_file"
    episodic_log "INFO" "Wrote context: $context_file"
}

# Read the project context file
# Usage: episodic_knowledge_read_context <project>
episodic_knowledge_read_context() {
    local project="$1"
    local context_file="$EPISODIC_KNOWLEDGE_DIR/$project/context.md"

    if [[ ! -f "$context_file" ]]; then
        return 1
    fi

    cat "$context_file"
}

# Commit and push all changes in the knowledge repo
# Usage: episodic_knowledge_push [commit_message]
episodic_knowledge_push() {
    local message="${1:-Update knowledge from episodic-memory}"

    if ! episodic_knowledge_is_configured; then
        episodic_log "WARN" "Knowledge repo not configured, skipping push"
        return 0
    fi

    local repo="$EPISODIC_KNOWLEDGE_DIR"

    # Stage all changes
    git -C "$repo" add -A 2>/dev/null

    # Check if there are changes to commit
    if git -C "$repo" diff --cached --quiet 2>/dev/null; then
        episodic_log "INFO" "No knowledge changes to commit"
        return 0
    fi

    # Commit
    if ! git -C "$repo" commit -m "$message" 2>/dev/null; then
        episodic_log "ERROR" "Failed to commit knowledge changes"
        return 1
    fi

    # Push
    if ! git -C "$repo" push 2>/dev/null; then
        episodic_log "WARN" "Failed to push knowledge repo (offline?)"
        return 1
    fi

    episodic_log "INFO" "Pushed knowledge changes: $message"
}

# Pull latest changes from remote
# Usage: episodic_knowledge_pull
episodic_knowledge_pull() {
    if ! episodic_knowledge_is_configured; then
        episodic_log "WARN" "Knowledge repo not configured, skipping pull"
        return 0
    fi

    local repo="$EPISODIC_KNOWLEDGE_DIR"

    if ! git -C "$repo" pull --rebase --quiet 2>/dev/null; then
        episodic_log "WARN" "Failed to pull knowledge repo (offline or conflict?)"
        return 1
    fi

    episodic_log "INFO" "Pulled latest knowledge"
}

# Sync: pull then push
# Usage: episodic_knowledge_sync [pull|push]
episodic_knowledge_sync() {
    local mode="${1:-both}"

    case "$mode" in
        pull)
            episodic_knowledge_pull
            ;;
        push)
            episodic_knowledge_push
            ;;
        both|*)
            episodic_knowledge_pull
            episodic_knowledge_push
            ;;
    esac
}
