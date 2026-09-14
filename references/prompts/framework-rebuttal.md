# Framework Rebuttal Prompt — Phase 1, Rounds 2+

Delta prompt for framework negotiation rounds after the first; Claude's framework rebuttal content is APPENDED after the fenced block.
Slots: `{FRAMEWORK_CONTRACT}` (the Phase 1 contract in `references/output-contract.md`).

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
{FRAMEWORK_CONTRACT}
</structured_output_contract>

<grounding_rules>
Do not repeat resolved disagreements.
New objections must reference specific framework elements.
</grounding_rules>
```
