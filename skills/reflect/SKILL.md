---
name: reflect
description: Analyze a progression's documents and update its current position, corrections, and open questions
user_invocable: true
---

# /reflect - Reflect on a Progression

Analyze all documents in a knowledge progression and update the progression.yaml metadata with a synthesized current position, list of corrections, and open questions.

## Usage

`/reflect [TOPIC]`

If TOPIC is omitted, reflect on all active progressions for the current project.

## Instructions

When the user invokes `/reflect`:

1. **Identify the project** from the current working directory (`basename` of CWD).

2. **Find the progression.** Use the topic argument or list active progressions:
   ```bash
   ${CLAUDE_PLUGIN_ROOT:-~/.claude/project-intelligence}/bin/pi-progression-status --project PROJECT [--topic "TOPIC"]
   ```

3. **Read all documents in the progression.** The progression directory is at:
   ```
   ~/.claude/knowledge/PROJECT/progressions/TOPIC_SLUG/
   ```
   Read `progression.yaml` to get the document list, then read each `.md` file in order.

4. **Call the Anthropic API** to analyze the full progression. Use this prompt structure:

   ```
   System: You are analyzing a knowledge progression — a sequence of documents that tracks
   evolving understanding of a topic. Some documents may correct earlier ones. Your job is
   to synthesize the CURRENT state of understanding.

   User: Here is a knowledge progression on the topic: "{topic}"

   [Document 00: title (type)]
   {content}

   [Document 01: title (type)]
   {content}

   ...

   Analyze this progression and produce:

   1. CURRENT_POSITION: A 2-3 sentence summary of the current best understanding,
      accounting for all corrections and updates. What do we know NOW?

   2. CORRECTIONS: A bullet list of what was wrong in earlier documents and what
      corrected it. Format: "Doc NN claimed X, but Doc MM showed Y"

   3. OPEN_QUESTIONS: A bullet list of unresolved questions or areas that need
      further investigation.

   Return as structured text with clear headers.
   ```

   Use `$EPISODIC_OPUS_MODEL` (or `claude-opus-4-6` default) with extended thinking enabled.
   Budget: `$EPISODIC_SYNTHESIZE_THINKING_BUDGET` tokens.

5. **Update the progression.yaml** with the results:
   - Set `current_position` to the CURRENT_POSITION text
   - Update the `corrections` list
   - Update the `open_questions` list
   - Update the `updated` timestamp

   Since the progression.yaml is simple YAML, update it by:
   - Reading the API response
   - Using `_pi_yaml_set` for `current_position` (via sourcing the lib)
   - For list fields (corrections, open_questions), rewrite the file section

   Or more simply, just edit the file directly with the correct YAML formatting.

6. **Commit and push** to the knowledge repo:
   ```bash
   cd ~/.claude/knowledge && git add -A && git commit -m "Reflect: PROJECT/TOPIC" && git push
   ```

7. **Report the results** to the user:
   - Current position summary
   - Number of corrections found
   - Open questions listed

## Example

```
User: /reflect ECS Task Placement

Reflecting on progression: ECS Task Placement Strategy (5 documents)...

Current Position:
  The ECS tasks are using spread placement with AZ constraints,
  costing $12K/yr in cross-AZ traffic. Binpack strategy would save ~$8K/yr.

Corrections:
  - Doc 01 claimed $387K DynamoDB cost, but Doc 03 (CUR validation)
    showed actual cost is $3.9K/yr

Open Questions:
  - Would binpack affect availability during AZ failures?
  - What's the latency impact of same-AZ placement?

Updated: ~/.claude/knowledge/myapp/progressions/ecs-task-placement/progression.yaml
```

## Guidelines

- **Read ALL documents** in order. Don't skip any — corrections only make sense in context.
- **Be specific** in the current position. Reference actual numbers, resources, and findings.
- **Corrections should trace the chain.** "Doc 01 said X, Doc 03 corrected to Y" — not just "Y is correct."
- **Open questions should be actionable.** "What is the cost?" not "More investigation needed."
- This is an expensive operation (Opus + extended thinking). Don't run it after every single document — wait until 2-3 new documents have been added, or when the user explicitly asks.

## Privacy Note

This command sends the full text of all documents in the progression to the Anthropic API for analysis. Do not include credentials, API keys, or sensitive PII in progression documents if you do not want them sent to the API. This is the same pattern as session summarization — user-controlled content sent to a trusted API provider.
