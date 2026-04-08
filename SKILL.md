---
name: ultrablitz
description: >-
  Adversarial debate loop between Claude and Codex to refine plans, ideas, and
  designs to perfection through scored rounds. Invoke when the user says
  /ultrablitz, "debate this", "pressure test this plan", "stress test this idea",
  "blitz this", "score and improve this", "have Claude and Codex argue about this",
  or natural language equivalents like "adversarial refine" or "battle test this".
  Use proactively when the user has a plan or proposal that would benefit from
  rigorous adversarial refinement before execution.
---

# Ultrablitz — Adversarial Debate Loop

Orchestrate a multi-round adversarial debate between Claude (you) and Codex
to iteratively refine a plan, idea, design, or proposal. Each round: Codex scores
and critiques, Claude argues back or incorporates feedback. The loop runs until
both sides reach consensus or a hard round cap is hit.

## Argument Parsing

Parse the user's input for:
- **Plan text**: everything after the command trigger (or flags)
- `--max-rounds N`: maximum debate rounds (default: 5, valid range: 2-10)
- `--effort <none|minimal|low|medium|high|xhigh>`: passed to Codex if set
- `--model <model>`: passed to Codex if set

If no plan text is provided, ask the user what they want to debate/refine.

## Pre-Flight

### 1. Resolve Codex Companion Path

Find `codex-companion.mjs` by checking these paths in order. Store the first one that exists:

```bash
# Check CLAUDE_PLUGIN_ROOT first (set when running inside codex plugin context)
CODEX_COMPANION="${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs"

# Fallback: check cache (version-agnostic glob)
if [ ! -f "$CODEX_COMPANION" ]; then
  CODEX_COMPANION=$(ls ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | head -1)
fi

# Fallback: check marketplace source
if [ ! -f "$CODEX_COMPANION" ]; then
  CODEX_COMPANION=~/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs
fi
```

If none exist, tell the user: "Codex plugin not found. Run `/codex:setup` to install it." and stop.

### 2. Verify Codex Is Ready

```bash
node "$CODEX_COMPANION" setup --json
```

If this reports Codex is missing or unauthenticated, direct the user to `/codex:setup` and stop.

### 3. Load Reference Files

Read all of these before starting the loop:
- `references/debate-protocol.md` — the tone and stance contract
- `references/output-contract.md` — the structured scoring format
- `references/claude-debate-rules.md` — how you formulate rebuttals
- `references/prompts/initial-scoring.md` — Round 1 prompt template
- `references/prompts/rebuttal-scoring.md` — Round 2+ prompt template

## Round 1: Initial Submission

1. Read `references/prompts/initial-scoring.md`.
2. Assemble the full prompt by interpolating:
   - `{PLAN_TEXT}` — the user's plan/idea text
   - `{DEBATE_PROTOCOL}` — the XML blocks from `references/debate-protocol.md`
   - `{OUTPUT_CONTRACT}` — the format spec from `references/output-contract.md`
3. Write the assembled prompt to `/tmp/ultrablitz-prompt-round1.md`.
4. Submit to Codex:
   ```bash
   node "$CODEX_COMPANION" task --prompt-file /tmp/ultrablitz-prompt-round1.md [--effort VALUE] [--model VALUE]
   ```
   - Do NOT add `--write`. Scoring is read-only.
   - Only add `--effort` or `--model` if the user explicitly set them.
5. Parse the score and feedback from Codex's stdout.
6. Display Round 1 results to the user using the display format below.
7. Check termination conditions.

## Rounds 2-N: Debate Loop

For each subsequent round until termination:

1. Analyze Codex's feedback from the previous round.
2. For each critique, decide one of three responses per `references/claude-debate-rules.md`:
   - **ACCEPTED**: incorporate the feedback, state what changed and why.
   - **REJECTED**: push back with a specific counterargument and evidence.
   - **PARTIALLY ACCEPTED**: take the valid part, propose a different solution.
3. You MUST push back on at least one point per round if you genuinely believe
   Codex is wrong. Do not capitulate on every point — that defeats the purpose.
   But do not reject valid points just to be contrarian.
4. Assemble the rebuttal following the format in `references/claude-debate-rules.md`.
   Include your per-critique responses AND the full updated plan.
5. Read `references/prompts/rebuttal-scoring.md` for the delta prompt wrapper.
6. Wrap the rebuttal with the XML scoring instruction from the template.
7. Submit to Codex:
   - If the assembled content is < 500 characters:
     ```bash
     node "$CODEX_COMPANION" task --resume-last "REBUTTAL_TEXT" [--effort VALUE] [--model VALUE]
     ```
   - If >= 500 characters, write to `/tmp/ultrablitz-prompt-roundN.md` and use:
     ```bash
     node "$CODEX_COMPANION" task --resume-last --prompt-file /tmp/ultrablitz-prompt-roundN.md [--effort VALUE] [--model VALUE]
     ```
   - Do NOT add `--write`. Scoring is read-only.
   - `--resume-last` continues the existing Codex thread — this is critical for
     Codex to have context from previous rounds.
8. Parse the new score and feedback.
9. Display the round results.
10. Check termination conditions.

## Termination Conditions

Stop the loop when ANY of these is true:

| Condition | Action |
|-----------|--------|
| Score reaches **100/100** | Declare victory |
| Score reaches **95+** AND Codex states remaining gaps are theoretical/negligible | Declare consensus at theoretical maximum |
| Round count reaches `--max-rounds` (default 5) | Stop with current best |
| Score unchanged for **2 consecutive rounds** | Declare stalemate |
| Score **decreased** for **2 consecutive rounds** | Stop with regression warning |

## Display Format

After each round, present to the user:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ULTRABLITZ — Round {N}/{MAX}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Score: {SCORE}/100 ({+/-DELTA} from previous)

Category Breakdown:
  Feasibility:    {score}/25
  Completeness:   {score}/25
  Correctness:    {score}/25
  Elegance:       {score}/25

Codex's Key Critiques:
{bulleted list of critiques with severity tags}

Claude's Response: (rounds 2+ only)
{bulleted list of ACCEPTED/REJECTED/PARTIALLY ACCEPTED per critique}

Refined Plan: (if changes were made)
{updated plan text, or "No changes — all critiques rejected" if fully pushed back}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

After the final round, present the summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ULTRABLITZ — COMPLETE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Final Score: {SCORE}/100
Rounds: {N}
Score Trajectory: {R1} -> {R2} -> ... -> {RN}
Termination: {reason}

Final Refined Plan:
{the plan as it stands after all rounds}

Unresolved Disagreements: (if any)
{points where Claude and Codex could not agree, with both positions}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Critical Rules

- **NEVER** add `--write` to any Codex invocation. This is scoring/review only.
- **NEVER** modify files in the user's repository as part of the debate.
- **ALWAYS** present Codex's raw output transparently — do not hide or soften critiques.
- **ALWAYS** maintain the current refined plan state across rounds.
- If Codex fails to return a parseable score, present the raw output with a warning
  and ask the user whether to continue or abort. Do not guess scores.
- If Codex fails to invoke entirely, report the failure and stop.
  Do not generate substitute scoring yourself.
- Clean up temp files after the loop completes:
  ```bash
  rm -f /tmp/ultrablitz-prompt-round*.md
  ```
- Track these variables across rounds:
  - `currentPlan` — the plan text as refined through debate
  - `scores[]` — array of scores from each round
  - `round` — current round number
  - `maxRounds` — the cap (default 5)
