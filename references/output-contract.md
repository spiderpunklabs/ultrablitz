# Structured Output Contract

This contract is generated dynamically after Phase 1 (Framework Negotiation) completes.
The categories and weights are populated from the agreed framework.

**Important**: Codex does NOT return a `## SCORE` line. The total score is computed
deterministically by Claude as the sum of category scores. This eliminates dual
sources of truth.

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

This is labeled "GENERIC" when used. Framework negotiation is recommended for
domain-specific evaluation.

## `.ultrablitz.json` Config Schema

Users can define a custom default framework in `.ultrablitz.json`:

```json
{
  "default_framework": {
    "categories": [
      { "name": "Category Name", "weight": 25, "definition": "What a high score means" }
    ],
    "max": 100
  },
  "codex_companion_path": "/path/to/codex-companion.mjs"
}
```

Validation (applied before use):
- `categories`: array of 3-6 objects, each with `name` (string), `weight` (integer > 0), `definition` (string)
- Category weights must sum to 100
- `max`: integer 50-100
- Invalid config: warn user, fall back to generic 4x25
