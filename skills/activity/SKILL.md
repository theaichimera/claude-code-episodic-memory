---
name: activity
description: "Track and search what you (or others) have done — GitHub activity, issues, PRs, commits"
user_invocable: true
---

# /activity — Activity Intelligence

Track, search, and report on what you (or others) have done across GitHub: issues created, PRs opened, commits pushed.

## Usage

`/activity [subcommand] [args]`

## Subcommands

### (no args) — Recent activity summary

When the user invokes `/activity` with no arguments, show a summary of recent activity for the current user.

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-activity recent
```

If the output is empty or says "No recent activities found", let the user know they may need to run `/activity gather` first or configure a source with `pi-activity sources add <github_username>`.

Present results grouped by day, showing activity type, repo, and title. Summarize at the top with counts (e.g., "3 issues, 2 PRs, 5 commits in the last 7 days").

### search — Search activities

Search across all tracked activities using full-text search.

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-activity search "$QUERY" --limit 20
```

Display results in a clean table or list format showing:
- Activity type (issue, PR, commit)
- Date
- Repository
- Title/description
- URL (if available)

Example: `/activity search cost optimization`

### gather — Gather from all sources

Trigger gathering of activity data from all configured sources (GitHub).

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-activity gather
```

To gather for a specific user or time range:

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-activity gather --user USERNAME --since YYYY-MM-DD
```

After gathering completes, report what was found: how many activities were gathered, from which sources, and the time range covered.

### report — Generate structured report

Generate a monthly activity report for a user.

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-activity report --user USER_SLUG --month YYYY-MM --format summary
```

If `--month` is not specified, default to the current month. If `--user` is not specified, the CLI will attempt to detect from git config.

For JSON output (useful for further processing):

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-activity report --user USER_SLUG --month YYYY-MM --format json
```

Format the report output as clean markdown with sections for:
- Summary counts by activity type
- Breakdown by repository
- Notable items (high-impact PRs, large commits, etc.)

Example: `/activity report --month 2026-02`

### team — Show team activity

Show recent activity for all configured users (all sources).

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-activity sources list
```

Then for each source found, run:

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-activity recent --user USER_SLUG --days 7
```

Present a combined view grouped by user, then by day.

Example: `/activity team`

### <username> — Show activity for a specific user

When the argument does not match any known subcommand, treat it as a GitHub username or user slug and show their recent activity.

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-activity recent --user USERNAME --days 7
```

If no results are found, check whether the user has a configured source:

```bash
${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-activity sources list --user USERNAME
```

If no source exists, suggest adding one:
```
No activity source found for USERNAME. Add one with:
  pi-activity sources add <github_username> --slug USERNAME --org <org>
```

Example: `/activity dschwartzi`

## Guidelines

- Always run commands via Bash using the full path with `${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-activity`.
- Format output for readability: use markdown tables or structured lists, not raw JSON.
- When showing dates, use human-friendly formats (e.g., "Feb 15" not "2026-02-15T10:00:00Z").
- Group activities by day or by repo depending on what makes the output most scannable.
- If the database is empty or a command returns no results, guide the user on how to set up sources and gather data.
