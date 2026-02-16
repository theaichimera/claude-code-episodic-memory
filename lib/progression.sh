#!/usr/bin/env bash
# episodic-memory: Progression tracking library
# Manages knowledge progressions — sequences of documents that track evolving
# understanding of a topic over time (baseline -> deepening -> correction -> ...).
#
# Progressions are stored in the knowledge repo at:
#   $EPISODIC_KNOWLEDGE_DIR/$project/progressions/$topic_slug/
#
# Each progression has:
#   - progression.yaml: metadata, document list, current position, corrections
#   - NN_title_slug.md: individual documents in the progression

_EPISODIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_EPISODIC_LIB_DIR/config.sh"

# Alias for the rename transition — use pi_sanitize_name or episodic_sanitize_name
pi_sanitize_name() {
    episodic_sanitize_name "$@"
}

# Convert a human-readable topic name to a filesystem-safe slug.
# "ECS Task Placement" -> "ecs-task-placement"
_pi_topic_to_slug() {
    local topic="$1"
    # Lowercase, replace spaces/underscores with hyphens, strip unsafe chars
    printf '%s' "$topic" \
        | tr '[:upper:]' '[:lower:]' \
        | tr ' _' '--' \
        | tr -cd 'a-z0-9-' \
        | sed 's/--*/-/g; s/^-//; s/-$//'
}

# Get the progressions directory for a project
# Usage: _pi_progressions_dir <project>
_pi_progressions_dir() {
    local project
    project=$(pi_sanitize_name "$1")
    echo "$EPISODIC_KNOWLEDGE_DIR/$project/progressions"
}

# Get the directory for a specific progression
# Usage: _pi_progression_dir <project> <topic>
_pi_progression_dir() {
    local project
    project=$(pi_sanitize_name "$1")
    local slug
    slug=$(_pi_topic_to_slug "$2")
    echo "$EPISODIC_KNOWLEDGE_DIR/$project/progressions/$slug"
}

# ─────────────────────────────────────────────────
# YAML helpers — simple line-by-line parsing, no external YAML library
# ─────────────────────────────────────────────────

# Read a top-level scalar value from a YAML file.
# Usage: _pi_yaml_get <file> <key>
# Returns the value after "key: " (handles quoted and unquoted values)
_pi_yaml_get() {
    local file="$1" key="$2"
    local line
    while IFS= read -r line; do
        # Match "key: value" at the start of a line (not indented = top-level)
        if [[ "$line" =~ ^${key}:\ (.*) ]]; then
            local val="${BASH_REMATCH[1]}"
            # Strip surrounding quotes
            val="${val#\"}"
            val="${val%\"}"
            val="${val#\'}"
            val="${val%\'}"
            printf '%s' "$val"
            return 0
        fi
    done < "$file"
    return 1
}

# Set a top-level scalar value in a YAML file (in-place, via temp file).
# Usage: _pi_yaml_set <file> <key> <value>
_pi_yaml_set() {
    local file="$1" key="$2" value="$3"
    # Escape for YAML double-quoted scalar safety
    value="${value//\\/\\\\}"     # backslashes first
    value="${value//\"/\\\"}"     # double quotes
    value=$(printf '%s' "$value" | tr -d '\n\r')  # strip newlines
    local yaml_tmp
    yaml_tmp=$(mktemp)

    local found=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^${key}: ]]; then
            printf '%s: "%s"\n' "$key" "$value" >> "$yaml_tmp"
            found=1
        else
            printf '%s\n' "$line" >> "$yaml_tmp"
        fi
    done < "$file"

    if [[ $found -eq 0 ]]; then
        printf '%s: "%s"\n' "$key" "$value" >> "$yaml_tmp"
    fi

    mv "$yaml_tmp" "$file"
    rm -f "$yaml_tmp" 2>/dev/null
}

# ─────────────────────────────────────────────────
# Core progression functions
# ─────────────────────────────────────────────────

# Create a new progression for a topic.
# Usage: pi_progression_create <project> <topic>
# Creates progressions/topic-slug/ dir with progression.yaml
pi_progression_create() {
    local project="$1"
    local topic="$2"

    if [[ -z "$project" || -z "$topic" ]]; then
        episodic_log "ERROR" "pi_progression_create: project and topic required"
        return 1
    fi

    local dir
    dir=$(_pi_progression_dir "$project" "$topic")

    if [[ -d "$dir" ]]; then
        episodic_log "WARN" "Progression already exists: $dir"
        echo "$dir"
        return 0
    fi

    mkdir -p -m 700 "$dir"

    local today
    today=$(date -u +"%Y-%m-%d")

    # Sanitize topic for YAML safety: escape quotes, strip newlines/backslashes
    local safe_topic="${topic//\\/\\\\}"
    safe_topic="${safe_topic//\"/\\\"}"
    safe_topic=$(printf '%s' "$safe_topic" | tr -d '\n\r')

    # Refuse to write to symlinks
    if [[ -L "$dir/progression.yaml" ]]; then
        episodic_log "ERROR" "Refusing to write to symlink: $dir/progression.yaml"
        return 1
    fi

    # Use printf (not expanding heredoc) to prevent shell injection via topic name
    {
        printf 'topic: "%s"\n' "$safe_topic"
        printf 'project: %s\n' "$project"
        printf 'status: active\n'
        printf 'created: %s\n' "$today"
        printf 'updated: %s\n' "$today"
        printf 'current_position: ""\n'
        printf 'corrections: []\n'
        printf 'open_questions: []\n'
        printf 'documents: []\n'
    } > "$dir/progression.yaml"

    episodic_log "INFO" "Created progression: $project / $topic at $dir"
    echo "$dir"
}

# Add a document to an existing progression.
# Usage: pi_progression_add <project> <topic> <doc_number> <title> <doc_type> [content_file]
# doc_type: baseline, deepening, correction, pivot, synthesis, etc.
# If content_file is provided, it is copied into the progression directory.
# If content_file is "-", reads from stdin.
pi_progression_add() {
    local project="$1"
    local topic="$2"
    local doc_number="$3"
    local title="$4"
    local doc_type="$5"
    local content_file="${6:-}"

    if [[ -z "$project" || -z "$topic" || -z "$doc_number" || -z "$title" || -z "$doc_type" ]]; then
        episodic_log "ERROR" "pi_progression_add: project, topic, doc_number, title, doc_type required"
        return 1
    fi

    local dir
    dir=$(_pi_progression_dir "$project" "$topic")
    local yaml_file="$dir/progression.yaml"

    if [[ ! -f "$yaml_file" ]]; then
        episodic_log "ERROR" "Progression does not exist: $dir"
        return 1
    fi

    # Build filename: NN_title_slug.md
    local title_slug
    title_slug=$(_pi_topic_to_slug "$title")
    local filename
    filename=$(printf '%02d_%s.md' "$doc_number" "$title_slug")

    local doc_path="$dir/$filename"

    # Refuse to write to symlinks
    if [[ -L "$doc_path" ]]; then
        episodic_log "ERROR" "Refusing to write to symlink: $doc_path"
        return 1
    fi

    # Write content
    if [[ "$content_file" == "-" ]]; then
        cat > "$doc_path"
    elif [[ -n "$content_file" && -f "$content_file" ]]; then
        cp "$content_file" "$doc_path"
    else
        # Create an empty document with a title header
        printf '# %s\n\n' "$title" > "$doc_path"
    fi

    # Append document entry to progression.yaml
    # We append to the documents list by adding YAML list item lines at the end
    local today
    today=$(date -u +"%Y-%m-%d")

    # Remove the trailing "documents: []" if present, replacing with "documents:"
    if grep -q '^documents: \[\]' "$yaml_file"; then
        local add_tmp
        add_tmp=$(mktemp)
        while IFS= read -r line; do
            if [[ "$line" == "documents: []" ]]; then
                printf 'documents:\n' >> "$add_tmp"
            else
                printf '%s\n' "$line" >> "$add_tmp"
            fi
        done < "$yaml_file"
        mv "$add_tmp" "$yaml_file"
        rm -f "$add_tmp" 2>/dev/null
    fi

    # Sanitize title for YAML: escape quotes, strip newlines/backslashes
    local safe_title="${title//\\/\\\\}"
    safe_title="${safe_title//\"/\\\"}"
    safe_title=$(printf '%s' "$safe_title" | tr -d '\n\r')

    # Validate doc_number is numeric
    [[ "$doc_number" =~ ^[0-9]+$ ]] || doc_number=0

    # Append document entry
    {
        printf '  - id: "%02d"\n' "$doc_number"
        printf '    title: "%s"\n' "$safe_title"
        printf '    file: "%s"\n' "$filename"
        printf '    type: %s\n' "$doc_type"
        printf '    date: %s\n' "$today"
        printf '    corrects: null\n'
        printf '    superseded_by: null\n'
    } >> "$yaml_file"

    # Update the "updated" timestamp
    _pi_yaml_set "$yaml_file" "updated" "$today"

    episodic_log "INFO" "Added doc $doc_number ($doc_type) to progression: $project / $topic"
    echo "$doc_path"
}

# Read a progression's YAML and return it as formatted text.
# Usage: pi_progression_get <project> <topic>
pi_progression_get() {
    local project="$1"
    local topic="$2"

    local dir
    dir=$(_pi_progression_dir "$project" "$topic")
    local yaml_file="$dir/progression.yaml"

    if [[ ! -f "$yaml_file" ]]; then
        episodic_log "ERROR" "Progression not found: $project / $topic"
        return 1
    fi

    cat "$yaml_file"
}

# List all progressions for a project.
# Usage: pi_progression_list <project>
# Output: one line per progression: "slug\tstatus\ttopic"
pi_progression_list() {
    local project="$1"

    local prog_dir
    prog_dir=$(_pi_progressions_dir "$project")

    if [[ ! -d "$prog_dir" ]]; then
        return 0
    fi

    local entry
    for entry in "$prog_dir"/*/; do
        [[ -d "$entry" ]] || continue
        local yaml_file="$entry/progression.yaml"
        [[ -f "$yaml_file" ]] || continue

        local slug
        slug=$(basename "$entry")
        local status
        status=$(_pi_yaml_get "$yaml_file" "status" 2>/dev/null || echo "unknown")
        local ptopic
        ptopic=$(_pi_yaml_get "$yaml_file" "topic" 2>/dev/null || echo "$slug")

        printf '%s\t%s\t%s\n' "$slug" "$status" "$ptopic"
    done
}

# Update the status of a progression (active, concluded, parked).
# Usage: pi_progression_update_status <project> <topic> <status>
pi_progression_update_status() {
    local project="$1"
    local topic="$2"
    local status="$3"

    if [[ -z "$project" || -z "$topic" || -z "$status" ]]; then
        episodic_log "ERROR" "pi_progression_update_status: project, topic, status required"
        return 1
    fi

    # Validate status
    case "$status" in
        active|concluded|parked) ;;
        *)
            episodic_log "ERROR" "Invalid status: $status (must be active|concluded|parked)"
            return 1
            ;;
    esac

    local dir
    dir=$(_pi_progression_dir "$project" "$topic")
    local yaml_file="$dir/progression.yaml"

    if [[ ! -f "$yaml_file" ]]; then
        episodic_log "ERROR" "Progression not found: $project / $topic"
        return 1
    fi

    _pi_yaml_set "$yaml_file" "status" "$status"

    local today
    today=$(date -u +"%Y-%m-%d")
    _pi_yaml_set "$yaml_file" "updated" "$today"

    episodic_log "INFO" "Updated status of $project / $topic to $status"
}

# Mark a document as correcting a previous document.
# Usage: pi_progression_mark_correction <project> <topic> <doc_number> <corrects_doc>
pi_progression_mark_correction() {
    local project="$1"
    local topic="$2"
    local doc_number="$3"
    local corrects_doc="$4"

    if [[ -z "$project" || -z "$topic" || -z "$doc_number" || -z "$corrects_doc" ]]; then
        episodic_log "ERROR" "pi_progression_mark_correction: all arguments required"
        return 1
    fi

    local dir
    dir=$(_pi_progression_dir "$project" "$topic")
    local yaml_file="$dir/progression.yaml"

    if [[ ! -f "$yaml_file" ]]; then
        episodic_log "ERROR" "Progression not found: $project / $topic"
        return 1
    fi

    local formatted_doc
    formatted_doc=$(printf '%02d' "$doc_number")
    local formatted_corrects
    formatted_corrects=$(printf '%02d' "$corrects_doc")

    # Update corrects/superseded_by fields in document entries via temp file
    local corr_tmp
    corr_tmp=$(mktemp)

    local current_id=""
    while IFS= read -r line; do
        # Track which document entry we're in
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*\"?([0-9]+)\"? ]]; then
            current_id=$(printf '%02d' "${BASH_REMATCH[1]}")
        fi

        # If this is the correcting doc's "corrects:" line, update it
        if [[ "$current_id" == "$formatted_doc" && "$line" =~ ^[[:space:]]*corrects: ]]; then
            printf '    corrects: "%s"\n' "$formatted_corrects" >> "$corr_tmp"
            continue
        fi

        # If this is the corrected doc's "superseded_by:" line, update it
        if [[ "$current_id" == "$formatted_corrects" && "$line" =~ ^[[:space:]]*superseded_by: ]]; then
            printf '    superseded_by: "%s"\n' "$formatted_doc" >> "$corr_tmp"
            continue
        fi

        printf '%s\n' "$line" >> "$corr_tmp"
    done < "$yaml_file"

    mv "$corr_tmp" "$yaml_file"
    rm -f "$corr_tmp" 2>/dev/null

    # Update the top-level corrections list
    local today
    today=$(date -u +"%Y-%m-%d")
    local correction_entry="doc_${formatted_doc} corrects doc_${formatted_corrects} (${today})"

    local corr_tmp2
    corr_tmp2=$(mktemp)

    local in_corrections=0
    local appended=0
    while IFS= read -r line; do
        if [[ "$line" == "corrections: []" ]]; then
            printf 'corrections:\n' >> "$corr_tmp2"
            printf '  - %s\n' "$correction_entry" >> "$corr_tmp2"
            appended=1
            continue
        fi
        if [[ "$line" =~ ^corrections: && "$line" != "corrections: []" ]]; then
            printf '%s\n' "$line" >> "$corr_tmp2"
            in_corrections=1
            continue
        fi
        if [[ $in_corrections -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
                printf '%s\n' "$line" >> "$corr_tmp2"
                continue
            else
                # End of corrections block — append our entry
                printf '  - %s\n' "$correction_entry" >> "$corr_tmp2"
                printf '%s\n' "$line" >> "$corr_tmp2"
                in_corrections=0
                appended=1
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$corr_tmp2"
    done < "$yaml_file"

    # If corrections: was the last block, append after EOF
    if [[ $in_corrections -eq 1 && $appended -eq 0 ]]; then
        printf '  - %s\n' "$correction_entry" >> "$corr_tmp2"
    fi

    mv "$corr_tmp2" "$yaml_file"
    rm -f "$corr_tmp2" 2>/dev/null

    _pi_yaml_set "$yaml_file" "updated" "$today"

    episodic_log "INFO" "Marked doc $doc_number as correcting doc $corrects_doc in $project / $topic"
}

# Get all active progressions for a project.
# Usage: pi_progression_get_active <project>
# Output: same format as pi_progression_list but filtered to status=active
pi_progression_get_active() {
    local project="$1"

    local prog_dir
    prog_dir=$(_pi_progressions_dir "$project")

    if [[ ! -d "$prog_dir" ]]; then
        return 0
    fi

    local entry
    for entry in "$prog_dir"/*/; do
        [[ -d "$entry" ]] || continue
        local yaml_file="$entry/progression.yaml"
        [[ -f "$yaml_file" ]] || continue

        local status
        status=$(_pi_yaml_get "$yaml_file" "status" 2>/dev/null || echo "unknown")
        [[ "$status" == "active" ]] || continue

        local slug
        slug=$(basename "$entry")
        local ptopic
        ptopic=$(_pi_yaml_get "$yaml_file" "topic" 2>/dev/null || echo "$slug")

        printf '%s\t%s\t%s\n' "$slug" "$status" "$ptopic"
    done
}

# Generate compact context for injection into Claude sessions.
# Only includes active progressions. For each, outputs:
#   - Topic name and document count
#   - current_position (if set)
#   - Active corrections
#   - Open questions
# Usage: pi_progression_generate_context <project>
# Output: markdown-formatted context block
pi_progression_generate_context() {
    local project="$1"

    local prog_dir
    prog_dir=$(_pi_progressions_dir "$project")

    if [[ ! -d "$prog_dir" ]]; then
        return 0
    fi

    local has_output=0
    local output=""

    local entry
    for entry in "$prog_dir"/*/; do
        [[ -d "$entry" ]] || continue
        local yaml_file="$entry/progression.yaml"
        [[ -f "$yaml_file" ]] || continue

        local status
        status=$(_pi_yaml_get "$yaml_file" "status" 2>/dev/null || echo "unknown")
        [[ "$status" == "active" ]] || continue

        local ptopic
        ptopic=$(_pi_yaml_get "$yaml_file" "topic" 2>/dev/null || echo "unknown")
        local current_position
        current_position=$(_pi_yaml_get "$yaml_file" "current_position" 2>/dev/null || echo "")

        # Count documents
        local doc_count=0
        local doc_line
        while IFS= read -r doc_line; do
            if [[ "$doc_line" =~ ^[[:space:]]*-[[:space:]]*id: ]]; then
                doc_count=$((doc_count + 1))
            fi
        done < "$yaml_file"

        output+="### $ptopic"$'\n'
        output+="*${doc_count} documents, active*"$'\n'

        if [[ -n "$current_position" ]]; then
            output+="**Current position:** $current_position"$'\n'
        fi

        # Extract corrections (non-empty list)
        local in_corrections=0
        local has_corrections=0
        while IFS= read -r doc_line; do
            if [[ "$doc_line" =~ ^corrections: ]]; then
                if [[ "$doc_line" == "corrections: []" ]]; then
                    break
                fi
                in_corrections=1
                continue
            fi
            if [[ $in_corrections -eq 1 ]]; then
                if [[ "$doc_line" =~ ^[[:space:]]*-[[:space:]](.+) ]]; then
                    if [[ $has_corrections -eq 0 ]]; then
                        output+="**Corrections:**"$'\n'
                        has_corrections=1
                    fi
                    output+="- ${BASH_REMATCH[1]}"$'\n'
                else
                    break
                fi
            fi
        done < "$yaml_file"

        # Extract open questions (non-empty list)
        local in_questions=0
        local has_questions=0
        while IFS= read -r doc_line; do
            if [[ "$doc_line" =~ ^open_questions: ]]; then
                if [[ "$doc_line" == "open_questions: []" ]]; then
                    break
                fi
                in_questions=1
                continue
            fi
            if [[ $in_questions -eq 1 ]]; then
                if [[ "$doc_line" =~ ^[[:space:]]*-[[:space:]](.+) ]]; then
                    if [[ $has_questions -eq 0 ]]; then
                        output+="**Open questions:**"$'\n'
                        has_questions=1
                    fi
                    output+="- ${BASH_REMATCH[1]}"$'\n'
                else
                    break
                fi
            fi
        done < "$yaml_file"

        output+=$'\n'
        has_output=1
    done

    if [[ $has_output -eq 1 ]]; then
        printf '## Active Progressions\n\n'
        printf '%s' "$output"
    fi
}
