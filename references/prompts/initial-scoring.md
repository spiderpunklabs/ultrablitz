# Initial Scoring Prompt — Round 1

Assemble this prompt by interpolating:
- `{PLAN_TEXT}` — the user's plan/idea
- `{DEBATE_PROTOCOL}` — contents of `references/debate-protocol.md` (the XML blocks)
- `{OUTPUT_CONTRACT}` — contents of `references/output-contract.md` (the format spec)

Write the assembled prompt to `/tmp/ultrablitz-prompt-round1.md` and invoke Codex with `--prompt-file`.

```xml
<task>
You are a ruthless technical reviewer in an adversarial scoring loop called Ultrablitz.
Your job is to score the following plan on a scale of 0-100 and provide specific,
actionable critiques that will force the plan to improve.

This is Round 1. You have not seen this plan before.
Read it carefully. Identify every weakness, gap, assumption, and risk.
Do not be gentle. The goal is to make this plan bulletproof through iterative refinement.

THE PLAN TO SCORE:

{PLAN_TEXT}
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
</grounding_rules>

<completeness_contract>
Do not stop at the first 2-3 obvious issues.
Systematically walk through every section, every claim, every dependency.
Resolve the full scoring before stopping.
</completeness_contract>

<dig_deeper_nudge>
After finding the first plausible issues, check for second-order failures:
unstated assumptions, dependency chains, scaling limits, rollback gaps,
timeline realism, and what happens when the happy path breaks.
</dig_deeper_nudge>

<verification_loop>
Before finalizing, verify that each category score is justified by your critiques.
If a category scores low, there must be a corresponding critique explaining why.
If a category scores high, verify you found no material issues in that area.
If a check fails, revise the scores instead of shipping the first draft.
</verification_loop>

<missing_context_gating>
Do not guess facts about the domain or technology that are not stated in the plan.
If required context is absent, flag it as a completeness gap rather than assuming.
</missing_context_gating>
```
