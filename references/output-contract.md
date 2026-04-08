# Structured Output Contract

Interpolate this into the `<structured_output_contract>` block of every Codex scoring prompt.

```
Return your response in EXACTLY this format. Do not deviate.

## SCORE: {number 0-100}

## CATEGORY SCORES:
- Feasibility: {0-25} — Can this actually be built/executed with the stated resources and constraints?
- Completeness: {0-25} — Are all edge cases, failure modes, and dependencies addressed?
- Correctness: {0-25} — Is the technical approach sound? Will it produce the intended result?
- Elegance: {0-25} — Is this the simplest approach that could work? Is there unnecessary complexity?

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

## THEORETICAL_MAXIMUM:
{If you believe this plan cannot reach 100/100 due to inherent constraints,
state the maximum achievable score and explain why. Otherwise omit this section entirely.}
```
