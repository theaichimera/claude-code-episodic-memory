#!/usr/bin/env bash
# install.sh: One-command setup for claude-episodic-memory
set -euo pipefail

EPISODIC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
SKILLS_DIR="$HOME/.claude/skills"

echo "╔══════════════════════════════════════════════╗"
echo "║  Installing claude-episodic-memory           ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# 1. Check prerequisites
echo "Checking prerequisites..."
errors=0

if ! command -v sqlite3 &>/dev/null; then
    echo "  ✗ sqlite3 not found"
    errors=$((errors + 1))
else
    echo "  ✓ sqlite3 $(sqlite3 --version | cut -d' ' -f1)"
fi

if ! command -v curl &>/dev/null; then
    echo "  ✗ curl not found"
    errors=$((errors + 1))
else
    echo "  ✓ curl"
fi

if ! command -v jq &>/dev/null; then
    echo "  ✗ jq not found (brew install jq)"
    errors=$((errors + 1))
else
    echo "  ✓ jq $(jq --version)"
fi

if ! command -v git &>/dev/null; then
    echo "  ✗ git not found"
    errors=$((errors + 1))
else
    echo "  ✓ git $(git --version | cut -d' ' -f3)"
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "  ⚠ ANTHROPIC_API_KEY not set (needed for summaries, not for install)"
else
    echo "  ✓ ANTHROPIC_API_KEY set"
fi

if [[ $errors -gt 0 ]]; then
    echo ""
    echo "Please install missing prerequisites and try again."
    exit 1
fi

# 2. Make bin scripts executable
echo ""
echo "Setting permissions..."
chmod +x "$EPISODIC_ROOT"/bin/*
chmod +x "$EPISODIC_ROOT"/hooks/*.sh
chmod +x "$EPISODIC_ROOT"/install.sh
chmod +x "$EPISODIC_ROOT"/uninstall.sh
echo "  ✓ Scripts are executable"

# 3. Initialize database
echo ""
echo "Initializing database..."
"$EPISODIC_ROOT/bin/episodic-init"

# 4. Add hooks to settings.json (non-destructive)
echo ""
echo "Configuring hooks..."

if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo "  ✗ Settings file not found at $SETTINGS_FILE"
    echo "  Please run Claude Code at least once first."
    exit 1
fi

# Backup settings
cp "$SETTINGS_FILE" "${SETTINGS_FILE}.backup.$(date +%s)"

# Add SessionStart hook if not already present
SESSION_START_CMD="bash $EPISODIC_ROOT/hooks/on-session-start.sh"
if ! jq -e ".hooks.SessionStart[]?.hooks[]? | select(.command == \"$SESSION_START_CMD\")" "$SETTINGS_FILE" &>/dev/null; then
    local_tmp=$(mktemp)
    jq --arg cmd "$SESSION_START_CMD" '
        .hooks.SessionStart[0].hooks += [{
            "type": "command",
            "command": $cmd,
            "timeout": 15
        }]
    ' "$SETTINGS_FILE" > "$local_tmp" && mv "$local_tmp" "$SETTINGS_FILE"
    echo "  ✓ SessionStart hook added"
else
    echo "  ✓ SessionStart hook already present"
fi

# Add Stop hook if not already present
STOP_CMD="bash $EPISODIC_ROOT/hooks/on-stop.sh"
if ! jq -e ".hooks.Stop[]?.hooks[]? | select(.command == \"$STOP_CMD\")" "$SETTINGS_FILE" &>/dev/null; then
    local_tmp=$(mktemp)
    jq --arg cmd "$STOP_CMD" '
        .hooks.Stop[0].hooks += [{
            "type": "command",
            "command": $cmd,
            "timeout": 10
        }]
    ' "$SETTINGS_FILE" > "$local_tmp" && mv "$local_tmp" "$SETTINGS_FILE"
    echo "  ✓ Stop hook added"
else
    echo "  ✓ Stop hook already present"
fi

# 5. Install /recall skill
echo ""
echo "Installing /recall skill..."
mkdir -p "$SKILLS_DIR"
SKILL_LINK="$SKILLS_DIR/recall"
if [[ -L "$SKILL_LINK" || -d "$SKILL_LINK" ]]; then
    rm -rf "$SKILL_LINK"
fi
ln -s "$EPISODIC_ROOT/skills/recall" "$SKILL_LINK"
echo "  ✓ /recall skill installed"

# 6. Knowledge repo setup (optional)
echo ""
echo "Knowledge Repo Setup"
echo "  A Git repo stores per-project skills and context across machines."
echo "  Create a private repo on GitHub (e.g., youruser/claude-knowledge)."
echo ""
read -p "  Knowledge repo URL (Enter to skip): " KNOWLEDGE_REPO_URL

if [[ -n "$KNOWLEDGE_REPO_URL" ]]; then
    "$EPISODIC_ROOT/bin/episodic-knowledge-init" "$KNOWLEDGE_REPO_URL"
    echo "  ✓ Knowledge repo configured"
else
    echo "  ⏭ Skipped (configure later with: bin/episodic-knowledge-init <url>)"
fi

# 7. Summary
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Installation complete!                       ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
source "$EPISODIC_ROOT/lib/config.sh"
echo "Database:  $EPISODIC_DB"
echo "Archives:  $EPISODIC_ARCHIVE_DIR"
echo "Knowledge: ${EPISODIC_KNOWLEDGE_DIR:-not configured}"
echo ""
echo "Next steps:"
echo "  1. Backfill existing sessions:"
echo "     $EPISODIC_ROOT/bin/episodic-backfill"
echo ""
echo "  2. Use /recall in any Claude Code session:"
echo "     /recall API optimization"
echo ""
echo "  3. Generate skills for a project:"
echo "     $EPISODIC_ROOT/bin/episodic-synthesize --project myproject"
echo ""
echo "  4. Sessions are archived automatically on each session start."
