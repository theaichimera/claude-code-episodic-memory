#!/usr/bin/env bash
# SessionStart hook: sync knowledge, archive previous session, inject context
# Must be fast — archive and sync are background where possible
#
# Supports both plugin mode (CLAUDE_PLUGIN_ROOT) and standalone install.

PI_ROOT="${CLAUDE_PLUGIN_ROOT:-${PI_ROOT:-${EPISODIC_ROOT:-$HOME/.claude/project-intelligence}}}"

# Backward compat: check both pi-* and episodic-* script names
_pi_bin() {
    local cmd="$1"
    if [[ -f "$PI_ROOT/bin/pi-$cmd" ]]; then
        echo "$PI_ROOT/bin/pi-$cmd"
    elif [[ -f "$PI_ROOT/bin/episodic-$cmd" ]]; then
        echo "$PI_ROOT/bin/episodic-$cmd"
    else
        return 1
    fi
}

# Skip if not installed
_pi_bin archive >/dev/null 2>&1 || exit 0

# Pull latest knowledge repo (background, non-blocking)
if sync_bin=$(_pi_bin knowledge-sync 2>/dev/null); then
    "$sync_bin" pull &>/dev/null &
fi

# Archive the previous session (background, non-blocking)
archive_bin=$(_pi_bin archive)
"$archive_bin" --previous &>/dev/null &

# Index knowledge repo documents (background, non-blocking)
if index_bin=$(_pi_bin index 2>/dev/null); then
    "$index_bin" --all &>/dev/null &
fi

# Auto-create Project Understanding progression on first visit (background, non-blocking)
if analyze_bin=$(_pi_bin analyze 2>/dev/null); then
    PROJECT_NAME=$(basename "${CWD:-$(pwd)}")
    KNOWLEDGE_DIR="${PI_KNOWLEDGE_DIR:-${EPISODIC_KNOWLEDGE_DIR:-$HOME/.claude/knowledge}}"
    if [[ ! -d "$KNOWLEDGE_DIR/$PROJECT_NAME/progressions/project-understanding" ]]; then
        "$analyze_bin" --project "$PROJECT_NAME" --path "${CWD:-$(pwd)}" &>/dev/null &
    fi
fi

# Inject recent session context + skills + active progressions for this project
if context_bin=$(_pi_bin context 2>/dev/null); then
    "$context_bin" 2>/dev/null || true
fi
