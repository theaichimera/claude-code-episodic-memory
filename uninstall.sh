#!/usr/bin/env bash
# uninstall.sh: Clean removal of claude-episodic-memory
set -euo pipefail

EPISODIC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
SKILLS_DIR="$HOME/.claude/skills"

echo "Uninstalling claude-episodic-memory..."

# 1. Remove hooks from settings.json
if [[ -f "$SETTINGS_FILE" ]]; then
    echo "Removing hooks..."

    # Backup
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.backup.$(date +%s)"

    SESSION_START_CMD="bash $EPISODIC_ROOT/hooks/on-session-start.sh"
    STOP_CMD="bash $EPISODIC_ROOT/hooks/on-stop.sh"

    tmp=$(mktemp)
    jq --arg ss_cmd "$SESSION_START_CMD" --arg stop_cmd "$STOP_CMD" '
        .hooks.SessionStart[0].hooks |= map(select(.command != $ss_cmd)) |
        .hooks.Stop[0].hooks |= map(select(.command != $stop_cmd))
    ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"

    echo "  ✓ Hooks removed from settings.json"
fi

# 2. Remove skill symlink
SKILL_LINK="$SKILLS_DIR/recall"
if [[ -L "$SKILL_LINK" ]]; then
    rm "$SKILL_LINK"
    echo "  ✓ /recall skill removed"
fi

# 3. Ask about database
source "$EPISODIC_ROOT/lib/config.sh"
echo ""
echo "Database at: $EPISODIC_DB"
echo "Archives at: $EPISODIC_ARCHIVE_DIR"
echo ""
read -p "Delete database? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f "$EPISODIC_DB"
    echo "  ✓ Database deleted"
else
    echo "  ✓ Database preserved"
fi

echo ""
read -p "Delete archives? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$EPISODIC_ARCHIVE_DIR"
    echo "  ✓ Archives deleted"
else
    echo "  ✓ Archives preserved"
fi

echo ""
echo "Uninstall complete."
echo "The episodic-memory directory itself has NOT been removed."
echo "To fully remove: rm -rf $EPISODIC_ROOT"
