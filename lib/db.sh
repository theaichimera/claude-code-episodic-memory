#!/usr/bin/env bash
# episodic-memory: SQLite database helpers

_EPISODIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_EPISODIC_LIB_DIR/config.sh"

# Escape a string for safe interpolation into SQL single-quoted literals.
# Doubles any single quotes: O'Brien -> O''Brien
# Usage: escaped=$(episodic_sql_escape "$value")
episodic_sql_escape() {
    printf '%s' "${1//\'/\'\'}"
}

# Escape a user query for safe use in FTS5 MATCH expressions.
# Wraps each token in double quotes so FTS5 operators (OR, AND, NOT,
# NEAR, etc.) and special characters (*, :, etc.) are treated as literals.
# Multi-word queries use implicit AND (each word quoted separately).
# Usage: safe_query=$(episodic_fts5_escape "$user_input")
episodic_fts5_escape() {
    local input="$1"
    # Remove characters that are problematic even inside FTS5 double quotes
    # (unmatched parens, braces, brackets)
    input="${input//(/}"
    input="${input//)/}"
    input="${input//{/}"
    input="${input//\}/}"
    # Quote each whitespace-separated token individually so FTS5 operators
    # like OR, AND, NOT, NEAR are treated as search terms, and * : ^ are
    # neutralized. Embedded double quotes are doubled per FTS5 convention.
    local result=""
    local token
    local old_glob
    old_glob=$(shopt -p noglob 2>/dev/null || true)
    set -f  # disable glob expansion for word splitting
    for token in $input; do
        token="${token//\"/\"\"}"
        result="${result:+$result }\"$token\""
    done
    eval "$old_glob" 2>/dev/null || set +f  # restore
    printf '%s' "$result"
}

# SQLite busy timeout in milliseconds.
# Multiple background processes (archive, index, synthesis) write concurrently.
EPISODIC_BUSY_TIMEOUT="${EPISODIC_BUSY_TIMEOUT:-5000}"

# Execute a SQL statement with busy_timeout set.
# Usage: episodic_db_exec <sql> [db_path]
# For queries returning data, pipe through this or use episodic_db_query.
episodic_db_exec() {
    local sql="$1"
    local db="${2:-$EPISODIC_DB}"
    sqlite3 -cmd ".timeout ${EPISODIC_BUSY_TIMEOUT}" "$db" "${sql}"
}

# Execute a SQL statement and return JSON output with busy_timeout set.
# Usage: episodic_db_query_json <sql> [db_path]
episodic_db_query_json() {
    local sql="$1"
    local db="${2:-$EPISODIC_DB}"
    sqlite3 -json -cmd ".timeout ${EPISODIC_BUSY_TIMEOUT}" "$db" "${sql}"
}

# Execute a multi-statement SQL block (heredoc) with busy_timeout set.
# Usage: episodic_db_exec_multi <db_path> <<'SQL' ... SQL
episodic_db_exec_multi() {
    local db="${1:-$EPISODIC_DB}"
    # Prepend .timeout dot-command to the piped SQL (no output, unlike PRAGMA)
    { echo ".timeout ${EPISODIC_BUSY_TIMEOUT}"; cat; } | sqlite3 "$db"
}

# Initialize the database schema (idempotent)
episodic_db_init() {
    local db="${1:-$EPISODIC_DB}"
    mkdir -p "$(dirname "$db")"

    episodic_db_exec_multi "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    project TEXT NOT NULL,
    project_path TEXT,
    archive_path TEXT,
    source_path TEXT,
    first_prompt TEXT,
    message_count INTEGER,
    user_message_count INTEGER,
    assistant_message_count INTEGER,
    git_branch TEXT,
    created_at TEXT NOT NULL,
    modified_at TEXT,
    archived_at TEXT,
    duration_minutes INTEGER
);

CREATE TABLE IF NOT EXISTS summaries (
    session_id TEXT PRIMARY KEY REFERENCES sessions(id),
    topics TEXT,
    decisions TEXT,
    dead_ends TEXT,
    artifacts_created TEXT,
    key_insights TEXT,
    summary TEXT,
    generated_at TEXT,
    model TEXT
);

CREATE TABLE IF NOT EXISTS archive_log (
    session_id TEXT PRIMARY KEY,
    archived_at TEXT,
    summary_generated_at TEXT,
    status TEXT DEFAULT 'pending'
);

CREATE INDEX IF NOT EXISTS idx_sessions_project_created ON sessions(project, created_at DESC);
SQL

    # FTS5 table needs special handling since CREATE VIRTUAL TABLE IF NOT EXISTS
    # is supported in modern SQLite but let's be safe
    local fts_exists
    fts_exists=$(episodic_db_exec "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='sessions_fts';" "$db")
    if [[ "$fts_exists" == "0" ]]; then
        episodic_db_exec_multi "$db" <<'SQL'
CREATE VIRTUAL TABLE sessions_fts USING fts5(
    session_id UNINDEXED,
    project,
    topics,
    decisions,
    dead_ends,
    key_insights,
    summary,
    first_prompt,
    tokenize='porter unicode61'
);
SQL
    fi

    # Documents table for knowledge repo file indexing
    episodic_db_exec_multi "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    project TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_name TEXT NOT NULL,
    title TEXT,
    file_type TEXT,
    file_size INTEGER,
    content_hash TEXT,
    extracted_text TEXT,
    extraction_method TEXT,
    indexed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS synthesis_log (
    project TEXT NOT NULL,
    synthesized_at TEXT NOT NULL,
    session_count INTEGER,
    skills_created INTEGER DEFAULT 0,
    skills_updated INTEGER DEFAULT 0,
    model TEXT,
    PRIMARY KEY(project, synthesized_at)
);

CREATE INDEX IF NOT EXISTS idx_documents_project ON documents(project);
CREATE INDEX IF NOT EXISTS idx_documents_hash ON documents(content_hash);
SQL

    # Documents FTS5 table
    local docs_fts_exists
    docs_fts_exists=$(episodic_db_exec "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='documents_fts';" "$db")
    if [[ "$docs_fts_exists" == "0" ]]; then
        episodic_db_exec_multi "$db" <<'SQL'
CREATE VIRTUAL TABLE documents_fts USING fts5(
    doc_id UNINDEXED,
    project,
    file_name,
    title,
    extracted_text,
    tokenize='porter unicode61'
);
SQL
    fi

    episodic_log "INFO" "Database initialized at $db"
}

# Insert a session record
episodic_db_insert_session() {
    local db="$EPISODIC_DB"
    local id="$1" project="$2" project_path="$3" archive_path="$4" source_path="$5"
    local first_prompt="$6" message_count="$7" user_count="$8" assistant_count="$9"
    local git_branch="${10}" created_at="${11}" modified_at="${12}" duration="${13}"

    id=$(episodic_sql_escape "$id")
    project=$(episodic_sql_escape "$project")
    project_path=$(episodic_sql_escape "$project_path")
    archive_path=$(episodic_sql_escape "$archive_path")
    source_path=$(episodic_sql_escape "$source_path")
    first_prompt=$(episodic_sql_escape "$first_prompt")
    git_branch=$(episodic_sql_escape "$git_branch")
    created_at=$(episodic_sql_escape "$created_at")
    modified_at=$(episodic_sql_escape "$modified_at")

    # Validate numeric fields to prevent SQL injection via exec_multi (stdin)
    [[ "$message_count" =~ ^[0-9]+$ ]] || message_count=0
    [[ "$user_count" =~ ^[0-9]+$ ]] || user_count=0
    [[ "$assistant_count" =~ ^[0-9]+$ ]] || assistant_count=0
    [[ "$duration" =~ ^[0-9]+$ ]] || duration=0

    episodic_db_exec_multi "$db" <<SQL
INSERT OR REPLACE INTO sessions (
    id, project, project_path, archive_path, source_path,
    first_prompt, message_count, user_message_count, assistant_message_count,
    git_branch, created_at, modified_at, archived_at, duration_minutes
) VALUES (
    '$id', '$project', '$project_path', '$archive_path', '$source_path',
    '$first_prompt', $message_count, $user_count, $assistant_count,
    '$git_branch', '$created_at', '$modified_at', datetime('now'), $duration
);
SQL
}

# Insert a summary record and update FTS
episodic_db_insert_summary() {
    local db="$EPISODIC_DB"
    local session_id="$1"
    local summary_json="$2"
    local model="$3"

    # Extract fields from JSON
    local topics decisions dead_ends artifacts key_insights summary_text
    topics=$(echo "$summary_json" | jq -r '.topics // [] | join(", ")')
    decisions=$(echo "$summary_json" | jq -r '.decisions // [] | join(", ")')
    dead_ends=$(echo "$summary_json" | jq -r '.dead_ends // [] | join(", ")')
    artifacts=$(echo "$summary_json" | jq -r '.artifacts_created // [] | join(", ")')
    key_insights=$(echo "$summary_json" | jq -r '.key_insights // [] | join(", ")')
    summary_text=$(echo "$summary_json" | jq -r '.summary // ""')

    # Store raw JSON arrays in summaries table
    local topics_json decisions_json dead_ends_json artifacts_json insights_json
    topics_json=$(echo "$summary_json" | jq -c '.topics // []')
    decisions_json=$(echo "$summary_json" | jq -c '.decisions // []')
    dead_ends_json=$(echo "$summary_json" | jq -c '.dead_ends // []')
    artifacts_json=$(echo "$summary_json" | jq -c '.artifacts_created // []')
    insights_json=$(echo "$summary_json" | jq -c '.key_insights // []')

    topics_json=$(episodic_sql_escape "$topics_json")
    decisions_json=$(episodic_sql_escape "$decisions_json")
    dead_ends_json=$(episodic_sql_escape "$dead_ends_json")
    artifacts_json=$(episodic_sql_escape "$artifacts_json")
    insights_json=$(episodic_sql_escape "$insights_json")
    summary_text=$(episodic_sql_escape "$summary_text")
    topics=$(episodic_sql_escape "$topics")
    decisions=$(episodic_sql_escape "$decisions")
    dead_ends=$(episodic_sql_escape "$dead_ends")
    key_insights=$(episodic_sql_escape "$key_insights")

    # Escape session_id for SQL interpolation
    local safe_session_id
    safe_session_id=$(episodic_sql_escape "$session_id")

    # Get first_prompt and project from sessions table
    local first_prompt project
    first_prompt=$(episodic_db_exec "SELECT first_prompt FROM sessions WHERE id='$safe_session_id';" "$db")
    project=$(episodic_db_exec "SELECT project FROM sessions WHERE id='$safe_session_id';" "$db")
    first_prompt=$(episodic_sql_escape "$first_prompt")
    project=$(episodic_sql_escape "$project")

    # Write SQL to temp file to avoid bash variable size limits.
    # Summary text and first_prompt can be substantial; writing through
    # printf to a file bypasses heredoc expansion limitations.
    local sql_file
    sql_file=$(mktemp)
    trap 'rm -f "$sql_file"' RETURN

    {
        printf ".timeout ${EPISODIC_BUSY_TIMEOUT}\n"
        printf "BEGIN;\n"
        printf "INSERT OR REPLACE INTO summaries (\n"
        printf "    session_id, topics, decisions, dead_ends, artifacts_created,\n"
        printf "    key_insights, summary, generated_at, model\n"
        printf ") VALUES (\n"
        printf "    '%s', '%s', '%s', '%s',\n" "$safe_session_id" "$topics_json" "$decisions_json" "$dead_ends_json"
        printf "    '%s', '%s', '%s', datetime('now'), '%s'\n" "$artifacts_json" "$insights_json" "$summary_text" "$(episodic_sql_escape "$model")"
        printf ");\n\n"
        printf "DELETE FROM sessions_fts WHERE session_id = '%s';\n" "$safe_session_id"
        printf "INSERT INTO sessions_fts (\n"
        printf "    session_id, project, topics, decisions, dead_ends,\n"
        printf "    key_insights, summary, first_prompt\n"
        printf ") VALUES (\n"
        printf "    '%s', '%s', '%s', '%s', '%s',\n" "$safe_session_id" "$project" "$topics" "$decisions" "$dead_ends"
        printf "    '%s', '%s', '%s'\n" "$key_insights" "$summary_text" "$first_prompt"
        printf ");\n"
        printf "COMMIT;\n"
    } > "$sql_file"

    sqlite3 "$db" < "$sql_file"
}

# Update archive log
episodic_db_update_log() {
    local db="$EPISODIC_DB"
    local session_id="$1"
    local status="$2"

    session_id=$(episodic_sql_escape "$session_id")
    status=$(episodic_sql_escape "$status")

    episodic_db_exec_multi "$db" <<SQL
INSERT OR REPLACE INTO archive_log (session_id, archived_at, status)
VALUES ('$session_id', datetime('now'), '$status');
SQL
}

# Search sessions using FTS5
episodic_db_search() {
    local db="$EPISODIC_DB"
    local query="$1"
    local limit="${2:-10}"

    # FTS5-escape first (wraps in double quotes), then SQL-escape (doubles single quotes)
    query=$(episodic_fts5_escape "$query")
    query=$(episodic_sql_escape "$query")

    episodic_db_query_json "
SELECT
    s.id,
    s.project,
    s.created_at,
    s.first_prompt,
    s.git_branch,
    s.duration_minutes,
    sum.summary,
    sum.topics,
    sum.decisions,
    sum.key_insights,
    sum.dead_ends,
    rank
FROM sessions_fts fts
JOIN sessions s ON s.id = fts.session_id
JOIN summaries sum ON sum.session_id = fts.session_id
WHERE sessions_fts MATCH '$query'
ORDER BY rank
LIMIT $limit;" "$db"
}

# Get recent sessions for a project
episodic_db_recent() {
    local db="$EPISODIC_DB"
    local project="$1"
    local limit="${2:-$EPISODIC_CONTEXT_COUNT}"

    project=$(episodic_sql_escape "$project")

    episodic_db_query_json "
SELECT
    s.id,
    s.project,
    s.created_at,
    s.first_prompt,
    s.git_branch,
    s.duration_minutes,
    sum.summary,
    sum.topics,
    sum.decisions,
    sum.key_insights
FROM sessions s
JOIN summaries sum ON sum.session_id = s.id
WHERE s.project = '$project'
ORDER BY s.created_at DESC
LIMIT $limit;" "$db"
}

# Get session count
episodic_db_count() {
    local db="$EPISODIC_DB"
    episodic_db_exec "SELECT count(*) FROM sessions;" "$db"
}

# Check if a session is already fully archived (has a completed summary or
# is intentionally without one). Sessions with 'pending' or 'summary_failed'
# status are considered NOT archived so they will be retried automatically.
episodic_db_is_archived() {
    local db="$EPISODIC_DB"
    local session_id="$1"
    local safe_id
    safe_id=$(episodic_sql_escape "$session_id")
    local count
    count=$(episodic_db_exec "SELECT count(*) FROM archive_log WHERE session_id='$safe_id' AND status IN ('complete','too_short','no_summary');" "$db")
    [[ "$count" -gt 0 ]]
}

# Count sessions since last synthesis for a project
episodic_db_sessions_since_synthesis() {
    local db="$EPISODIC_DB"
    local project="$1"

    project=$(episodic_sql_escape "$project")

    local last_synth
    last_synth=$(episodic_db_exec "SELECT MAX(synthesized_at) FROM synthesis_log WHERE project='$project';" "$db")

    if [[ -z "$last_synth" || "$last_synth" == "" ]]; then
        # Never synthesized — count all sessions
        episodic_db_exec "SELECT count(*) FROM sessions WHERE project='$project';" "$db"
    else
        episodic_db_exec "SELECT count(*) FROM sessions WHERE project='$project' AND archived_at > '$last_synth';" "$db"
    fi
}

# Log a synthesis run
episodic_db_log_synthesis() {
    local db="$EPISODIC_DB"
    local project="$1"
    local session_count="$2"
    local skills_created="${3:-0}"
    local skills_updated="${4:-0}"
    local model="${5:-$EPISODIC_OPUS_MODEL}"

    project=$(episodic_sql_escape "$project")

    episodic_db_exec_multi "$db" <<SQL
INSERT INTO synthesis_log (project, synthesized_at, session_count, skills_created, skills_updated, model)
VALUES ('$project', datetime('now'), $session_count, $skills_created, $skills_updated, '$model');
SQL
}
