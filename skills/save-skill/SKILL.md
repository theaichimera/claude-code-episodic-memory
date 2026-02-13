---
name: save-skill
description: Save the current conversation insight as a reusable skill in the knowledge repo
user_invocable: true
---

# /save-skill - Save a Skill from This Session

Save a piece of knowledge, pattern, or workflow from the current conversation as a reusable skill that will be injected into future sessions.

## Usage

The user invokes `/save-skill <skill-name>` to save a skill. If no name is given, infer a kebab-case name from the content.

## Instructions

When the user invokes `/save-skill`:

1. **Identify the content to save.** Look at the recent conversation context:
   - If the user just said "save that as a skill" or similar, use the most recent substantive assistant response
   - If the user provides specific content or instructions, use that
   - If unclear, ask the user what they want to save

2. **Determine the project.** Use the current working directory's project name (basename of CWD).

3. **Format as a skill file** with YAML frontmatter:

```markdown
---
name: <skill-name-kebab-case>
project: <project-name>
generated: <YYYY-MM-DD>
sessions: [<current-session-id-if-available>]
confidence: high
source: manual
---

# <Skill Title>

<The skill content - actionable instructions, steps, patterns, or knowledge>
```

4. **Write the file** to:
```
~/.claude/knowledge/<project>/skills/<skill-name>.md
```
Create the directory if it doesn't exist (`mkdir -p`).

5. **Commit and push** to the knowledge repo:
```bash
cd ~/.claude/knowledge && git add -A && git commit -m "Add skill: <skill-name> for <project>" && git push
```

6. **Confirm** to the user what was saved and where.

## Guidelines

- Skills should be **actionable instructions**, not observations. "When X happens, do Y" not "X was observed."
- Keep skills focused — one pattern/workflow per skill
- Use numbered steps for procedures, bullet points for checklists
- Include context about *why* this pattern matters (e.g., "This avoids the 20x cost estimation error we hit before")
- If a skill with the same name already exists, update it (merge new insights with existing content)

## Examples

- `/save-skill` — Save the last discussed pattern (auto-name it)
- `/save-skill deployment-checklist` — Save as "deployment-checklist"
- `/save-skill` after user says "that debugging approach was great, remember it" — Capture the approach
