#!/usr/bin/env bash
# episodic-memory: SQLite database helpers

_EPISODIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_EPISODIC_LIB_DIR/config.sh"

# Initialize the database schema (idempotent)
episodic_db_init() {
    local db="${1:-$EPISODIC_DB}"
    mkdir -p "$(dirname "$db")"

    sqlite3 "$db" <<'SQL'
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
    fts_exists=$(sqlite3 "$db" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='sessions_fts';")
    if [[ "$fts_exists" == "0" ]]; then
        sqlite3 "$db" <<'SQL'
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
    sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    project TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_name TEXT NOT NULL,
    file_type TEXT,
    content_hash TEXT,
    extracted_text TEXT,
    title TEXT,
    indexed_at TEXT,
    file_size INTEGER,
    extraction_method TEXT
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
    docs_fts_exists=$(sqlite3 "$db" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='documents_fts';")
    if [[ "$docs_fts_exists" == "0" ]]; then
        sqlite3 "$db" <<'SQL'
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

    # Escape single quotes in first_prompt
    first_prompt="${first_prompt//\'/\'\'}"

    sqlite3 "$db" <<SQL
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

    # Escape single quotes
    topics_json="${topics_json//\'/\'\'}"
    decisions_json="${decisions_json//\'/\'\'}"
    dead_ends_json="${dead_ends_json//\'/\'\'}"
    artifacts_json="${artifacts_json//\'/\'\'}"
    insights_json="${insights_json//\'/\'\'}"
    summary_text="${summary_text//\'/\'\'}"
    topics="${topics//\'/\'\'}"
    decisions="${decisions//\'/\'\'}"
    dead_ends="${dead_ends//\'/\'\'}"
    key_insights="${key_insights//\'/\'\'}"

    # Get first_prompt and project from sessions table
    local first_prompt project
    first_prompt=$(sqlite3 "$db" "SELECT first_prompt FROM sessions WHERE id='$session_id';")
    project=$(sqlite3 "$db" "SELECT project FROM sessions WHERE id='$session_id';")
    first_prompt="${first_prompt//\'/\'\'}"
    project="${project//\'/\'\'}"

    sqlite3 "$db" <<SQL
INSERT OR REPLACE INTO summaries (
    session_id, topics, decisions, dead_ends, artifacts_created,
    key_insights, summary, generated_at, model
) VALUES (
    '$session_id', '$topics_json', '$decisions_json', '$dead_ends_json',
    '$artifacts_json', '$insights_json', '$summary_text', datetime('now'), '$model'
);

DELETE FROM sessions_fts WHERE session_id = '$session_id';
INSERT INTO sessions_fts (
    session_id, project, topics, decisions, dead_ends,
    key_insights, summary, first_prompt
) VALUES (
    '$session_id', '$project', '$topics', '$decisions', '$dead_ends',
    '$key_insights', '$summary_text', '$first_prompt'
);
SQL
}

# Update archive log
episodic_db_update_log() {
    local db="$EPISODIC_DB"
    local session_id="$1"
    local status="$2"

    sqlite3 "$db" <<SQL
INSERT OR REPLACE INTO archive_log (session_id, archived_at, status)
VALUES ('$session_id', datetime('now'), '$status');
SQL
}

# Search sessions using FTS5
episodic_db_search() {
    local db="$EPISODIC_DB"
    local query="$1"
    local limit="${2:-10}"

    # Escape single quotes in query
    query="${query//\'/\'\'}"

    sqlite3 -json "$db" <<SQL
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
LIMIT $limit;
SQL
}

# Get recent sessions for a project
episodic_db_recent() {
    local db="$EPISODIC_DB"
    local project="$1"
    local limit="${2:-$EPISODIC_CONTEXT_COUNT}"

    sqlite3 -json "$db" <<SQL
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
LIMIT $limit;
SQL
}

# Get session count
episodic_db_count() {
    local db="$EPISODIC_DB"
    sqlite3 "$db" "SELECT count(*) FROM sessions;"
}

# Check if a session is already archived
episodic_db_is_archived() {
    local db="$EPISODIC_DB"
    local session_id="$1"
    local count
    count=$(sqlite3 "$db" "SELECT count(*) FROM sessions WHERE id='$session_id';")
    [[ "$count" -gt 0 ]]
}

# Count sessions since last synthesis for a project
episodic_db_sessions_since_synthesis() {
    local db="$EPISODIC_DB"
    local project="$1"

    # Escape single quotes
    project="${project//\'/\'\'}"

    local last_synth
    last_synth=$(sqlite3 "$db" "SELECT MAX(synthesized_at) FROM synthesis_log WHERE project='$project';")

    if [[ -z "$last_synth" || "$last_synth" == "" ]]; then
        # Never synthesized — count all sessions
        sqlite3 "$db" "SELECT count(*) FROM sessions WHERE project='$project';"
    else
        sqlite3 "$db" "SELECT count(*) FROM sessions WHERE project='$project' AND archived_at > '$last_synth';"
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

    project="${project//\'/\'\'}"

    sqlite3 "$db" <<SQL
INSERT INTO synthesis_log (project, synthesized_at, session_count, skills_created, skills_updated, model)
VALUES ('$project', datetime('now'), $session_count, $skills_created, $skills_updated, '$model');
SQL
}
