# Changelog

All notable changes to claude-episodic-memory are documented in this file.

## [Unreleased]

### Added
- **Activity Intelligence** — System 7: tracks what users *did* (GitHub activity, issues, PRs, commits) as opposed to what they discussed (episodic) or learned (skills/progressions)
  - `lib/activity.sh`: GitHub adapter, FTS5 search, context injection, report generation
  - `bin/pi-activity`: CLI with `gather`, `search`, `report`, `recent`, `sources` subcommands
  - `skills/activity/SKILL.md`: `/activity` slash command for Claude Code
  - 3 new DB tables: `activity_sources`, `activities`, `activities_fts` (FTS5)
  - Context injection: recent activity summary injected at session start (after patterns, before sessions)
  - GitHub adapter: gathers issues created, PRs created, and commits via `gh` CLI
  - Multi-user support: track your own activity (rich) or others' (GitHub-only)
  - Report generation: summary and JSON formats, filterable by user and month
  - Source management: `pi-activity sources add/list/remove` for configuring GitHub users
  - Config: `PI_ACTIVITY_GATHER_DAYS`, `PI_ACTIVITY_MAX_INJECT`, `PI_ACTIVITY_GITHUB_ORG`
  - `tests/test-activity.sh`: 30 tests covering schema, sources, insert, search, recent, report, context injection, and SQL/FTS5 injection security
  - Designed for extension: MCP adapter and product-specific plugin adapters can be added as new gather functions in `lib/activity.sh`
- **User Behavioral Patterns** — cross-project pattern learning from session transcripts
  - `lib/patterns.sh`: extraction pipeline, storage, confidence escalation, context injection
  - `bin/pi-patterns`: CLI with `extract`, `list`, `show`, `inject`, `retire`, `backfill`, `stats`
  - `bin/episodic-patterns`: backward-compat symlink
  - 3 new DB tables: `user_patterns`, `pattern_evidence`, `pattern_extraction_log`
  - Knowledge repo: `_user/patterns/<category>/<id>.md` + `_user/patterns.yaml` index
  - Auto-extraction every 5 sessions via `on-session-start.sh` (background)
  - Context injection: top 8 weighted active patterns before project-specific context
  - Confidence escalation: 1 session=low, 2-3=medium, 4+ or 2+ projects=high
  - Weight boosting: +0.25 per additional project (capped at 2.0)
  - Dormancy: patterns not reinforced in 180 days become dormant
  - `--patterns` flag added to `pi-backfill` for pattern extraction after session import
  - Config: `PI_PATTERNS_MODEL`, `PI_PATTERNS_THINKING_BUDGET`, `PI_PATTERNS_MAX_INJECT`, `PI_PATTERNS_EXTRACT_EVERY`, `PI_PATTERNS_DORMANCY_DAYS`, `PI_PATTERNS_WEIGHT_CAP`
  - `tests/test-patterns.sh`: 22 tests (28 assertions) covering storage, injection, security
  - Security: SQL injection prevention, path traversal prevention, symlink protection, category allowlist, weight cap enforcement
- **Explicit Preferences** (`pi-remember`) — store explicit user directives that persist across all sessions
  - `bin/pi-remember`: CLI with add, list, remove, clear
  - `/remember` slash command for Claude Code
  - Stored in knowledge repo at `_user/preferences.md` (Git-synced)
  - Injected before behavioral patterns in every session context
  - Deduplication, symlink protection
- **Context Checkpointing** (`pi-checkpoint`) — save important discoveries during long sessions before context compaction
  - `bin/pi-checkpoint`: CLI that reads from stdin, writes timestamped checkpoint files
  - Types: discoveries, decisions, context, corrections
  - Stored in knowledge repo at `<project>/checkpoints/` (Git-synced)
  - Recent checkpoints (last 3) injected into next session context
  - Behavioral instructions tell Claude to proactively checkpoint without being asked
- **Deep Dive system** — comprehensive codebase analysis documents
  - `lib/deep-dive.sh`: context collection, Opus API with extended thinking, read/write/exists
  - `bin/episodic-deep-dive`: CLI with `--project`, `--path`, `--refresh`, `--force`, `--dry-run`
  - `skills/deep-dive/SKILL.md`: interactive `/deep-dive` command for Claude Code
  - Auto-triggers on first visit to a project (background, non-blocking)
  - Injected into session context between skills and documents
  - Config: `EPISODIC_DEEP_DIVE_MODEL`, `EPISODIC_DEEP_DIVE_THINKING_BUDGET`, `EPISODIC_DEEP_DIVE_TIMEOUT`
- `tests/test-deep-dive.sh`: 9 tests covering context collection, read/write, frontmatter
- This CHANGELOG

### Changed
- **Skill synthesis v2** — major quality overhaul
  - Now reads raw session transcripts from JSONL archives instead of summaries-of-summaries
  - Extended thinking enabled (16K token budget) for deeper analysis
  - Completely rewritten prompt enforcing specific quality bar: exact commands, file paths, failure modes required
  - Skills must follow structured template: When to use, What to do, Gotchas, Why
  - Supports `action: delete` to remove skills contradicted by new evidence
  - Upgraded default model from Opus 4.5 to Opus 4.6
  - New config: `EPISODIC_SYNTHESIZE_THINKING_BUDGET`, `EPISODIC_SYNTHESIZE_TRANSCRIPT_COUNT`, `EPISODIC_SYNTHESIZE_TRANSCRIPT_CHARS`
  - Summaries still used as secondary input for broader pattern coverage beyond the transcript window

## [1.3.0] - 2026-02-13

### Added
- **Document indexing** — index knowledge repo files for FTS5 search
  - `lib/index.sh`: format-aware text extraction (md, txt, py, js, html, pdf, docx, csv, images)
  - `bin/episodic-index`: CLI with `--all`, `--project`, `--stats`, `--cleanup`, `--search`
  - SHA-256 change detection to skip unchanged files
  - Vision model support for PDF/image OCR via Haiku
  - Indexed documents listed in session context injection
- **Auto-synthesis trigger** — automatically synthesize skills every N sessions
  - `episodic_maybe_synthesize` in `lib/synthesize.sh`
  - Configurable via `EPISODIC_SYNTHESIZE_EVERY` (default: 2)
  - Suppressed during backfill via `EPISODIC_BACKFILL_MODE`

## [1.2.0] - 2026-02-13

### Added
- `/save-skill` command for manually saving skills during conversations
  - Manual skills marked `source: manual` are pinned (never decay)
- **Skill decay system** for context injection
  - Pinned: always full content (manual skills)
  - Fresh (<=30 days): full content
  - Aging (31-90 days): one-line summary
  - Stale (>90 days): omitted from injection, still searchable
  - Configurable via `EPISODIC_SKILL_FRESH_DAYS` / `EPISODIC_SKILL_AGING_DAYS`

## [1.1.0] - 2026-02-13

### Fixed
- **10 security and reliability fixes** (merged from community PR)
  - SQL injection prevention: centralized `episodic_sql_escape` function
  - FTS5 MATCH injection prevention: `episodic_fts5_escape` function
  - Command injection fix in backfill retry
  - Git conflict marker detection before push
  - Atomic FTS inserts via transactions
  - SQLite busy_timeout wrappers (5000ms default)
  - Knowledge repo lockfile for concurrent git operations
  - Large text handling via temp files (prevents shell expansion issues)
  - Cross-platform fixes: shasum portability, sed -i portability
  - Config defaults centralization (single source of truth in config.sh)
- Failed archives now leave retryable state (`--retry-summaries`)

### Added
- 13 regression tests covering all security fixes
- `episodic_db_exec_multi` for multi-statement SQL

## [1.0.0] - 2026-02-13

### Added
- Initial release of claude-episodic-memory
- **Session archiving**: JSONL parsing, metadata extraction, structured summaries via Anthropic API
- **FTS5 search**: full-text search over sessions and summaries with BM25 ranking
- **Skill synthesis**: Opus-powered pattern detection and skill generation
- **Knowledge repo**: Git-backed cross-machine persistence for skills
- **Context injection**: SessionStart hook injects recent sessions + skills
- **`/recall` command**: search sessions and documents from Claude Code
- **Backfill**: bulk import of existing sessions with rate limiting
- Core libraries: config, db, extract, summarize, knowledge, synthesize
- 8 core test suites + install/uninstall scripts
- Extended thinking support for session summarization
