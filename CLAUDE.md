# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A self-contained episodic memory system for Claude Code, implemented entirely in Bash. It archives session transcripts, generates searchable summaries via the Anthropic API, synthesizes reusable skills from session patterns, and manages a Git-backed knowledge repo for cross-machine persistence.

## Development Commands

```bash
# Run all tests (8 core suites)
./tests/run-all.sh

# Run a single test suite
./tests/test-init.sh            # DB schema + idempotency
./tests/test-archive.sh         # Session archival + dedup
./tests/test-query.sh           # FTS5 search + BM25 ranking
./tests/test-roundtrip.sh       # Full capture -> store -> retrieve cycle
./tests/test-knowledge.sh       # Knowledge repo git operations
./tests/test-synthesize.sh      # Skill generation + auto-synthesis
./tests/test-index.sh           # Document indexing + search
./tests/test-project-name.sh    # Project name derivation from paths

# Run individual regression tests (not in run-all.sh)
./tests/test-busy-timeout.sh       # SQLite busy_timeout wrappers
./tests/test-git-lockfile.sh       # Knowledge repo lockfile mechanism
./tests/test-sql-escape.sh         # Centralized SQL escaping
./tests/test-large-text-sql.sh     # Large text handling via temp files
./tests/test-config-defaults.sh    # Config centralization
./tests/test-content-hash.sh       # sha256sum/shasum portability
./tests/test-schema-consistency.sh # No duplicate schema definitions
./tests/test-sql-escape-context.sh # SQL escaping in episodic-context
./tests/test-knowledge-init-env.sh # sed portability in knowledge init
./tests/test-archive-retry.sh      # Failed summaries leave retryable state
./tests/test-fts5-escape.sh        # FTS5 MATCH injection prevention
./tests/test-insert-session-escape.sh # SQL escaping in session inserts
./tests/test-git-conflict-safety.sh   # Git rebase conflict marker detection

# Install (sets up hooks, DB, skills)
./install.sh

# Uninstall (removes hooks, symlinks)
./uninstall.sh
```

Tests create temp databases in `/tmp` and clean up via `trap`. Most tests don't need `ANTHROPIC_API_KEY` — they either use `--no-summary` or mock the API.

## Architecture

**Everything is Bash.** No package manager, no build step. Dependencies: `sqlite3`, `curl`, `jq`, `git`.

### Core Data Flow

1. **Stop hook** (`hooks/on-stop.sh`): Quick metadata-only archive of current session (no API call), pushes knowledge repo changes
2. **SessionStart hook** (`hooks/on-session-start.sh`): Background tasks (git pull knowledge, archive previous session with full summary, index documents) + foreground context injection
3. **Archive** (`bin/episodic-archive`): Parses JSONL -> extracts metadata (`lib/extract.sh`) -> calls Anthropic API for structured summary (`lib/summarize.sh`) -> stores in SQLite (`lib/db.sh`) -> copies raw JSONL to archive dir
4. **Context injection** (`bin/episodic-context`): Outputs recent sessions + skills (with decay tiers) as markdown for the current project
5. **Synthesis** (`bin/episodic-synthesize`): Loads sessions from DB + existing skills -> calls Opus to identify patterns -> writes skill markdown files to knowledge repo -> git commit+push

### Three Storage Layers

- **SQLite FTS5** (`~/.claude/memory/episodic.db`): Local cache, fully regenerable. Tables: `sessions`, `summaries`, `sessions_fts`, `documents`, `documents_fts`, `synthesis_log`, `archive_log`
- **JSONL archives** (configurable dir): Raw session transcripts, lossless copies
- **Knowledge repo** (separate Git repo at `~/.claude/knowledge/`): Source of truth for skills. Per-project dirs with `skills/*.md` and `context.md`

### Library Modules (`lib/`)

- `config.sh` — **Single source of truth for all defaults.** Paths, model IDs, thresholds — all as env-var-overridable variables. Sourced by every other module. Supports `.env` local overrides. No other module should redeclare defaults.
- `db.sh` — SQLite schema init (idempotent), CRUD, FTS5 search, synthesis tracking. All SQLite access goes through wrapper functions (see Key Patterns below).
- `extract.sh` — JSONL parsing. Filters out progress/snapshot events, extracts user+assistant messages for summarization.
- `summarize.sh` — Anthropic API call (supports extended thinking). Sends extracted transcript, gets structured JSON summary.
- `knowledge.sh` — Git operations for the knowledge repo (clone, pull, push, conflict handling). All git operations serialized via lockfile.
- `synthesize.sh` — Opus-powered skill generation. Auto-synthesis check (`EPISODIC_SYNTHESIZE_EVERY`), backfill suppression via `EPISODIC_BACKFILL_MODE`.
- `index.sh` — Document text extraction (format-aware: direct read, pdftotext, html-strip, textutil/pandoc for docx) + FTS5 indexing with SHA-256 change detection. Schema is owned by `db.sh` — this module delegates `episodic_db_init`.

### Skill Decay System

Skills injected at session start use age-based tiers:
- **Pinned** (source: manual, from `/save-skill`): Always full content, never decays
- **Fresh** (<=30 days): Full content
- **Aging** (31-90 days): One-line summary only
- **Stale** (>90 days): Omitted from injection, still searchable via `/recall`

Thresholds configurable via `EPISODIC_SKILL_FRESH_DAYS` / `EPISODIC_SKILL_AGING_DAYS`.

## Key Patterns

- Every `lib/*.sh` module sources `config.sh` as its first action
- `bin/*` scripts are the CLI entry points; they source needed `lib/` modules
- **Never call `sqlite3` directly.** Use the wrappers in `db.sh`:
  - `episodic_db_exec <sql> [db]` — single statement with busy_timeout
  - `episodic_db_query_json <sql> [db]` — single statement returning JSON
  - `episodic_db_exec_multi <db> <<'SQL'` — multi-statement heredoc with busy_timeout
  - For temp-file based SQL (large text), prepend `.timeout ${EPISODIC_BUSY_TIMEOUT}` in the file and use `sqlite3 "$db" < "$sql_file"`
- **SQL string escaping:** Use `episodic_sql_escape "$value"` (defined in `db.sh`). Never use inline `${var//\'/\'\'}`.
- **FTS5 query escaping:** Use `episodic_fts5_escape "$user_input"` (defined in `db.sh`) before passing user input to FTS5 MATCH. It wraps each token in double quotes to neutralize FTS5 operators (OR, AND, NOT, NEAR, `*`, `:`). Apply FTS5 escape first, then SQL escape: `query=$(episodic_sql_escape "$(episodic_fts5_escape "$input")")`.
- **Large text in SQL:** For inserts with potentially large text (summaries, extracted document text), write SQL to a temp file via `printf` instead of using heredoc expansion. Use `trap 'rm -f "$sql_file"' RETURN` for cleanup. See `episodic_db_insert_summary` and `episodic_index_file` for examples.
- **Knowledge repo locking:** `episodic_knowledge_lock`/`episodic_knowledge_unlock` in `knowledge.sh` serialize concurrent git operations using `mkdir`-based atomic locks with PID stale detection.
- **Cross-platform portability:**
  - Use `sha256sum` with `shasum -a 256` fallback (Linux vs macOS)
  - Use `sed` with temp file instead of `sed -i ''` (macOS-only flag)
  - Use `stat -c%s` (Linux) vs `stat -f%z` (macOS) for file sizes
- **SQLite busy timeout:** `EPISODIC_BUSY_TIMEOUT` (default 5000ms) is set in `db.sh`, not `config.sh`. All db wrappers apply it automatically. For raw `sqlite3` calls via temp files, prepend `.timeout ${EPISODIC_BUSY_TIMEOUT}`.
- FTS5 virtual tables need special CREATE handling (check `sqlite_master` first)
- Schema is defined once in `episodic_db_init` in `db.sh` — no other module should define tables
- Tests override `EPISODIC_DB`, `EPISODIC_LOG`, and `EPISODIC_ARCHIVE_DIR` to temp paths and use `trap cleanup EXIT`
- The `config.sh` model IDs in the README may differ from actual `config.sh` defaults — `config.sh` is the source of truth
