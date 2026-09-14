# Framework Proposal Prompt — Phase 1, Round 1

Sends Claude's proposed scoring framework to Codex for critique.
Slots: `{PLAN_SUMMARY}`, `{FRAMEWORK_PROPOSAL}`, `{DEBATE_PROTOCOL}`, and `{FRAMEWORK_CONTRACT}` (the Phase 1 contract in `references/output-contract.md`).

```xml
<task>
You are entering Phase 1 of an adversarial debate loop called Ultrablitz.
Before we evaluate any plan, we must first agree on the EVALUATION FRAMEWORK.

The plan we will eventually evaluate is in this domain:

{PLAN_SUMMARY}

Your counterpart (Claude) proposes the following scoring framework.
Your job is to challenge it: argue about the categories, weights, theoretical
maximum, and what should matter most for evaluating a plan in this domain.

Do not accept the framework passively. If categories are wrong, say so.
If weights are unbalanced, fight for better ones. If the theoretical maximum
is too high or too low, argue why.

We continue debating the framework until both sides agree. Only then do we
move to evaluating the actual plan.

PROPOSED FRAMEWORK:

{FRAMEWORK_PROPOSAL}
</task>

{DEBATE_PROTOCOL}

<structured_output_contract>
{FRAMEWORK_CONTRACT}
</structured_output_contract>

<grounding_rules>
Ground your assessment in the specific domain described.
Do not apply generic rubrics — tailor your critique to what actually matters
for evaluating plans in this area.
If you accept a category, briefly state why it fits.
If you reject one, explain what real evaluation need it fails to capture.
</grounding_rules>

<completeness_contract>
Evaluate every aspect of the proposed framework: categories, weights,
theoretical maximum, and any missing dimensions.
Do not stop at surface-level acceptance.
</completeness_contract>
```
