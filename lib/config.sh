#!/usr/bin/env bash
# episodic-memory: configuration
# All paths and defaults, overridable via environment variables

EPISODIC_ROOT="${EPISODIC_ROOT:-$HOME/.claude/episodic-memory}"
EPISODIC_DB="${EPISODIC_DB:-$HOME/.claude/memory/episodic.db}"
EPISODIC_ARCHIVE_DIR="${EPISODIC_ARCHIVE_DIR:-$HOME/.claude/episodic-memory/archives}"
EPISODIC_CLAUDE_PROJECTS="${EPISODIC_CLAUDE_PROJECTS:-$HOME/.claude/projects}"

# Summary model: used for session summarization
# Default: Opus 4.6. Override with any Anthropic model ID.
# Examples: claude-opus-4-5-20251101, claude-sonnet-4-5-20250929, claude-haiku-4-5-20251001
EPISODIC_SUMMARY_MODEL="${EPISODIC_SUMMARY_MODEL:-claude-opus-4-5-20251101}"

# Enable extended thinking for summary generation (true/false)
# When enabled, the model thinks through the session before summarizing.
# Only works with models that support extended thinking (Opus, Sonnet).
EPISODIC_SUMMARY_THINKING="${EPISODIC_SUMMARY_THINKING:-true}"

# Thinking budget in tokens (only used when EPISODIC_SUMMARY_THINKING=true)
EPISODIC_SUMMARY_THINKING_BUDGET="${EPISODIC_SUMMARY_THINKING_BUDGET:-10000}"

# Skill synthesis model
EPISODIC_OPUS_MODEL="${EPISODIC_OPUS_MODEL:-claude-opus-4-5-20251101}"

# Vision model for PDF/image OCR during document indexing
EPISODIC_INDEX_VISION_MODEL="${EPISODIC_INDEX_VISION_MODEL:-claude-haiku-4-5-20251001}"

EPISODIC_SYNTHESIZE_EVERY="${EPISODIC_SYNTHESIZE_EVERY:-10}"

EPISODIC_CONTEXT_COUNT="${EPISODIC_CONTEXT_COUNT:-3}"
EPISODIC_MAX_EXTRACT_CHARS="${EPISODIC_MAX_EXTRACT_CHARS:-100000}"
EPISODIC_LOG="${EPISODIC_LOG:-$HOME/.claude/memory/episodic.log}"

# Ensure the API key is available
episodic_require_api_key() {
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        echo "ERROR: ANTHROPIC_API_KEY not set" >&2
        return 1
    fi
}

# Log a message with timestamp
episodic_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    mkdir -p "$(dirname "$EPISODIC_LOG")"
    echo "[$ts] [$level] $msg" >> "$EPISODIC_LOG"
    if [[ "$level" == "ERROR" ]]; then
        echo "ERROR: $msg" >&2
    fi
}

# Derive project name from a project path like -Users-jane-projects-myapp
episodic_project_from_path() {
    local dir_name="$1"
    # Strip leading dash, split on dashes, take the last segment(s)
    # e.g. -Users-jane-projects-myapp -> myapp
    echo "$dir_name" | sed 's/^-//' | rev | cut -d'-' -f1 | rev
}

# Get the full project path from a directory name
episodic_project_path_from_dir() {
    local dir_name="$1"
    echo "$dir_name" | sed 's/^-//' | tr '-' '/'
}

# Knowledge repo configuration
EPISODIC_KNOWLEDGE_REPO="${EPISODIC_KNOWLEDGE_REPO:-}"
EPISODIC_KNOWLEDGE_DIR="${EPISODIC_KNOWLEDGE_DIR:-$HOME/.claude/knowledge}"

# Load local overrides
if [[ -f "$EPISODIC_ROOT/.env" ]]; then
    source "$EPISODIC_ROOT/.env"
fi
