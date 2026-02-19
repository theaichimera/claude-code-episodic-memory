#!/usr/bin/env bash
# install.sh: One-command setup for claude-episodic-memory
set -euo pipefail

EPISODIC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
SKILLS_DIR="$HOME/.claude/skills"

echo "╔══════════════════════════════════════════════╗"
echo "║  Installing Project Intelligence             ║"
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

# Install /save-skill
SAVE_LINK="$SKILLS_DIR/save-skill"
if [[ -L "$SAVE_LINK" || -d "$SAVE_LINK" ]]; then
    rm -rf "$SAVE_LINK"
fi
ln -s "$EPISODIC_ROOT/skills/save-skill" "$SAVE_LINK"
echo "  ✓ /save-skill skill installed"

# /deep-dive removed — codebase analysis is now via /progress (Project Understanding)

# Install /progress
PROGRESS_LINK="$SKILLS_DIR/progress"
if [[ -L "$PROGRESS_LINK" || -d "$PROGRESS_LINK" ]]; then
    rm -rf "$PROGRESS_LINK"
fi
ln -s "$EPISODIC_ROOT/skills/progress" "$PROGRESS_LINK"
echo "  ✓ /progress skill installed"

# Install /remember
REMEMBER_LINK="$SKILLS_DIR/remember"
if [[ -L "$REMEMBER_LINK" || -d "$REMEMBER_LINK" ]]; then
    rm -rf "$REMEMBER_LINK"
fi
ln -s "$EPISODIC_ROOT/skills/remember" "$REMEMBER_LINK"
echo "  ✓ /remember skill installed"

# Install /reflect
REFLECT_LINK="$SKILLS_DIR/reflect"
if [[ -L "$REFLECT_LINK" || -d "$REFLECT_LINK" ]]; then
    rm -rf "$REFLECT_LINK"
fi
ln -s "$EPISODIC_ROOT/skills/reflect" "$REFLECT_LINK"
echo "  ✓ /reflect skill installed"

# Install /activity
ACTIVITY_LINK="$SKILLS_DIR/activity"
if [[ -L "$ACTIVITY_LINK" || -d "$ACTIVITY_LINK" ]]; then
    rm -rf "$ACTIVITY_LINK"
fi
ln -s "$EPISODIC_ROOT/skills/activity" "$ACTIVITY_LINK"
echo "  ✓ /activity skill installed"

# Install /help
HELP_LINK="$SKILLS_DIR/help"
if [[ -L "$HELP_LINK" || -d "$HELP_LINK" ]]; then
    rm -rf "$HELP_LINK"
fi
ln -s "$EPISODIC_ROOT/skills/help" "$HELP_LINK"
echo "  ✓ /help skill installed"

# Install /plugins
PLUGINS_LINK="$SKILLS_DIR/plugins"
if [[ -L "$PLUGINS_LINK" || -d "$PLUGINS_LINK" ]]; then
    rm -rf "$PLUGINS_LINK"
fi
ln -s "$EPISODIC_ROOT/skills/plugins" "$PLUGINS_LINK"
echo "  ✓ /plugins skill installed"

# 6. Register as Claude Code plugin marketplace
echo ""
echo "Registering as Claude Code plugin..."

PLUGINS_DIR_CC="$HOME/.claude/plugins"
MARKETPLACE_NAME="pi-marketplace"
PLUGIN_NAME="pi"
PLUGIN_VERSION=$(python3 -c "import json; print(json.load(open('$EPISODIC_ROOT/.claude-plugin/plugin.json'))['version'])" 2>/dev/null || echo "1.0.0")

# Ensure marketplace.json exists
if [[ ! -f "$EPISODIC_ROOT/.claude-plugin/marketplace.json" ]]; then
    cat > "$EPISODIC_ROOT/.claude-plugin/marketplace.json" <<MKJSON
{
  "name": "$MARKETPLACE_NAME",
  "owner": {"name": "theaichimera", "url": "https://github.com/theaichimera"},
  "metadata": {"description": "Project Intelligence: Persistent learning system for Claude Code", "version": "$PLUGIN_VERSION"},
  "plugins": [{"name": "$PLUGIN_NAME", "description": "Episodic memory, skill synthesis, reasoning progressions, behavioral patterns, activity intelligence.", "source": "./"}]
}
MKJSON
    echo "  ✓ marketplace.json created"
fi

# Ensure hooks.json is valid (not a copy of plugin.json)
if [[ -f "$EPISODIC_ROOT/.claude-plugin/hooks.json" ]]; then
    if python3 -c "import json; d=json.load(open('$EPISODIC_ROOT/.claude-plugin/hooks.json')); assert 'name' in d and 'hooks' not in d" 2>/dev/null; then
        # hooks.json looks like plugin.json — fix it
        if [[ -f "$EPISODIC_ROOT/hooks/hooks.json" ]]; then
            cp "$EPISODIC_ROOT/hooks/hooks.json" "$EPISODIC_ROOT/.claude-plugin/hooks.json"
            echo "  ✓ hooks.json fixed (was copy of plugin.json)"
        fi
    fi
fi

# Symlink into marketplaces directory
mkdir -p "$PLUGINS_DIR_CC/marketplaces"
ln -sf "$EPISODIC_ROOT" "$PLUGINS_DIR_CC/marketplaces/$MARKETPLACE_NAME"

# Create cache with symlinks
CACHE_PATH="$PLUGINS_DIR_CC/cache/$MARKETPLACE_NAME/$PLUGIN_NAME/$PLUGIN_VERSION"
rm -rf "$CACHE_PATH"
mkdir -p "$CACHE_PATH"
for item in "$EPISODIC_ROOT"/*; do
    ln -sf "$item" "$CACHE_PATH/$(basename "$item")" 2>/dev/null || true
done
ln -sf "$EPISODIC_ROOT/.claude-plugin" "$CACHE_PATH/.claude-plugin"

# Register in known_marketplaces.json
KNOWN_MKT="$PLUGINS_DIR_CC/known_marketplaces.json"
if [[ -f "$KNOWN_MKT" ]]; then
    python3 -c "
import json
with open('$KNOWN_MKT') as f:
    data = json.load(f)
data['$MARKETPLACE_NAME'] = {
    'source': {'source': 'local', 'path': '$EPISODIC_ROOT'},
    'installLocation': '$PLUGINS_DIR_CC/marketplaces/$MARKETPLACE_NAME',
    'lastUpdated': '$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'
}
with open('$KNOWN_MKT', 'w') as f:
    json.dump(data, f, indent=4)
    f.write('\n')
" 2>/dev/null
fi

# Register in installed_plugins.json
INSTALLED_PLG="$PLUGINS_DIR_CC/installed_plugins.json"
if [[ -f "$INSTALLED_PLG" ]]; then
    python3 -c "
import json
with open('$INSTALLED_PLG') as f:
    data = json.load(f)
# Remove old @local entry if present
data['plugins'].pop('$PLUGIN_NAME@local', None)
data['plugins']['$PLUGIN_NAME@$MARKETPLACE_NAME'] = [{
    'scope': 'user',
    'installPath': '$CACHE_PATH',
    'version': '$PLUGIN_VERSION',
    'installedAt': '$(date -u +%Y-%m-%dT%H:%M:%S.000Z)',
    'lastUpdated': '$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'
}]
with open('$INSTALLED_PLG', 'w') as f:
    json.dump(data, f, indent=4)
    f.write('\n')
" 2>/dev/null
fi

# Enable in settings.json
python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    data = json.load(f)
ep = data.setdefault('enabledPlugins', {})
ep.pop('$PLUGIN_NAME@local', None)
ep['$PLUGIN_NAME@$MARKETPLACE_NAME'] = True
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(data, f, indent=4)
    f.write('\n')
" 2>/dev/null

echo "  ✓ Registered as $PLUGIN_NAME@$MARKETPLACE_NAME"

# 7. Knowledge repo setup (optional)
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
