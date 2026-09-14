# Structured Output Contract

## Phase 1 contract — interpolated as {FRAMEWORK_CONTRACT}

The single source of truth for the Phase 1 (Framework Negotiation) output shape.
Both Phase 1 prompt templates (`framework-proposal.md`, `framework-rebuttal.md`)
interpolate this block verbatim into their `<structured_output_contract>` tags,
so round 1 and rounds 2+ demand the same shape.

```
Return your response in EXACTLY this format:

## FRAMEWORK VERDICT: ACCEPT | REJECT | COUNTER-PROPOSE

## CATEGORY ASSESSMENT:
For each category:
- {Category}: ACCEPT | REJECT | MODIFY
  - If REJECT/MODIFY: why, and what to replace/change it with

## WEIGHT ASSESSMENT:
- Are the weights appropriate for this domain? If not, propose alternatives with justification.

## THEORETICAL MAXIMUM:
- Your position on the realistic maximum score for a plan in this domain, and why.
- If you disagree with the proposed maximum, state yours with evidence.

## MISSING DIMENSIONS:
- Evaluation dimensions critical to this domain that the framework omits.
- In rounds after the first, "- None." is a complete and legitimate answer.

## PROPOSED CHANGES:
{Only if REJECT or COUNTER-PROPOSE: your complete alternative or modified framework}

## RATIONALE:
{One paragraph: why this framework is or isn't appropriate for the domain}
```

## Phase 2 contract

This contract is generated dynamically after Phase 1 (Framework Negotiation)
completes. The categories and weights are populated from the agreed framework.
It defines the SHAPE of Codex's output only; the scoring semantics live in
`references/protocol-invariants.md`.

**Important**: Codex does NOT return a `## SCORE` line. Per INV-SCORE-1, the
authoritative total is computed by Claude from the category scores (capped at
the theoretical max), so the contract deliberately contains no total slot —
one source of truth. Malformed output is repaired within the bounds of
INV-FORMAT-1, and validation is performed by the `validate-output` subcommand
(INV-A9), not by ad-hoc parsing.

## Template

Interpolate into `<structured_output_contract>` blocks during Phase 2.
Replace `{CATEGORIES}` with the agreed categories and weights.

```
Return your response in EXACTLY this format. Do not deviate.
Do NOT include a total score line — it will be computed from your category scores.

## CATEGORY SCORES:
{CATEGORIES}

## CRITIQUES:
{Numbered list. Each critique MUST include all four fields:}
1. **[CRITICAL|MAJOR|MINOR]** {One-line summary}
   - Evidence: {Specific plan text or gap that is problematic}
   - Impact: {What goes wrong if this is not addressed}
   - Suggestion: {Concrete improvement — not vague hand-waving}

## STRENGTHS:
{2-3 max, one line each — genuine strengths only}

## VERDICT:
{One paragraph: would you ship/execute this as-is? What is the single biggest risk?}
```

## Default Framework (used when `--skip-framework` and no `.ultrablitz.json` config)

```
- Feasibility: {0-25} — Can this actually be built/executed with the stated resources and constraints?
- Completeness: {0-25} — Are all edge cases, failure modes, and dependencies addressed?
- Correctness: {0-25} — Is the technical approach sound? Will it produce the intended result?
- Elegance: {0-25} — Is this the simplest approach that could work? Is there unnecessary complexity?

Theoretical Maximum: 100
```

This is labeled "GENERIC" when used.

## `.ultrablitz.json` Config Schema

Users can define a custom default framework in `.ultrablitz.json`.

**Lookup order**: the repo root first, then the current working directory —
the first file found wins. These are the only two locations checked.

```json
{
  "default_framework": {
    "categories": [
      { "name": "Category Name", "weight": 25, "definition": "What a high score means" }
    ],
    "max": 100
  }
}
```

`default_framework` is the only supported key.

Validation (applied before use):
- `categories`: array of 3-6 objects, each with `name` (string), `weight` (integer > 0), `definition` (string)
- Category weights must sum to 100
- `max`: integer 50-100
- Invalid config: warn user, fall back to generic 4x25
- Unknown keys: warn and ignore (the framework itself is still used if valid)
