#!/usr/bin/env bash
# episodic-memory: Document indexing for knowledge repo files

_EPISODIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_EPISODIC_LIB_DIR/config.sh"
source "$_EPISODIC_LIB_DIR/db.sh"

# Initialize document tables (idempotent)
# Delegates to episodic_db_init in db.sh which owns all schema definitions.
episodic_db_init_documents() {
    local db="${1:-$EPISODIC_DB}"
    episodic_db_init "$db"
}

# Extract text content from a file based on its extension
# Usage: episodic_index_extract_text <file_path>
# Returns extracted text to stdout, returns 1 for unsupported binary files
episodic_index_extract_text() {
    local file_path="$1"
    local ext="${file_path##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    local method=""
    local text=""
    local max_chars="${EPISODIC_MAX_EXTRACT_CHARS:-100000}"

    if [[ ! -f "$file_path" ]]; then
        episodic_log "WARN" "File not found: $file_path"
        return 1
    fi

    case "$ext" in
        md|txt|py|js|ts|sh|yaml|yml|json|toml|cfg|ini|xml|sql|go|rs|java|c|h|cpp|rb|r|lua)
            method="direct"
            text=$(cat "$file_path")
            ;;
        pdf)
            if command -v pdftotext >/dev/null 2>&1; then
                method="pdftotext"
                text=$(pdftotext "$file_path" - 2>/dev/null) || true
            else
                episodic_log "WARN" "pdftotext not available, skipping PDF: $file_path"
                return 1
            fi
            ;;
        html|htm)
            method="html-strip"
            text=$(sed 's/<[^>]*>//g' "$file_path" | tr -s '[:space:]' ' ')
            ;;
        docx)
            if [[ "$(uname)" == "Darwin" ]] && command -v textutil >/dev/null 2>&1; then
                method="textutil"
                text=$(textutil -convert txt -stdout "$file_path" 2>/dev/null) || true
            elif command -v pandoc >/dev/null 2>&1; then
                method="pandoc"
                text=$(pandoc --to plain "$file_path" 2>/dev/null) || true
            else
                episodic_log "WARN" "No docx converter available, skipping: $file_path"
                return 1
            fi
            ;;
        csv)
            method="csv-head"
            text=$(head -1000 "$file_path")
            ;;
        *)
            # Check mime type for unknown extensions
            local mime_type
            mime_type=$(file --mime-type -b "$file_path" 2>/dev/null || echo "unknown")
            if [[ "$mime_type" == text/* ]]; then
                method="mime-text"
                text=$(cat "$file_path")
            else
                episodic_log "WARN" "Unsupported binary file ($mime_type): $file_path"
                return 1
            fi
            ;;
    esac

    # Truncate to max chars
    if [[ ${#text} -gt $max_chars ]]; then
        text="${text:0:$max_chars}"
    fi

    episodic_log "INFO" "Extracted text from $file_path (method=$method, ${#text} chars)"
    printf '%s' "$text"
}

# Generate a content hash for change detection
# Usage: episodic_index_content_hash <file_path>
episodic_index_content_hash() {
    local file_path="$1"
    shasum -a 256 < "$file_path" | cut -d' ' -f1
}

# Index a single file into the documents table + FTS5
# Usage: episodic_index_file <file_path> <project>
episodic_index_file() {
    local file_path="$1"
    local project="$2"
    local db="${EPISODIC_DB}"

    # Resolve to absolute path
    if [[ ! "$file_path" = /* ]]; then
        file_path="$(cd "$(dirname "$file_path")" && pwd)/$(basename "$file_path")"
    fi

    if [[ ! -f "$file_path" ]]; then
        episodic_log "WARN" "File not found for indexing: $file_path"
        return 1
    fi

    # Compute content hash
    local content_hash
    content_hash=$(episodic_index_content_hash "$file_path")

    # Build document ID from project + relative path
    local relative_path="$file_path"
    if [[ -d "$EPISODIC_KNOWLEDGE_DIR" ]] && [[ "$file_path" == "$EPISODIC_KNOWLEDGE_DIR"/* ]]; then
        relative_path="${file_path#$EPISODIC_KNOWLEDGE_DIR/}"
    fi
    local doc_id="${project}:${relative_path}"

    # Check if already indexed with same hash
    local existing_hash
    existing_hash=$(sqlite3 "$db" "SELECT content_hash FROM documents WHERE id='${doc_id//\'/\'\'}';" 2>/dev/null || true)
    if [[ "$existing_hash" == "$content_hash" ]]; then
        episodic_log "INFO" "Skipping unchanged file: $file_path"
        return 0
    fi

    # Extract text
    local extracted_text
    extracted_text=$(episodic_index_extract_text "$file_path") || true
    if [[ -z "$extracted_text" ]]; then
        episodic_log "WARN" "Empty extraction for: $file_path"
        return 1
    fi

    # Generate title from filename
    local file_name
    file_name=$(basename "$file_path")
    local title="${file_name%.*}"
    # Replace dashes and underscores with spaces
    title="${title//-/ }"
    title="${title//_/ }"
    # Capitalize first letter
    title="$(echo "${title:0:1}" | tr '[:lower:]' '[:upper:]')${title:1}"

    # Determine file type from extension
    local file_type="${file_name##*.}"
    file_type=$(echo "$file_type" | tr '[:upper:]' '[:lower:]')

    # Get file size
    local file_size
    if [[ "$(uname)" == "Darwin" ]]; then
        file_size=$(stat -f%z "$file_path" 2>/dev/null || echo "0")
    else
        file_size=$(stat -c%s "$file_path" 2>/dev/null || echo "0")
    fi

    # Determine extraction method (reuse logic from extract)
    local ext="${file_name##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    local extraction_method="direct"
    case "$ext" in
        pdf) extraction_method="pdftotext" ;;
        html|htm) extraction_method="html-strip" ;;
        docx)
            if [[ "$(uname)" == "Darwin" ]] && command -v textutil >/dev/null 2>&1; then
                extraction_method="textutil"
            else
                extraction_method="pandoc"
            fi
            ;;
        csv) extraction_method="csv-head" ;;
    esac

    # Escape single quotes for SQL
    local safe_id="${doc_id//\'/\'\'}"
    local safe_project="${project//\'/\'\'}"
    local safe_file_path="${file_path//\'/\'\'}"
    local safe_file_name="${file_name//\'/\'\'}"
    local safe_title="${title//\'/\'\'}"
    local safe_text="${extracted_text//\'/\'\'}"

    # Insert/replace into documents table
    sqlite3 "$db" <<SQL
INSERT OR REPLACE INTO documents (
    id, project, file_path, file_name, title, file_type,
    file_size, content_hash, extracted_text, extraction_method, indexed_at
) VALUES (
    '$safe_id', '$safe_project', '$safe_file_path', '$safe_file_name',
    '$safe_title', '$file_type', $file_size, '$content_hash',
    '$safe_text', '$extraction_method', datetime('now')
);

DELETE FROM documents_fts WHERE doc_id = '$safe_id';
INSERT INTO documents_fts (doc_id, project, file_name, title, extracted_text)
VALUES ('$safe_id', '$safe_project', '$safe_file_name', '$safe_title', '$safe_text');
SQL

    episodic_log "INFO" "Indexed: $doc_id ($file_type, $file_size bytes)"
}

# Recursively index all supported files in a directory
# Usage: episodic_index_directory <dir_path> <project>
episodic_index_directory() {
    local dir_path="$1"
    local project="$2"
    local indexed=0
    local skipped=0
    local failed=0

    if [[ ! -d "$dir_path" ]]; then
        episodic_log "ERROR" "Directory not found: $dir_path"
        return 1
    fi

    local max_size=$((10 * 1024 * 1024))  # 10MB

    while IFS= read -r -d '' file; do
        # Skip hidden files and directories (already handled by find pattern but double-check)
        local base
        base=$(basename "$file")
        if [[ "$base" == .* ]]; then
            skipped=$((skipped + 1))
            continue
        fi

        # Skip files larger than 10MB
        local fsize
        if [[ "$(uname)" == "Darwin" ]]; then
            fsize=$(stat -f%z "$file" 2>/dev/null || echo "0")
        else
            fsize=$(stat -c%s "$file" 2>/dev/null || echo "0")
        fi
        if [[ "$fsize" -gt "$max_size" ]]; then
            episodic_log "WARN" "Skipping large file ($fsize bytes): $file"
            skipped=$((skipped + 1))
            continue
        fi

        if episodic_index_file "$file" "$project"; then
            indexed=$((indexed + 1))
        else
            failed=$((failed + 1))
        fi
    done < <(find "$dir_path" -type f \
        -not -path '*/.*' \
        -not -path '*/node_modules/*' \
        -print0 2>/dev/null)

    episodic_log "INFO" "Directory indexing complete: $dir_path (indexed=$indexed, skipped=$skipped, failed=$failed)"
    echo "Indexed: $indexed, Skipped: $skipped, Failed: $failed"
}

# Search the documents FTS5 index
# Usage: episodic_index_search <query> [limit]
episodic_index_search() {
    local query="$1"
    local limit="${2:-10}"
    local db="${EPISODIC_DB}"

    # Escape single quotes in query
    query="${query//\'/\'\'}"

    sqlite3 -json "$db" <<SQL
SELECT d.id, d.project, d.file_path, d.file_name, d.title, d.file_type,
       d.indexed_at, d.file_size, d.extraction_method,
       snippet(documents_fts, 4, '>>>', '<<<', '...', 30) as snippet, rank
FROM documents_fts fts
JOIN documents d ON d.id = fts.doc_id
WHERE documents_fts MATCH '$query'
ORDER BY rank
LIMIT $limit;
SQL
}

# Return JSON with index stats
# Usage: episodic_index_stats
episodic_index_stats() {
    local db="${EPISODIC_DB}"

    local total
    total=$(sqlite3 "$db" "SELECT count(*) FROM documents;")

    local by_project
    by_project=$(sqlite3 -json "$db" "SELECT project, count(*) as count FROM documents GROUP BY project;")

    local by_type
    by_type=$(sqlite3 -json "$db" "SELECT file_type, count(*) as count FROM documents GROUP BY file_type;")

    local total_size
    total_size=$(sqlite3 "$db" "SELECT coalesce(sum(file_size), 0) FROM documents;")

    jq -n \
        --argjson total "$total" \
        --argjson by_project "$by_project" \
        --argjson by_type "$by_type" \
        --argjson total_size "$total_size" \
        '{total_documents: $total, by_project: $by_project, by_type: $by_type, total_size_bytes: $total_size}'
}

# Remove entries for files that no longer exist on disk
# Usage: episodic_index_cleanup <project>
episodic_index_cleanup() {
    local project="$1"
    local db="${EPISODIC_DB}"
    local removed=0

    # Escape single quotes
    local safe_project="${project//\'/\'\'}"

    local doc_ids_paths
    doc_ids_paths=$(sqlite3 "$db" "SELECT id, file_path FROM documents WHERE project='$safe_project';")

    while IFS='|' read -r doc_id file_path; do
        [[ -z "$doc_id" ]] && continue
        if [[ ! -f "$file_path" ]]; then
            local safe_id="${doc_id//\'/\'\'}"
            sqlite3 "$db" <<SQL
DELETE FROM documents WHERE id = '$safe_id';
DELETE FROM documents_fts WHERE doc_id = '$safe_id';
SQL
            removed=$((removed + 1))
            episodic_log "INFO" "Cleaned up missing file: $doc_id ($file_path)"
        fi
    done <<< "$doc_ids_paths"

    episodic_log "INFO" "Cleanup complete for project $project: removed $removed entries"
    echo "Removed: $removed"
}
