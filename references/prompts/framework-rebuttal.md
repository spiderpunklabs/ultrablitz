# Framework Rebuttal Prompt — Phase 1, Rounds 2+

Delta-only prompt for framework negotiation rounds after the initial proposal.
Codex retains context via `--resume-last`.

Claude responds to Codex's framework critique, then Codex re-evaluates.
Loop continues until both sides reach ACCEPT.

```xml
<task>
The framework proposer has responded to your critique.
Re-evaluate the framework in its current state.

Rules:
- If their changes address your concerns, move toward ACCEPT.
- If their counterargument is strong, concede and adjust.
- If their counterargument is weak, hold your ground.
- You MUST reach ACCEPT or COUNTER-PROPOSE — do not stall.
- ACCEPT means you are genuinely satisfied this framework will produce
  meaningful evaluation of plans in this domain. Do not accept to be agreeable.
</task>

<structured_output_contract>
## FRAMEWORK VERDICT: ACCEPT | REJECT | COUNTER-PROPOSE

## CATEGORY ASSESSMENT:
For each category:
- {Category}: ACCEPT | REJECT | MODIFY
  - Reasoning if not ACCEPT

## WEIGHT ASSESSMENT:
- Assessment of current weights

## THEORETICAL MAXIMUM:
- Your position on the maximum achievable score

## PROPOSED CHANGES:
{Only if REJECT or COUNTER-PROPOSE}

## RATIONALE:
{One paragraph}
</structured_output_contract>

<grounding_rules>
Do not repeat resolved disagreements.
New objections must reference specific framework elements.
</grounding_rules>
```

Then append Claude's framework rebuttal content.
