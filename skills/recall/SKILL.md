---
name: recall
description: Search episodic memory - your full conversation history across all Claude Code sessions
user_invocable: true
---

# /recall - Search Session History

Search your archived Claude Code sessions for past decisions, approaches, dead ends, and insights.

## Usage

The user invokes `/recall <search terms>` to find relevant past sessions.

## Instructions

When the user invokes `/recall`, run the episodic-query CLI tool with their search terms:

```bash
~/.claude/episodic-memory/bin/episodic-query "$ARGUMENTS"
```

If no arguments are provided, show recent sessions:

```bash
~/.claude/episodic-memory/bin/episodic-query --recent 5
```

Present the results to the user in a clean format, highlighting:
- Which sessions matched and when they occurred
- Key decisions made in those sessions
- Dead ends to avoid repeating
- Insights that might be relevant now

If the user wants more detail about a specific session, the raw JSONL archive can be found at `~/.claude/episodic-memory/archives/<project>/<session-id>.jsonl`.

The search also covers indexed documents from the knowledge repo. Use `--docs-only` to search only documents:

```bash
~/.claude/episodic-memory/bin/episodic-query --docs-only "$ARGUMENTS"
```

## Examples

- `/recall API optimization` - Find sessions about API optimization
- `/recall FTS5 search` - Find when FTS5 decisions were made
- `/recall --project myapp containers` - Search within myapp sessions only
- `/recall --recent 10` - Show last 10 sessions
