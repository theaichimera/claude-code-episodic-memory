#!/usr/bin/env bash
# project-intelligence: activity intelligence
# Tracks what users *did* (GitHub activity, MCP usage, etc.)
# as opposed to what they discussed (episodic) or learned (skills/progressions).

_PI_ACTIVITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_PI_ACTIVITY_LIB_DIR/config.sh"
source "$_PI_ACTIVITY_LIB_DIR/db.sh"

# ─── Source Management ───────────────────────────────────────────────

# Add or update a GitHub activity source.
# Usage: pi_activity_add_source <username> [user_slug] [org] [repos_json]
pi_activity_add_source() {
    local username="$1"
    local user_slug="${2:-$(echo "$username" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')}"
    local org="${3:-$PI_ACTIVITY_GITHUB_ORG}"
    local repos_json="${4:-[]}"

    local safe_id safe_username safe_slug safe_config
    safe_id=$(episodic_sql_escape "github:$username")
    safe_username=$(episodic_sql_escape "$username")
    safe_slug=$(episodic_sql_escape "$user_slug")
    safe_config=$(episodic_sql_escape "{\"org\":\"$org\",\"repos\":$repos_json}")

    episodic_db_exec "INSERT OR REPLACE INTO activity_sources (id, source_type, user_slug, username, config, created_at) VALUES ('$safe_id', 'github', '$safe_slug', '$safe_username', '$safe_config', datetime('now'));"

    episodic_log "INFO" "Activity source added: github:$username (slug: $user_slug)"
    echo "Added source: github:$username"
}

# List configured activity sources.
# Usage: pi_activity_list_sources [user_slug]
pi_activity_list_sources() {
    local user_slug="${1:-}"

    if [[ -n "$user_slug" ]]; then
        local safe_slug
        safe_slug=$(episodic_sql_escape "$user_slug")
        episodic_db_query_json "SELECT id, source_type, user_slug, username, last_gathered FROM activity_sources WHERE user_slug='$safe_slug';"
    else
        episodic_db_query_json "SELECT id, source_type, user_slug, username, last_gathered FROM activity_sources;"
    fi
}

# ─── GitHub Gathering ────────────────────────────────────────────────

# Gather GitHub activity for a user.
# Usage: pi_activity_gather_github <username> [since_date] [org]
# since_date: ISO date (YYYY-MM-DD), defaults to PI_ACTIVITY_GATHER_DAYS ago
pi_activity_gather_github() {
    local username="$1"
    local since_date="${2:-}"
    local org="${3:-$PI_ACTIVITY_GITHUB_ORG}"

    if ! command -v gh &>/dev/null; then
        episodic_log "ERROR" "gh CLI not found. Install: https://cli.github.com/"
        echo "ERROR: gh CLI not found" >&2
        return 1
    fi

    # Default since date
    if [[ -z "$since_date" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            since_date=$(date -v-${PI_ACTIVITY_GATHER_DAYS}d +%Y-%m-%d)
        else
            since_date=$(date -d "-${PI_ACTIVITY_GATHER_DAYS} days" +%Y-%m-%d)
        fi
    fi

    local source_id="github:$username"
    local safe_source_id
    safe_source_id=$(episodic_sql_escape "$source_id")
    local count=0

    # ─── Issues created ──────────────────────────────────────────
    local issues_json
    if [[ -n "$org" ]]; then
        issues_json=$(gh search issues --author="$username" --owner="$org" --created=">=$since_date" --limit 200 --json title,repository,state,createdAt,url,number 2>/dev/null || echo "[]")
    else
        issues_json=$(gh search issues --author="$username" --created=">=$since_date" --limit 200 --json title,repository,state,createdAt,url,number 2>/dev/null || echo "[]")
    fi

    local issue_count
    issue_count=$(echo "$issues_json" | jq 'length')

    if [[ "$issue_count" -gt 0 ]]; then
        echo "$issues_json" | jq -c '.[]' | while IFS= read -r item; do
            local title repo url created_at number state
            title=$(echo "$item" | jq -r '.title')
            repo=$(echo "$item" | jq -r '.repository.nameWithOwner // .repository.name // ""')
            url=$(echo "$item" | jq -r '.url // ""')
            created_at=$(echo "$item" | jq -r '.createdAt')
            number=$(echo "$item" | jq -r '.number')
            state=$(echo "$item" | jq -r '.state // "OPEN"')

            _pi_activity_upsert "issue_created" "$source_id" "$repo" "$number" \
                "$title" "" "$url" "$created_at" "{\"state\":\"$state\"}"
        done
        count=$((count + issue_count))
    fi

    # ─── PRs created ─────────────────────────────────────────────
    local prs_json
    if [[ -n "$org" ]]; then
        prs_json=$(gh search prs --author="$username" --owner="$org" --created=">=$since_date" --limit 100 --json title,repository,state,createdAt,url,number 2>/dev/null || echo "[]")
    else
        prs_json=$(gh search prs --author="$username" --created=">=$since_date" --limit 100 --json title,repository,state,createdAt,url,number 2>/dev/null || echo "[]")
    fi

    local pr_count
    pr_count=$(echo "$prs_json" | jq 'length')

    if [[ "$pr_count" -gt 0 ]]; then
        echo "$prs_json" | jq -c '.[]' | while IFS= read -r item; do
            local title repo url created_at number state
            title=$(echo "$item" | jq -r '.title')
            repo=$(echo "$item" | jq -r '.repository.nameWithOwner // .repository.name // ""')
            url=$(echo "$item" | jq -r '.url // ""')
            created_at=$(echo "$item" | jq -r '.createdAt')
            number=$(echo "$item" | jq -r '.number')
            state=$(echo "$item" | jq -r '.state // "OPEN"')

            _pi_activity_upsert "pr_created" "$source_id" "$repo" "$number" \
                "$title" "" "$url" "$created_at" "{\"state\":\"$state\"}"
        done
        count=$((count + pr_count))
    fi

    # ─── Commits (via events API) ────────────────────────────────
    local events_json
    events_json=$(gh api "users/$username/events" --paginate --jq '[.[] | select(.type=="PushEvent") | {repo: .repo.name, created_at: .created_at, commits: .payload.commits}]' 2>/dev/null || echo "[]")

    local commit_count=0
    echo "$events_json" | jq -c '.[]' | while IFS= read -r event; do
        local repo created_at
        repo=$(echo "$event" | jq -r '.repo')
        created_at=$(echo "$event" | jq -r '.created_at')

        # Filter by date
        if [[ "$created_at" < "${since_date}T00:00:00Z" ]]; then
            continue
        fi

        echo "$event" | jq -c '.commits[]?' | while IFS= read -r commit; do
            local msg sha
            msg=$(echo "$commit" | jq -r '.message' | head -1)
            sha=$(echo "$commit" | jq -r '.sha // ""')

            _pi_activity_upsert "commit" "$source_id" "$repo" "$sha" \
                "$msg" "" "" "$created_at" "{}"
            commit_count=$((commit_count + 1))
        done
    done

    # Update last_gathered timestamp
    episodic_db_exec "UPDATE activity_sources SET last_gathered=datetime('now') WHERE id='$safe_source_id';"

    episodic_log "INFO" "Gathered $count activities for github:$username since $since_date"
    echo "Gathered $count+ activities for $username since $since_date"
}

# ─── Activity Insert (internal) ──────────────────────────────────────

# Upsert an activity record + FTS5 entry.
# Usage: _pi_activity_upsert <type> <source_id> <repo> <ref> <title> <desc> <url> <created_at> <metadata>
_pi_activity_upsert() {
    local activity_type="$1" source_id="$2" repo="$3" ref="$4"
    local title="$5" description="$6" url="$7" created_at="$8" metadata="$9"

    # Derive project name from repo (last component)
    local project
    project=$(basename "$repo" 2>/dev/null || echo "$repo")

    # Build unique ID
    local id="${source_id}:${activity_type}:${repo}:${ref}"

    local safe_id safe_source safe_type safe_project safe_title safe_desc safe_url safe_repo safe_created safe_meta
    safe_id=$(episodic_sql_escape "$id")
    safe_source=$(episodic_sql_escape "$source_id")
    safe_type=$(episodic_sql_escape "$activity_type")
    safe_project=$(episodic_sql_escape "$project")
    safe_title=$(episodic_sql_escape "$title")
    safe_desc=$(episodic_sql_escape "$description")
    safe_url=$(episodic_sql_escape "$url")
    safe_repo=$(episodic_sql_escape "$repo")
    safe_created=$(episodic_sql_escape "$created_at")
    safe_meta=$(episodic_sql_escape "$metadata")

    # Use temp file for large content (title/description may contain shell-unsafe chars)
    local sql_file
    sql_file=$(mktemp)
    {
        printf ".timeout ${EPISODIC_BUSY_TIMEOUT}\n"
        printf "BEGIN;\n"
        printf "INSERT OR REPLACE INTO activities (id, source_id, activity_type, project, title, description, url, repo, created_at, metadata)\n"
        printf "VALUES ('%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s');\n" \
            "$safe_id" "$safe_source" "$safe_type" "$safe_project" "$safe_title" "$safe_desc" "$safe_url" "$safe_repo" "$safe_created" "$safe_meta"
        printf "DELETE FROM activities_fts WHERE activity_id = '%s';\n" "$safe_id"
        printf "INSERT INTO activities_fts (activity_id, project, title, description, repo)\n"
        printf "VALUES ('%s', '%s', '%s', '%s', '%s');\n" \
            "$safe_id" "$safe_project" "$safe_title" "$safe_desc" "$safe_repo"
        printf "COMMIT;\n"
    } > "$sql_file"

    sqlite3 "$PI_DB" < "$sql_file"
    rm -f "$sql_file"
}

# ─── Search ──────────────────────────────────────────────────────────

# Search activities using FTS5.
# Usage: pi_activity_search <query> [limit] [user_slug]
pi_activity_search() {
    local query="$1"
    local limit="${2:-20}"
    local user_slug="${3:-}"

    [[ "$limit" =~ ^[0-9]+$ ]] || limit=20
    query=$(episodic_fts5_escape "$query")
    query=$(episodic_sql_escape "$query")

    local user_filter=""
    if [[ -n "$user_slug" ]]; then
        local safe_slug
        safe_slug=$(episodic_sql_escape "$user_slug")
        user_filter="AND s.user_slug = '$safe_slug'"
    fi

    episodic_db_query_json "
SELECT
    a.id,
    a.activity_type,
    a.project,
    a.title,
    a.repo,
    a.url,
    a.created_at,
    s.user_slug,
    rank
FROM activities_fts fts
JOIN activities a ON a.id = fts.activity_id
JOIN activity_sources s ON s.id = a.source_id
WHERE activities_fts MATCH '$query'
$user_filter
ORDER BY rank
LIMIT $limit;"
}

# ─── Recent Activities ───────────────────────────────────────────────

# Get recent activities for context injection.
# Usage: pi_activity_recent [user_slug] [days] [limit]
pi_activity_recent() {
    local user_slug="${1:-}"
    local days="${2:-7}"
    local limit="${3:-$PI_ACTIVITY_MAX_INJECT}"

    [[ "$days" =~ ^[0-9]+$ ]] || days=7
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=10

    local user_filter=""
    if [[ -n "$user_slug" ]]; then
        local safe_slug
        safe_slug=$(episodic_sql_escape "$user_slug")
        user_filter="AND s.user_slug = '$safe_slug'"
    fi

    episodic_db_query_json "
SELECT
    a.activity_type,
    a.project,
    a.title,
    a.repo,
    a.url,
    a.created_at,
    s.user_slug
FROM activities a
JOIN activity_sources s ON s.id = a.source_id
WHERE a.created_at >= datetime('now', '-$days days')
$user_filter
ORDER BY a.created_at DESC
LIMIT $limit;"
}

# ─── Report Generation ───────────────────────────────────────────────

# Generate a structured activity report for a user and time period.
# Usage: pi_activity_report <user_slug> [month] [format]
# month: YYYY-MM (default: current)
# format: summary | yaml | markdown (default: summary)
pi_activity_report() {
    local user_slug="$1"
    local month="${2:-$(date +%Y-%m)}"
    local format="${3:-summary}"

    local safe_slug
    safe_slug=$(episodic_sql_escape "$user_slug")

    local start_date="${month}-01"
    local end_date
    # Calculate end of month
    if [[ "$(uname)" == "Darwin" ]]; then
        end_date=$(date -j -f "%Y-%m-%d" "${start_date}" -v+1m -v-1d +%Y-%m-%d 2>/dev/null || echo "${month}-31")
    else
        end_date=$(date -d "${start_date} +1 month -1 day" +%Y-%m-%d 2>/dev/null || echo "${month}-31")
    fi

    local safe_start safe_end
    safe_start=$(episodic_sql_escape "${start_date}T00:00:00Z")
    safe_end=$(episodic_sql_escape "${end_date}T23:59:59Z")

    case "$format" in
        summary)
            # Counts by type
            echo "## Activity Report: $user_slug ($month)"
            echo ""
            episodic_db_exec "
SELECT activity_type, count(*) as count
FROM activities a
JOIN activity_sources s ON s.id = a.source_id
WHERE s.user_slug = '$safe_slug'
  AND a.created_at >= '$safe_start'
  AND a.created_at <= '$safe_end'
GROUP BY activity_type
ORDER BY count DESC;" | while IFS='|' read -r type count; do
                echo "- $type: $count"
            done

            echo ""
            echo "### By Repo"
            episodic_db_exec "
SELECT a.repo, count(*) as count
FROM activities a
JOIN activity_sources s ON s.id = a.source_id
WHERE s.user_slug = '$safe_slug'
  AND a.created_at >= '$safe_start'
  AND a.created_at <= '$safe_end'
GROUP BY a.repo
ORDER BY count DESC
LIMIT 20;" | while IFS='|' read -r repo count; do
                echo "- $repo: $count"
            done
            ;;

        json)
            episodic_db_query_json "
SELECT
    a.activity_type,
    a.project,
    a.title,
    a.repo,
    a.url,
    a.created_at,
    a.metadata
FROM activities a
JOIN activity_sources s ON s.id = a.source_id
WHERE s.user_slug = '$safe_slug'
  AND a.created_at >= '$safe_start'
  AND a.created_at <= '$safe_end'
ORDER BY a.created_at DESC;"
            ;;

        *)
            echo "Unknown format: $format (use: summary, json)" >&2
            return 1
            ;;
    esac
}

# ─── Context Injection ───────────────────────────────────────────────

# Generate context block for session start injection.
# Usage: pi_activity_generate_context [user_slug] [days]
pi_activity_generate_context() {
    local user_slug="${1:-}"
    local days="${2:-7}"

    # Check if we have any activities at all
    local total
    total=$(episodic_db_exec "SELECT count(*) FROM activities;" 2>/dev/null || echo "0")
    [[ "$total" -gt 0 ]] || return 0

    local user_filter=""
    if [[ -n "$user_slug" ]]; then
        local safe_slug
        safe_slug=$(episodic_sql_escape "$user_slug")
        user_filter="AND s.user_slug = '$safe_slug'"
    fi

    # Get summary stats
    local stats
    stats=$(episodic_db_exec "
SELECT activity_type || ':' || count(*)
FROM activities a
JOIN activity_sources s ON s.id = a.source_id
WHERE a.created_at >= datetime('now', '-$days days')
$user_filter
GROUP BY activity_type
ORDER BY count(*) DESC;" 2>/dev/null)

    [[ -n "$stats" ]] || return 0

    echo "## Recent Activity (last ${days} days)"
    echo ""

    echo "$stats" | while IFS=':' read -r type count; do
        case "$type" in
            issue_created) echo "- $count issues created" ;;
            pr_created) echo "- $count PRs created" ;;
            pr_merged) echo "- $count PRs merged" ;;
            commit) echo "- $count commits" ;;
            *) echo "- $count $type" ;;
        esac
    done

    # Top repos
    local top_repos
    top_repos=$(episodic_db_exec "
SELECT a.repo || ' (' || count(*) || ')'
FROM activities a
JOIN activity_sources s ON s.id = a.source_id
WHERE a.created_at >= datetime('now', '-$days days')
$user_filter
GROUP BY a.repo
ORDER BY count(*) DESC
LIMIT 5;" 2>/dev/null)

    if [[ -n "$top_repos" ]]; then
        echo ""
        echo "**Top repos:** $(echo "$top_repos" | tr '\n' ', ' | sed 's/, $//')"
    fi

    echo ""
}

# ─── Gather All Sources ──────────────────────────────────────────────

# Gather from all configured sources.
# Usage: pi_activity_gather_all [since_date]
pi_activity_gather_all() {
    local since_date="${1:-}"

    local sources
    sources=$(episodic_db_query_json "SELECT id, source_type, username, config FROM activity_sources;")

    local count
    count=$(echo "$sources" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        echo "No activity sources configured. Run: pi-activity sources add <github_username>"
        return 0
    fi

    echo "$sources" | jq -c '.[]' | while IFS= read -r source; do
        local source_type username org
        source_type=$(echo "$source" | jq -r '.source_type')
        username=$(echo "$source" | jq -r '.username')
        org=$(echo "$source" | jq -r '.config | fromjson? | .org // ""' 2>/dev/null || echo "")

        case "$source_type" in
            github)
                pi_activity_gather_github "$username" "$since_date" "$org"
                ;;
            *)
                echo "Unknown source type: $source_type"
                ;;
        esac
    done
}
