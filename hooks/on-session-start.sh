#!/usr/bin/env bash
# SessionStart hook: sync knowledge, archive previous session, inject context
# Must be fast — archive and sync are background where possible

EPISODIC_ROOT="${EPISODIC_ROOT:-$HOME/.claude/episodic-memory}"

# Skip if not installed
[[ -f "$EPISODIC_ROOT/bin/episodic-archive" ]] || exit 0

# Pull latest knowledge repo (background, non-blocking)
if [[ -f "$EPISODIC_ROOT/bin/episodic-knowledge-sync" ]]; then
    "$EPISODIC_ROOT/bin/episodic-knowledge-sync" pull &>/dev/null &
fi

# Archive the previous session (background, non-blocking)
"$EPISODIC_ROOT/bin/episodic-archive" --previous &>/dev/null &

# Index knowledge repo documents (background, non-blocking)
if [[ -f "$EPISODIC_ROOT/bin/episodic-index" ]]; then
    "$EPISODIC_ROOT/bin/episodic-index" --all &>/dev/null &
fi

# Inject recent session context + skills for this project
if [[ -f "$EPISODIC_ROOT/bin/episodic-context" ]]; then
    "$EPISODIC_ROOT/bin/episodic-context" 2>/dev/null || true
fi
