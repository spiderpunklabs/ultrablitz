# Framework Prompt — Phase 1 (all rounds)

Single parametric prompt for framework negotiation. Round 1 is sent as a fresh
task; rounds 2+ are sent over `--resume-last`. The same template handles both;
the round-conditional blocks are gated by the placeholders below.

Assemble by interpolating:
- `{ROUND_CONTEXT}` — R1: "Your counterpart (Claude) proposes the following
  scoring framework. Your job is to challenge it." R2+: "The framework
  proposer has responded. Re-evaluate the framework in its current state."
- `{PLAN_SUMMARY}` — R1 only: 2-3 sentence plan/domain summary (empty on R2+,
  Codex retains it via the resumed thread).
- `{FRAMEWORK_PROPOSAL}` — R1: Claude's proposed framework. R2+: Claude's
  rebuttal text (per-objection responses + revised framework).
- `{FRAMEWORK_CONTRACT}` — the Phase 1 contract block from
  `references/output-contract.md`, verbatim, every round. Its MISSING
  DIMENSIONS section already says "- None." is complete on rounds 2+.
- `{DEBATE_PROTOCOL}` — tone blocks from `references/debate-protocol.md`.

Write the assembled prompt to:
- R1: `<session>/p1-r1-framework.md`
- R2+: `<session>/p1-r<N>-claude-response.md`

Always `.md`. Send with `codex-turn` (R1 without `--resume`, R2+ with it).

```xml
<task>
{ROUND_CONTEXT}

{PLAN_SUMMARY}

Do not accept the framework passively. If categories are wrong, say so.
If weights are unbalanced, fight for better ones. If the theoretical maximum
is too high or too low, argue why.

We continue debating the framework until both sides reach ACCEPT. Only then
do we move to evaluating the actual plan. You MUST reach ACCEPT or
COUNTER-PROPOSE — do not stall. ACCEPT means you are genuinely satisfied
this framework will produce meaningful evaluation of plans in this domain.
Do not accept to be agreeable.

FRAMEWORK UNDER REVIEW:

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
On rounds after the first: do not repeat resolved disagreements, and new
objections must reference specific framework elements.
</grounding_rules>

<completeness_contract>
Evaluate every aspect of the proposed framework: categories, weights,
theoretical maximum, and any missing dimensions.
Do not stop at surface-level acceptance.
</completeness_contract>
```
