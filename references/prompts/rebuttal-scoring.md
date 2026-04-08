# Rebuttal Scoring Prompt — Phase 2, Rounds 2+

Delta-only prompt. Codex retains context from previous rounds via `--resume-last`.

Assemble the rebuttal text per `claude-debate-rules.md`, then submit via:
- If rebuttal < 500 chars: pass as positional argument to `task --resume-last "..."`
- If rebuttal >= 500 chars: write to session temp dir and use `task --resume-last --prompt-file ...`

The rebuttal itself should contain Claude's per-critique responses (with lifecycle
status updates) and the updated plan.

Wrap the scoring instruction in this XML header before the rebuttal content:

```xml
<task>
The plan author has responded to your critiques with a rebuttal and updated plan below.
Re-score the plan in its CURRENT state using the agreed framework.

Scoring rules:
- Raise category scores where feedback was well-addressed.
- If their counterargument is strong, concede the point and adjust upward.
- If their counterargument is weak, hold your ground and explain why their defense is insufficient.
- Flag any NEW problems introduced by their changes.
- Do not repeat critiques that were adequately addressed.
- The score must reflect the CURRENT state of the plan, not your opinion of the original.
- Score against the agreed framework categories only.
- Any score increase must cite which critique was resolved and what plan text changed.
</task>

<structured_output_contract>
{OUTPUT_CONTRACT}
</structured_output_contract>

<grounding_rules>
New critiques must reference specific parts of the updated plan or rebuttal.
Do not repeat addressed critiques unless the fix is inadequate.
Ground every claim in evidence from the plan text.
</grounding_rules>

<completeness_contract>
Re-examine the entire plan, not just the parts that changed.
Fixes in one area can expose new gaps elsewhere.
</completeness_contract>

<verification_loop>
Before finalizing, verify that score changes are justified:
- Points addressed well should yield higher category scores.
- New issues introduced should be reflected in lower scores.
- Overall score should track actual plan quality, not momentum or fatigue.
If a check fails, revise the scores instead of shipping the first draft.
</verification_loop>
```

Then append the rebuttal content after the XML blocks.
