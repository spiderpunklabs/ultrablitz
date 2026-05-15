# Scoring Prompt — Phase 2 (all rounds)

Single parametric prompt for Phase 2 plan evaluation. Round 1 is sent as a
fresh task (or `--resume-last` from Phase 1); rounds 2+ continue over
`--resume-last`. The round-conditional blocks below are gated by placeholders.

Assemble by interpolating:
- `{ROUND_CONTEXT}` — R1: "Now entering Phase 2. Score the following plan
  using the framework we agreed upon. Identify every weakness, gap,
  assumption, and risk." R2+: "The plan author has responded to your
  critiques with a rebuttal and updated plan below. Re-score the plan in
  its CURRENT state using the agreed framework."
- `{PLAN_TEXT}` — R1: the full plan. R2+: omit (Codex retains via
  `--resume-last`); pass Claude's rebuttal text + revised plan instead.
- `{DEBATE_PROTOCOL}` — tone blocks from `references/debate-protocol.md`.
- `{OUTPUT_CONTRACT}` — dynamic contract generated from the agreed framework.
- `{INCLUDE_DIG_DEEPER}` — R1 only: include `<dig_deeper_nudge>` block. R2+:
  omit (Codex has already done first-pass digging).
- `{INCLUDE_REBUTTAL_RULES}` — R2+ only: include the rebuttal scoring
  rules (raise scores where addressed, hold ground on weak counterargs,
  score must reflect CURRENT state, increases must cite the resolved
  critique). R1: omit.

Write to:
- R1: `<session>/p2-r1-scoring.md`
- R2+: `<session>/p2-r<N>-rebuttal.md` (when content >= 500 chars; otherwise
  pass directly as the positional `task --resume-last "..."` argument).

Always `.md`. Run `validate-session <runId>` immediately before the Codex call.

```xml
<task>
{ROUND_CONTEXT}

You are a ruthless technical reviewer in an adversarial scoring loop called Ultrablitz.

THE PLAN TO SCORE (or, on R2+, the updated plan and the author's rebuttal):

{PLAN_TEXT}

---

{INCLUDE_REBUTTAL_RULES}
</task>

{DEBATE_PROTOCOL}

<structured_output_contract>
{OUTPUT_CONTRACT}
</structured_output_contract>

<grounding_rules>
Ground every critique in specific text from the plan.
Do not invent problems that are not present.
If something is ambiguous, flag it as ambiguous rather than assuming the worst.
But assume the worst for anything left completely unaddressed.
If a point is an inference rather than a fact, label it clearly.
On rounds after the first: new critiques must reference specific parts of
the updated plan or rebuttal; do not repeat addressed critiques unless the
fix is inadequate.
</grounding_rules>

<completeness_contract>
Do not stop at the first 2-3 obvious issues.
Systematically walk through every section, every claim, every dependency.
Score against EVERY category in the agreed framework.
Resolve the full scoring before stopping.
On R2+: re-examine the entire plan, not just the parts that changed —
fixes in one area can expose new gaps elsewhere.
</completeness_contract>

{INCLUDE_DIG_DEEPER}

<verification_loop>
Before finalizing, verify that each category score is justified by your critiques.
If a category scores low, there must be a corresponding critique explaining why.
If a category scores high, verify you found no material issues in that area.
On R2+: also verify that score changes track actual plan quality, not
momentum or fatigue — points addressed well should yield higher category
scores, and new issues should be reflected in lower scores.
If a check fails, revise the scores instead of shipping the first draft.
</verification_loop>

<missing_context_gating>
Do not guess facts about the domain or technology that are not stated in the plan.
If required context is absent, flag it as a completeness gap rather than assuming.
</missing_context_gating>
```

Template fragments:

`{INCLUDE_DIG_DEEPER}` on R1:

```
<dig_deeper_nudge>
After finding the first plausible issues, check for second-order failures:
unstated assumptions, dependency chains, scaling limits, rollback gaps,
timeline realism, and what happens when the happy path breaks.
</dig_deeper_nudge>
```

On R2+, replace `{INCLUDE_DIG_DEEPER}` with an empty string.

`{INCLUDE_REBUTTAL_RULES}` on R2+:

```
Scoring rules for this round:
- Raise category scores where feedback was well-addressed.
- If their counterargument is strong, concede the point and adjust upward.
- If their counterargument is weak, hold your ground and explain why their
  defense is insufficient.
- Flag any NEW problems introduced by their changes.
- Do not repeat critiques that were adequately addressed.
- The score must reflect the CURRENT state of the plan, not your opinion of
  the original.
- Score against the agreed framework categories only.
- Any score increase must cite which critique was resolved and what plan
  text changed.
```

On R1, replace `{INCLUDE_REBUTTAL_RULES}` with an empty string.
