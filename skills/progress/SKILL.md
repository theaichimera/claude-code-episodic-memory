---
name: progress
description: Track evolving understanding of a topic through a sequence of documents
user_invocable: true
---

# /progress - Knowledge Progression Tracking

Track how your understanding of a topic evolves across sessions. A progression is a sequence of documents (baseline, deepenings, corrections, pivots) that captures the full arc of investigation.

## Usage

`/progress <subcommand> [args]`

## Subcommands

### start - Begin a new progression

Start tracking a new topic.

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-progression-init --project PROJECT --topic "Topic Name"
```

Determine PROJECT from the current working directory (`basename` of CWD). Ask the user for the topic name if not provided.

Example: `/progress start ECS Task Placement Strategy`

### add - Add a document to a progression

Save the current analysis/finding as a numbered document in the progression.

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-progression-add \
  --project PROJECT \
  --topic "TOPIC" \
  --number NN \
  --title "Document Title" \
  --type TYPE \
  [--file PATH] \
  [--corrects NN]
```

**Document types:**
- `baseline` — Initial understanding, first pass
- `deepening` — Deeper analysis that builds on previous docs
- `correction` — Corrects a previous document (use `--corrects NN`)
- `pivot` — Fundamental change in direction or approach
- `synthesis` — Consolidation of multiple findings

**How to determine the number:** Look at the existing progression with `pi-progression-status` and use the next sequential number.

**How to create content:** Write the document content to a temp file, then pass it via `--file`. The content should capture:
- What was discovered/analyzed
- Key data points or evidence
- How this relates to previous documents in the progression

Example: `/progress add correction "Actual Cost is $3.9K not $387K" --corrects 1`

### correct - Mark an existing document as corrected

Use this when a new finding invalidates a previous document. This is a shortcut that combines `add` with `--type correction --corrects NN`.

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-progression-add \
  --project PROJECT \
  --topic "TOPIC" \
  --number NN \
  --title "Correction Title" \
  --type correction \
  --corrects PREV_NN \
  --file /path/to/content.md
```

Example: `/progress correct 1 "CUR shows actual cost is much lower"`

### conclude - Mark a progression as complete

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-progression-conclude --project PROJECT --topic "TOPIC"
```

Concluded progressions are no longer injected into session context but remain searchable.

Example: `/progress conclude ECS Task Placement Strategy`

### show - Show details of a specific progression

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-progression-status --project PROJECT --topic "TOPIC"
```

Shows: status, document list with types, corrections, current position.

Example: `/progress show ECS Task Placement Strategy`

### list - List all progressions for the project

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-progression-status --project PROJECT
```

Shows all progressions with their status (active/concluded/parked).

Example: `/progress list`

## Guidelines

- **One progression per investigation arc.** A new topic or completely separate question gets its own progression.
- **Number documents sequentially** starting from 00. Use `pi-progression-status` to find the next number.
- **Always mark corrections explicitly.** When new data contradicts a previous document, use `--type correction --corrects NN` so the progression tracks what was wrong and why.
- **Write content that captures reasoning**, not just conclusions. Future sessions need to understand *why* you reached a conclusion.
- **Commit to the knowledge repo** after adding documents:
  ```bash
  cd ~/.claude/knowledge && git add -A && git commit -m "Progression: TOPIC - doc NN" && git push
  ```

## Active Progressions in Context

Active progressions are automatically injected into session context. They include:
- Topic name and document count
- Current position summary
- Corrections (what was wrong)
- Open questions (what to investigate next)

This helps new sessions pick up where previous ones left off without re-reading all documents.
