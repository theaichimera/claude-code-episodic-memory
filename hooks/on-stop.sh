#!/usr/bin/env bash
# Stop hook: checkpoint session + push knowledge changes
# No API calls here — full summary happens on next SessionStart

EPISODIC_ROOT="${EPISODIC_ROOT:-$HOME/.claude/episodic-memory}"

# Skip if not installed
[[ -f "$EPISODIC_ROOT/bin/episodic-archive" ]] || exit 0

# Quick metadata-only archive of current session (no Haiku call)
"$EPISODIC_ROOT/bin/episodic-archive" --previous --no-summary &>/dev/null || true

# Push any knowledge repo changes (background, non-blocking)
if [[ -f "$EPISODIC_ROOT/bin/episodic-knowledge-sync" ]]; then
    "$EPISODIC_ROOT/bin/episodic-knowledge-sync" push &>/dev/null &
fi
