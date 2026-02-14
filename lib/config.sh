#!/usr/bin/env bash
# episodic-memory: configuration
# All paths and defaults, overridable via environment variables

EPISODIC_ROOT="${EPISODIC_ROOT:-$HOME/.claude/episodic-memory}"
EPISODIC_DB="${EPISODIC_DB:-$HOME/.claude/memory/episodic.db}"
EPISODIC_ARCHIVE_DIR="${EPISODIC_ARCHIVE_DIR:-$HOME/.claude/episodic-memory/archives}"
EPISODIC_CLAUDE_PROJECTS="${EPISODIC_CLAUDE_PROJECTS:-$HOME/.claude/projects}"

# Summary model: used for session summarization
# Default: Opus 4.5 with extended thinking. Override with any Anthropic model ID.
# Examples: claude-opus-4-6, claude-sonnet-4-5-20250929, claude-haiku-4-5-20251001
EPISODIC_SUMMARY_MODEL="${EPISODIC_SUMMARY_MODEL:-claude-opus-4-5-20251101}"

# Enable extended thinking for summary generation (true/false)
# When enabled, the model thinks through the session before summarizing.
# Only works with models that support extended thinking (Opus, Sonnet).
EPISODIC_SUMMARY_THINKING="${EPISODIC_SUMMARY_THINKING:-true}"

# Thinking budget in tokens (only used when EPISODIC_SUMMARY_THINKING=true)
EPISODIC_SUMMARY_THINKING_BUDGET="${EPISODIC_SUMMARY_THINKING_BUDGET:-10000}"

# Skill synthesis model and thinking budget
EPISODIC_OPUS_MODEL="${EPISODIC_OPUS_MODEL:-claude-opus-4-6}"

# Extended thinking budget for synthesis (tokens)
EPISODIC_SYNTHESIZE_THINKING_BUDGET="${EPISODIC_SYNTHESIZE_THINKING_BUDGET:-16000}"

# Max chars per transcript when loading for synthesis
EPISODIC_SYNTHESIZE_TRANSCRIPT_CHARS="${EPISODIC_SYNTHESIZE_TRANSCRIPT_CHARS:-30000}"

# Number of recent transcripts to load (full text) for synthesis
EPISODIC_SYNTHESIZE_TRANSCRIPT_COUNT="${EPISODIC_SYNTHESIZE_TRANSCRIPT_COUNT:-5}"

# Vision model for PDF/image OCR during document indexing
EPISODIC_INDEX_VISION_MODEL="${EPISODIC_INDEX_VISION_MODEL:-claude-haiku-4-5-20251001}"

# Deep dive model: used for comprehensive codebase analysis
EPISODIC_DEEP_DIVE_MODEL="${EPISODIC_DEEP_DIVE_MODEL:-claude-opus-4-6}"

# Thinking budget for deep-dive generation (tokens)
EPISODIC_DEEP_DIVE_THINKING_BUDGET="${EPISODIC_DEEP_DIVE_THINKING_BUDGET:-16000}"

# API timeout for deep-dive generation (seconds) — longer due to extended thinking
EPISODIC_DEEP_DIVE_TIMEOUT="${EPISODIC_DEEP_DIVE_TIMEOUT:-300}"

EPISODIC_SYNTHESIZE_EVERY="${EPISODIC_SYNTHESIZE_EVERY:-2}"

# Skill decay thresholds (days) for context injection
# Fresh: full content injected. Aging: one-line summary. Stale: omitted.
EPISODIC_SKILL_FRESH_DAYS="${EPISODIC_SKILL_FRESH_DAYS:-30}"
EPISODIC_SKILL_AGING_DAYS="${EPISODIC_SKILL_AGING_DAYS:-90}"

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

# Sanitize a name for safe use in file paths.
# Strips path separators, parent-dir references, leading dots, and non-safe chars.
# Only allows: alphanumeric, hyphens, underscores, dots (not leading).
# Usage: safe=$(episodic_sanitize_name "$untrusted_name")
episodic_sanitize_name() {
    local name="$1"
    # Remove path separators and parent directory references
    name="${name//\//}"
    name="${name//\.\./}"
    # Remove leading dots (hidden files)
    name="${name#.}"
    # Strip any remaining characters that aren't alphanumeric, hyphen, underscore, or dot
    name=$(printf '%s' "$name" | tr -cd 'a-zA-Z0-9._-')
    # Ensure non-empty
    if [[ -z "$name" ]]; then
        name="unnamed"
    fi
    printf '%s' "$name"
}

# Validate a string is a positive integer, return default if not.
# Usage: safe_int=$(episodic_validate_int "$value" "$default")
episodic_validate_int() {
    local value="$1"
    local default="${2:-0}"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$default"
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

# Derive project name from a Claude projects directory name like
# -home-user-projects-my-cool-app
#
# The encoding (/ -> -) is lossy: we can't distinguish path separators from
# hyphens in directory names. We resolve this by checking the actual filesystem:
# try the full reconstructed path first, then progressively strip leading
# components until we find a real directory and use its basename.
episodic_project_from_path() {
    local dir_name="$1"

    # Reconstruct candidate path: strip leading dash, replace - with /
    local candidate
    candidate=$(echo "$dir_name" | sed 's/^-/\//' | sed 's/-/\//g')

    # If the exact path exists, use its basename
    if [[ -d "$candidate" ]]; then
        basename "$candidate"
        return 0
    fi

    # Walk backwards to find the deepest existing parent, then take the
    # remainder as the project name. E.g. for /home/user/exp/claude-code:
    # /home/user/exp exists -> project = "claude-code" (with / re-joined as -)
    local parts
    IFS='/' read -ra parts <<< "$candidate"
    local i
    for (( i=${#parts[@]}-1; i>=1; i-- )); do
        local parent_path
        parent_path=$(printf '%s/' "${parts[@]:0:i}" | sed 's|/$||')
        if [[ -d "$parent_path" ]]; then
            local remaining="${parts[*]:i}"
            echo "${remaining// /-}"
            return 0
        fi
    done

    # Fallback: last component of the dash-separated name
    echo "$dir_name" | rev | cut -d'-' -f1 | rev
}

# Get the full project path from a directory name
# Note: this is a best-effort reconstruction since the encoding is lossy
# (dashes in directory names are indistinguishable from path separators).
episodic_project_path_from_dir() {
    local dir_name="$1"
    echo "$dir_name" | sed 's/^-/\//' | sed 's/-/\//g'
}

# Derive project name from CWD (preferred when CWD is available)
episodic_project_from_cwd() {
    basename "${CWD:-$(pwd)}"
}

# Knowledge repo configuration
EPISODIC_KNOWLEDGE_REPO="${EPISODIC_KNOWLEDGE_REPO:-}"
EPISODIC_KNOWLEDGE_DIR="${EPISODIC_KNOWLEDGE_DIR:-$HOME/.claude/knowledge}"

# Load local overrides from .env (safe key=value parsing only, no code execution)
if [[ -f "$EPISODIC_ROOT/.env" ]]; then
    while IFS='=' read -r key value; do
        # Skip comments and blank lines
        [[ -z "$key" || "$key" == \#* ]] && continue
        # Only allow known EPISODIC_ config variable names
        [[ "$key" =~ ^EPISODIC_[A-Z_]+$ ]] || continue
        # Strip surrounding quotes from value
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
        export "$key"="$value"
    done < "$EPISODIC_ROOT/.env"
fi
