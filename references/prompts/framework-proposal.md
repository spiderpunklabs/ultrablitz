# Framework Proposal Prompt — Phase 1, Round 1

Claude proposes a scoring framework to Codex for debate. This is the first step
before any plan evaluation begins.

Assemble this prompt by interpolating:
- `{PLAN_SUMMARY}` — a brief summary of the plan/idea to be evaluated (enough context for Codex to understand the domain)
- `{DEBATE_PROTOCOL}` — tone/stance blocks from `references/debate-protocol.md`

Write the assembled prompt to the session temp directory and invoke Codex with `--prompt-file`.

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
Return your response in EXACTLY this format:

## FRAMEWORK VERDICT: ACCEPT | REJECT | COUNTER-PROPOSE

## CATEGORY ASSESSMENT:
For each proposed category:
- {Category}: ACCEPT | REJECT | MODIFY
  - If REJECT/MODIFY: why, and what to replace/change it with

## WEIGHT ASSESSMENT:
- Are the weights appropriate for this domain? If not, propose alternatives with justification.

## THEORETICAL MAXIMUM:
- What is the realistic maximum score for a plan in this domain, and why?
- If you disagree with the proposed maximum, state yours with evidence.

## MISSING DIMENSIONS:
- Are there evaluation dimensions critical to this domain that the framework omits?

## PROPOSED CHANGES:
{If REJECT or COUNTER-PROPOSE: your complete alternative or modified framework}

## RATIONALE:
{One paragraph: why this framework is or isn't appropriate for the domain}
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
