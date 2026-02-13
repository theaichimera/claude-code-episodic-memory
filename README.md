# claude-episodic-memory

A self-contained episodic memory and learning system for Claude Code. Archives conversation transcripts, generates searchable summaries, synthesizes reusable skills, and evolves project knowledge over time — all backed by Git for multi-machine sync.

## The Problem

Claude Code sessions are ephemeral. Every new conversation starts from zero. Current memory mechanisms (`MEMORY.md`, `CLAUDE.md`) capture facts but lose the reasoning trail — why decisions were made, what dead ends were explored, the full narrative of problem-solving. Worse, patterns that emerge across sessions (workflows you repeat, approaches that work) are never captured as reusable knowledge.

## What This Does

Four interconnected systems:

1. **Episodic Memory** — Archive every session, generate structured summaries, enable full-text search across your entire conversation history
2. **Document Indexing** — Index files in your knowledge repo (Markdown, code, PDFs, images) for full-text search alongside session history
3. **Skill Synthesis** — Opus analyzes sessions and generates project-specific skills (structured prompts/playbooks) that capture recurring patterns, with auto-synthesis every N sessions
4. **Knowledge Repo** — Git-backed per-project knowledge store that syncs across machines, versions skill evolution, and serves as the durable source of truth

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Claude Code Session                          │
│                                                                     │
│  SessionStart hook ──┬── git pull knowledge repo (background)       │
│                      ├── archive previous session (background)      │
│                      ├── index knowledge documents (background)     │
│                      └── inject context (sessions + skills + docs)  │
│                                                                     │
│  Stop hook ──────────┬── checkpoint session metadata                │
│                      └── git commit+push knowledge (if changed)     │
│                                                                     │
│  /recall ────────────── FTS5 search (sessions + documents)          │
│  /synthesize ────────── generate skills from recent sessions        │
│  auto-synthesis ─────── triggers every N sessions automatically     │
└─────────────────────────────────────────────────────────────────────┘
         │                        │                        │
         ▼                        ▼                        ▼
┌─────────────────┐  ┌──────────────────┐  ┌──────────────────────────┐
│   SQLite FTS5   │  │  JSONL Archives  │  │   Knowledge Repo (Git)   │
│   episodic.db   │  │  (raw sessions)  │  │                          │
│                 │  │                  │  │  myproject/               │
│  sessions       │  │  myproject/     │  │    skills/                │
│  summaries      │  │    session1.jsonl│  │      validate-cost.md    │
│  sessions_fts   │  │    session2.jsonl│  │    context.md            │
│  documents      │  │  acme-app/      │  │  acme-app/               │
│  documents_fts  │  │    session3.jsonl│  │    skills/               │
│  synthesis_log  │  │                  │  │      api-optimization.md │
│                 │  │                  │  │                          │
│  (local cache,  │  │                  │  │                          │
│   regenerable)  │  │  (configurable   │  │    context.md            │
│                 │  │   directory)     │  │                          │
└─────────────────┘  └──────────────────┘  │  (git@github.com:you/    │
                                           │   claude-knowledge.git)  │
                                           └──────────────────────────┘
```

## Project Structure

```
~/.claude/episodic-memory/              # The tool (this repo)
├── README.md                           # This file
├── install.sh                          # One-command setup
├── uninstall.sh                        # Clean removal
├── bin/
│   ├── episodic-init                   # Initialize DB + directories
│   ├── episodic-archive                # Archive + summarize a session
│   ├── episodic-query                  # CLI search interface
│   ├── episodic-backfill               # Bulk import existing sessions
│   ├── episodic-context                # Generate context for session start
│   ├── episodic-knowledge-init         # Clone/setup knowledge repo
│   ├── episodic-knowledge-sync         # Git pull/push knowledge repo
│   ├── episodic-synthesize             # Generate skills from sessions (Opus)
│   └── episodic-index                  # Index knowledge repo docs for search
├── hooks/
│   ├── on-session-start.sh             # SessionStart hook
│   └── on-stop.sh                      # Stop hook
├── skills/
│   ├── recall/
│   │   └── SKILL.md                    # /recall — search session history
│   └── save-skill/
│       └── SKILL.md                    # /save-skill — save insight as skill
├── lib/
│   ├── config.sh                       # Configuration (paths, env vars)
│   ├── db.sh                           # SQLite helpers
│   ├── extract.sh                      # JSONL extraction + filtering
│   ├── summarize.sh                    # Haiku API for summaries
│   ├── knowledge.sh                    # Knowledge repo git operations
│   ├── synthesize.sh                   # Opus skill generation + auto-synthesis
│   └── index.sh                        # Document text extraction + FTS5 indexing
└── tests/
    ├── run-all.sh                      # Test runner
    ├── test-init.sh                    # DB creation + idempotency
    ├── test-archive.sh                 # Session archival
    ├── test-query.sh                   # FTS5 search + ranking
    ├── test-roundtrip.sh               # Full capture → store → retrieve
    ├── test-knowledge.sh               # Knowledge repo operations
    ├── test-synthesize.sh              # Skill generation + auto-synthesis
    ├── test-index.sh                   # Document indexing + search
    └── fixtures/
        └── sample-session.jsonl        # Test fixture
```

## Data Flow

### 1. Capture (automatic, every session)

```
Session ends → Stop hook fires
  → bin/episodic-archive --previous
    → lib/extract.sh: parse JSONL, filter out progress/snapshot events (~77% noise reduction)
    → lib/summarize.sh: call Haiku, get structured JSON summary
    → lib/db.sh: insert into SQLite (sessions + summaries + FTS5 index)
    → copy raw JSONL to archive directory
    → lib/knowledge.sh: commit + push if knowledge changed
```

### 2. Retrieve (on-demand via /recall or CLI)

```
User: /recall API optimization pricing
  → bin/episodic-query "API optimization pricing"
    → FTS5 BM25 search over summaries, topics, decisions, insights
    → returns ranked results with dates, projects, context
```

### 3. Context Injection (automatic, every session start)

```
SessionStart hook fires
  → bin/episodic-knowledge-sync pull    (get latest from remote, background)
  → bin/episodic-archive --previous     (archive last session, background)
  → bin/episodic-index --all            (index knowledge documents, background)
  → bin/episodic-context                (output recent sessions + skills + docs for this project)
```

The context block injected at session start looks like:

```markdown
# Recent Sessions (acme-app)

## 2026-02-12 (45m) [cost-analysis]
Analyzed API gateway costs. Found $50K/yr on image processing.
Decisions: Reduce payload size for non-critical endpoints
Insights: Pricing varies significantly by request type and region

## 2026-02-10 (30m) [main]
Fixed container task definitions for background service.
Decisions: Add auto-scaling policy

# Project Skills (acme-app)

## Pinned Skills (manually saved)

### deployment-checklist
# Deployment Checklist
1. Run tests locally
2. Check staging environment
...

### api-optimization
# API Cost Analysis Workflow
When analyzing API costs for a service:
1. Query billing data directly...
2. Compare to estimated usage...

## Older Skills (summary only, use /recall for details)
- container-scaling: Auto-scaling checklist for container services
```

### 4. Document Indexing (automatic on session start)

```
SessionStart hook fires (background)
  → bin/episodic-index --all
    → scan knowledge repo project directories
    → for each file: compute SHA-256 hash, skip if unchanged
    → extract text (format-aware: direct read for code/md, pdftotext for PDF,
      sed tag-strip for HTML, textutil/pandoc for docx, head -1000 for CSV)
    → insert into documents table + documents_fts (FTS5)
```

Supported formats: `.md`, `.txt`, `.py`, `.js`, `.ts`, `.sh`, `.yaml`, `.json`, `.html`, `.csv`, `.docx`, `.pdf`, and any `text/*` MIME type. Files over 10MB and hidden directories are skipped.

Search documents alongside sessions:
```bash
episodic-query "deployment architecture"           # sessions + documents
episodic-query --docs-only "deployment architecture"  # documents only
episodic-index --search "deployment"               # quick document search
episodic-index --stats                             # index statistics
episodic-index --cleanup                           # remove stale entries
```

### 5. Skill Synthesis (on-demand or automatic)

```
User: /synthesize   (or: bin/episodic-synthesize --project acme-app)
  → load last N sessions for project from DB
  → load existing skills from knowledge repo
  → call Opus: "analyze these sessions, identify recurring patterns, generate/update skills"
  → write new/updated skill files to knowledge repo
  → git commit + push
```

## The Knowledge Repo

The knowledge repo is a **separate Git repository** that you create and own. It stores per-project knowledge that evolves over time.

### Structure

```
<your-knowledge-repo>/
├── .episodic-config.json               # Repo metadata + project registry
├── myproject/
│   ├── skills/
│   │   ├── validate-cost.md            # "Always validate estimates against billing data"
│   │   └── query-pattern.md            # "How to query billing for a specific service"
│   └── context.md                      # Auto-generated project summary
├── acme-app/
│   ├── skills/
│   │   ├── api-optimization.md         # Full workflow for analyzing API costs
│   │   └── container-scaling.md        # Checklist for setting up auto-scaling
│   └── context.md
└── webapp/
    ├── skills/
    │   └── data-pipeline.md
    └── context.md
```

### Why Git?

| Alternative | Problem |
|-------------|---------|
| Cloud sync services | Unreliable sync timing, vendor dependency, not everyone uses it |
| Local filesystem | Doesn't survive disk failure, no multi-machine sync |
| S3/cloud storage | Requires cloud credentials, complex setup |
| **Git** | Universal, versioned, offline-capable, free, diffable |

Git gives you:
- **Multi-machine sync**: Clone on any machine, pull to get latest
- **Version history**: See how skills evolved over time (`git log acme-app/skills/`)
- **Collaboration**: Multiple people could share a knowledge repo
- **Backup**: GitHub/GitLab is the backup
- **No vendor lock-in**: Works with any Git host

### Setup

```bash
# Create your knowledge repo on GitHub (private recommended)
# Then configure episodic-memory to use it:

episodic-knowledge-init git@github.com:youruser/claude-knowledge.git
```

This clones the repo to `~/.claude/knowledge/` and stores the URL in config.

### Sync Protocol

- **SessionStart**: `git pull --rebase --quiet` (fast, non-blocking)
- **After skill generation**: `git add . && git commit -m "..." && git push` (background)
- **Conflict resolution**: Auto-merge for different files; for same-file conflicts, keep both versions and flag for human review

## Skill Synthesis

Skills are project-specific prompts/playbooks that capture recurring patterns from your sessions.

### What a Skill Looks Like

```markdown
---
name: validate-cost-estimate
project: acme-app
generated: 2026-02-13
sessions: [abc123, def456, ghi789]
confidence: high
---

# Validate Cost Estimate Against Billing Data

When estimating infrastructure costs for a service or resource:

1. **Never trust rough estimates alone.** Previous estimates were off by 20x or more.
2. Query your billing data directly:
   - Verify which billing account/org contains the target service
   - Use your organization's cost explorer or billing API
3. Compare estimate to actual billing data:
   - If delta > 2x, investigate
   - Common causes: shared resources, reserved instances, savings plans, committed use discounts
4. Include billing query results in any cost optimization ticket.

## Context
This pattern emerged from 3 sessions where initial estimates were dramatically wrong.
A database cost estimate of $100K/yr turned out to be $5K/yr actual — always validate
estimates with real billing data before acting on them.
```

### How Synthesis Works

1. `bin/episodic-synthesize` loads recent sessions for a project
2. It loads any existing skills from the knowledge repo
3. It calls Opus with a structured prompt:
   - "Here are the last N sessions for project X"
   - "Here are the existing skills"
   - "Identify new patterns, update existing skills, or create new ones"
4. Opus returns skill updates as structured JSON
5. The tool writes/updates Markdown skill files
6. Git commit + push

### When to Synthesize

- **Automatic**: After every N archived sessions (configurable via `EPISODIC_SYNTHESIZE_EVERY`, default: 2). Runs in background after `episodic-archive`.
- **On demand**: `/synthesize` or `bin/episodic-synthesize --project acme-app`
- **After backfill**: `episodic-backfill --synthesize` runs synthesis for all qualifying projects after import
- **Manual save**: `/save-skill` during a session to explicitly save an insight as a skill
- **Manual review**: Skills are Markdown — you can edit them directly
- **Suppressed during backfill**: `episodic-backfill` sets `EPISODIC_BACKFILL_MODE=true` to avoid triggering per-session synthesis during bulk import

### Skill Decay (Context Injection)

Skills are injected into session context using a decay function based on age:

| Tier | Age | Injection | Purpose |
|------|-----|-----------|---------|
| **Pinned** | Any age | Full content | Manually saved via `/save-skill` (`source: manual`) — never decays |
| **Fresh** | ≤30 days | Full content | Recently generated/reinforced by synthesis |
| **Aging** | 31-90 days | One-line summary | Still listed, use `/recall` for full content |
| **Stale** | >90 days | Omitted | Still searchable via `/recall`, not injected |

Synthesis naturally refreshes skills when patterns recur in new sessions, keeping actively-used knowledge in the fresh tier. Thresholds are configurable via `EPISODIC_SKILL_FRESH_DAYS` and `EPISODIC_SKILL_AGING_DAYS`.

### /save-skill — Manual Skill Creation

During any session, use `/save-skill` to explicitly save a conversation insight:

```
/save-skill deployment-checklist    # Save with a specific name
/save-skill                         # Auto-name from content
```

Manual skills get `source: manual` and `confidence: high` in their frontmatter. They appear in a "Pinned Skills" section at the top of context injection and never decay.

## SQLite Schema

```sql
-- Core session data
CREATE TABLE sessions (
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

-- Structured summaries (from Haiku)
CREATE TABLE summaries (
    session_id TEXT PRIMARY KEY REFERENCES sessions(id),
    topics TEXT,            -- JSON array
    decisions TEXT,         -- JSON array
    dead_ends TEXT,         -- JSON array
    artifacts_created TEXT, -- JSON array
    key_insights TEXT,      -- JSON array
    summary TEXT,           -- 2-4 sentence narrative
    generated_at TEXT,
    model TEXT
);

-- Full-text search index
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

-- Archive status tracking
CREATE TABLE archive_log (
    session_id TEXT PRIMARY KEY,
    archived_at TEXT,
    summary_generated_at TEXT,
    status TEXT DEFAULT 'pending'
);

CREATE INDEX idx_sessions_project_created ON sessions(project, created_at DESC);

-- Document indexing (knowledge repo files)
CREATE TABLE documents (
    id TEXT PRIMARY KEY,           -- "project:relative/path"
    project TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_name TEXT NOT NULL,
    file_type TEXT,                -- extension (md, py, etc.)
    content_hash TEXT,             -- SHA-256 for change detection
    extracted_text TEXT,
    title TEXT,
    indexed_at TEXT,
    file_size INTEGER,
    extraction_method TEXT         -- direct, pdftotext, textutil, etc.
);

CREATE VIRTUAL TABLE documents_fts USING fts5(
    doc_id UNINDEXED,
    project, file_name, title, extracted_text,
    tokenize='porter unicode61'
);

-- Auto-synthesis tracking
CREATE TABLE synthesis_log (
    project TEXT NOT NULL,
    synthesized_at TEXT NOT NULL,
    session_count INTEGER,
    skills_created INTEGER DEFAULT 0,
    skills_updated INTEGER DEFAULT 0,
    model TEXT,
    PRIMARY KEY(project, synthesized_at)
);
```

The SQLite database is a **local cache**. It can be fully regenerated from:
1. JSONL archives (re-extract metadata + re-summarize)
2. Knowledge repo (skills are the source of truth there)

## Installation

### Prerequisites

- Claude Code installed and working
- `sqlite3` (ships with macOS/Linux)
- `curl` (ships with macOS/Linux)
- `jq` (`brew install jq` / `apt install jq`)
- `git` (ships with macOS/Linux)
- `ANTHROPIC_API_KEY` set (already required for Claude Code)

### Install

```bash
git clone git@github.com:youruser/claude-episodic-memory.git ~/.claude/episodic-memory
cd ~/.claude/episodic-memory
./install.sh
```

`install.sh` will:
1. Verify prerequisites (sqlite3, curl, jq, git, ANTHROPIC_API_KEY)
2. Create SQLite database and archive directory
3. Add hooks to `~/.claude/settings.json` (non-destructive, appends to existing arrays)
4. Install `/recall` skill
5. Prompt for knowledge repo URL (optional, can configure later)

### Configure Knowledge Repo (optional but recommended)

```bash
# Create a private repo on GitHub first, then:
~/.claude/episodic-memory/bin/episodic-knowledge-init git@github.com:you/claude-knowledge.git
```

### Backfill Existing Sessions

```bash
# Preview what will be backfilled
~/.claude/episodic-memory/bin/episodic-backfill --dry-run

# Metadata only (fast, free)
~/.claude/episodic-memory/bin/episodic-backfill --no-summary

# Full backfill with Haiku summaries (~$0.008/session)
~/.claude/episodic-memory/bin/episodic-backfill
```

### Uninstall

```bash
~/.claude/episodic-memory/uninstall.sh
```

Removes hooks and skill symlinks. Optionally deletes DB (archives and knowledge repo are preserved).

## Configuration

All config is in `lib/config.sh` with environment variable overrides:

```bash
# Database location (local cache, regenerable)
EPISODIC_DB="${EPISODIC_DB:-$HOME/.claude/memory/episodic.db}"

# Raw JSONL archive directory
EPISODIC_ARCHIVE_DIR="${EPISODIC_ARCHIVE_DIR:-$HOME/.claude/episodic-memory/archives}"

# Claude projects directory (where sessions live)
EPISODIC_CLAUDE_PROJECTS="${EPISODIC_CLAUDE_PROJECTS:-$HOME/.claude/projects}"

# Knowledge repo (Git-backed, the source of truth for skills)
EPISODIC_KNOWLEDGE_REPO="${EPISODIC_KNOWLEDGE_REPO:-}"  # git URL, set during install
EPISODIC_KNOWLEDGE_DIR="${EPISODIC_KNOWLEDGE_DIR:-$HOME/.claude/knowledge}"  # local clone

# Summary model (default: Opus 4.6 with extended thinking)
EPISODIC_SUMMARY_MODEL="${EPISODIC_SUMMARY_MODEL:-claude-opus-4-6-20260205}"
EPISODIC_SUMMARY_THINKING="${EPISODIC_SUMMARY_THINKING:-true}"       # enable extended thinking
EPISODIC_SUMMARY_THINKING_BUDGET="${EPISODIC_SUMMARY_THINKING_BUDGET:-10000}"  # thinking tokens

# Skill synthesis model
EPISODIC_OPUS_MODEL="${EPISODIC_OPUS_MODEL:-claude-opus-4-6-20260205}"

# Vision model for PDF/image OCR during document indexing
EPISODIC_INDEX_VISION_MODEL="${EPISODIC_INDEX_VISION_MODEL:-claude-haiku-4-5-20251001}"

# Tuning
EPISODIC_CONTEXT_COUNT="${EPISODIC_CONTEXT_COUNT:-3}"        # sessions to inject on start
EPISODIC_MAX_EXTRACT_CHARS="${EPISODIC_MAX_EXTRACT_CHARS:-100000}"  # transcript truncation
EPISODIC_SYNTHESIZE_EVERY="${EPISODIC_SYNTHESIZE_EVERY:-2}"  # sessions between auto-synthesis

# Skill decay thresholds (days) for context injection
EPISODIC_SKILL_FRESH_DAYS="${EPISODIC_SKILL_FRESH_DAYS:-30}"   # full content injection
EPISODIC_SKILL_AGING_DAYS="${EPISODIC_SKILL_AGING_DAYS:-90}"   # one-line summary only
```

## CLI Reference

| Command | Description |
|---------|-------------|
| `episodic-init` | Initialize database and directories |
| `episodic-archive <path>` | Archive a single session JSONL |
| `episodic-archive --previous` | Archive the most recent session for CWD's project |
| `episodic-archive --all-in <dir>` | Archive all sessions in a directory |
| `episodic-query <terms>` | FTS5 search across sessions + documents |
| `episodic-query --docs-only <terms>` | Search only indexed documents |
| `episodic-query --recent [N]` | Show N most recent sessions |
| `episodic-query --project X <terms>` | Search within a specific project |
| `episodic-backfill` | Bulk import all existing sessions |
| `episodic-backfill --synthesize` | Backfill + generate skills for qualifying projects |
| `episodic-backfill --dry-run` | Preview without archiving |
| `episodic-context` | Generate context block for current project |
| `episodic-knowledge-init <repo-url>` | Clone and configure knowledge repo |
| `episodic-knowledge-sync [pull\|push]` | Sync knowledge repo with remote |
| `episodic-synthesize` | Generate/update skills for current project |
| `episodic-synthesize --project X` | Generate skills for a specific project |
| `episodic-index --all` | Index all knowledge repo documents |
| `episodic-index --project X` | Index documents for one project |
| `episodic-index --search <terms>` | Quick document search |
| `episodic-index --stats` | Show index statistics (JSON) |
| `episodic-index --cleanup` | Remove entries for deleted files |
| `/recall <terms>` | Search sessions + documents (slash command) |
| `/save-skill [name]` | Save conversation insight as a pinned skill (slash command) |

## Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Search engine | SQLite FTS5 (BM25) | Zero deps, 10-50ms queries, keyword-rich summaries don't need vectors |
| Session summaries | Haiku API | ~$0.008/session, reliable structured JSON, fast |
| Skill synthesis | Opus API | Needs deep reasoning to identify patterns across sessions |
| Knowledge storage | Git repo | Universal sync, versioned, offline-capable, no vendor lock-in |
| Archive format | Raw JSONL copy | Lossless, re-processable, same format Claude Code uses |
| Implementation | Bash | Hooks are bash, no build step, runs anywhere Claude Code runs |
| Dependencies | sqlite3, curl, jq, git | All standard on macOS/Linux, no npm/pip/compilation |
| SQLite role | Local cache | Regenerable from archives + knowledge repo; not source of truth |
| Skill format | Markdown with YAML frontmatter | Human-readable, editable, diffable, Git-friendly |
| Archive location | Configurable directory | User chooses: local, NAS, cloud sync, etc. |

## Testing

```bash
# Run all tests
./tests/run-all.sh

# Individual test suites
./tests/test-init.sh        # DB creation, schema, idempotency
./tests/test-archive.sh     # Metadata extraction, archival, dedup
./tests/test-query.sh       # FTS5 search, BM25 ranking, CLI
./tests/test-roundtrip.sh   # Full init → archive → search → context cycle
./tests/test-knowledge.sh   # Knowledge repo clone, sync, conflict handling
./tests/test-synthesize.sh  # Skill generation, auto-synthesis, backfill suppression
./tests/test-index.sh       # Document indexing, search, change detection, cleanup
```

Tests use temporary databases in `/tmp` and clean up after themselves. No API keys needed for most tests (summary/synthesis tests mock the API or use `--no-summary`).

## Cost

| Item | Cost |
|------|------|
| Backfill existing sessions (one-time, ~330 sessions) | ~$2-3 |
| Per session summary (Haiku, ongoing) | ~$0.008 |
| Skill synthesis (Opus, per invocation) | ~$0.10-0.50 |
| Auto-synthesis (every 5 sessions) | ~$0.10-0.50 |
| Storage (SQLite DB) | ~10-20 MB |
| Knowledge repo (GitHub) | Free (private repos are free) |

## Multi-Machine Setup

```bash
# Machine 1: Full install + backfill
git clone <this-repo> ~/.claude/episodic-memory
cd ~/.claude/episodic-memory && ./install.sh
bin/episodic-knowledge-init git@github.com:you/claude-knowledge.git
bin/episodic-backfill

# Machine 2: Install + connect to same knowledge repo
git clone <this-repo> ~/.claude/episodic-memory
cd ~/.claude/episodic-memory && ./install.sh
bin/episodic-knowledge-init git@github.com:you/claude-knowledge.git
# Skills and context are immediately available
# Run backfill for local session archives if needed
bin/episodic-backfill
```

The knowledge repo is the bridge between machines. The SQLite DB is local and regenerable. Session archives can be local-only or synced separately if desired.

## Verification Checklist

1. `./install.sh` — hooks added to settings.json, DB created, skill installed
2. `bin/episodic-backfill --dry-run` — shows all sessions to import
3. `bin/episodic-backfill` — imports with progress, check `archive_log` table
4. `bin/episodic-query "API optimization"` — returns ranked results
5. Start new Claude Code session — previous session archived, context injected
6. `/recall API optimization pricing` — skill returns search results
7. `bin/episodic-synthesize --project acme-app` — generates skills, commits to knowledge repo
8. `./uninstall.sh` — clean removal
9. `./tests/run-all.sh` — all green
