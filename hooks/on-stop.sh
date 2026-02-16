#!/usr/bin/env bash
# Stop hook: checkpoint session + push knowledge changes
# No API calls here — full summary happens on next SessionStart
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

# Quick metadata-only archive of current session (no API call)
archive_bin=$(_pi_bin archive)
"$archive_bin" --previous --no-summary &>/dev/null || true

# Push any knowledge repo changes (background, non-blocking)
if sync_bin=$(_pi_bin knowledge-sync 2>/dev/null); then
    "$sync_bin" push &>/dev/null &
fi
