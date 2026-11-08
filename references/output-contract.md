# Structured Output Contract

## Phase 1 contract — interpolated as {FRAMEWORK_CONTRACT}

The single source of truth for the Phase 1 (Framework Negotiation) output shape.
The Phase 1 prompt template (`framework-prompt.md`, used on every round)
interpolates this block verbatim into its `<structured_output_contract>` tag,
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

## ATTACK SURFACE:
- The 3-8 failure classes specific to THIS plan's domain that the scoring rounds
  must probe first, one line each, concrete ("double charge on payment retry",
  not "reliability"). Accept, drop, or add to the proposer's list with a reason.
- In rounds after the first, "- Unchanged." is a complete and legitimate answer.

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
completes, by the `render-contract` subcommand — never hand-typed (INV-A9):

```bash
bash "$UB" render-contract --contract "$SD/framework.json" --round "$N"
```

The categories and weights come from the locked framework; the round picks
which fragment is spliced in (round 1 carries the edge-case sweep per
INV-SWEEP-1, rounds 2+ carry the admissibility rules per INV-ADMIT-1). It
defines the SHAPE of Codex's output only; the scoring semantics live in
`references/protocol-invariants.md`.

**Important**: Codex does NOT return a `## SCORE` line. Per INV-SCORE-1, the
authoritative total is computed by Claude from the category scores (capped at
the theoretical max), so the contract deliberately contains no total slot —
one source of truth. Malformed output is repaired within the bounds of
INV-FORMAT-1, and validation is performed by the `validate-output` subcommand
(INV-A9), not by ad-hoc parsing. Critique identity (`UB-n`, `Category:`) is
enforced per INV-ID-1.

### Phase 2 contract — base template

`render-contract` expands `{CATEGORIES}` from the framework, `{ROUND_PRE}` to
the round 1 fragment (empty on rounds 2+), `{ROUND_POST}` to the rounds 2+
fragment (empty on round 1) and `{EDGE_CASE_CLASSES}` to the fixed class list.

```
Return your response in EXACTLY this format. Do not deviate.
Do NOT include a total score line — it will be computed from your category scores.

## CATEGORY SCORES:
{CATEGORIES}

{ROUND_PRE}
## CRITIQUES:
{One entry per finding. Ids are UB-n: continue the run's sequence from the
highest id you have used so far, never reuse an id and never renumber an
earlier finding, even when it is resolved. Every entry MUST carry all five
lines below. Write "- None." when you have no findings.}
UB-{n} **[CRITICAL|MAJOR|MINOR]** {One-line summary}
   - Category: {exactly one category name, spelled as in CATEGORY SCORES}
   - Evidence: {Specific plan text or gap that is problematic}
   - Impact: {What goes wrong if this is not addressed}
   - Suggestion: {Concrete improvement — not vague hand-waving}

Severity: CRITICAL — executed as written, the plan fails its stated goal or
causes harm that cannot be rolled back. MAJOR — a material defect that must be
fixed before execution; a workaround exists. MINOR — a real but contained
weakness; execution could proceed with it open.
{ROUND_POST}
## STRENGTHS:
{2-3 max, one line each — genuine strengths only}

## VERDICT:
{One paragraph: would you ship/execute this as-is? What is the single biggest risk?}
```

### Phase 2 — round 1 fragment

Spliced in as `{ROUND_PRE}` on round 1 only (INV-SWEEP-1). Every class must
appear exactly once, in this order, with one of the three statuses.

```
## EDGE CASE SWEEP:
{One line per class, every class present, this exact order and spelling:}
{EDGE_CASE_CLASSES}
{COVERED = the plan handles it; say where. UNCOVERED = it does not; you MUST
raise a critique for it and name that UB-n on this line. N-A = the class cannot
apply to this plan; say why in a clause. Walk the sweep BEFORE writing the
critiques so the critique list is complete.}
```

### Phase 2 — rounds 2+ fragment

Spliced in as `{ROUND_POST}` on rounds 2 and later (INV-ADMIT-1).

```
Rules for findings NEW on this round (any id above the highest id already in play):
- Directly under its Category line, a new finding MUST carry exactly one of:
   - Triggered-by: UB-{m} — the change made for UB-{m} created or exposed it
   - Missed-because: {what round 1 could not see} — CRITICAL or MAJOR only
- A new finding that carries neither line is NOT admitted to the ledger. Do
  not give it a UB id; put it under ## NOTES as a plain bullet instead.
- Existing findings keep their id. Restate each one you still hold, with its
  current severity; say in one clause why the author's response did not
  resolve it.

## NOTES:
{Observations below the admissibility bar, plain bullets, no UB id, no
Evidence/Impact/Suggestion lines. "- None." when empty.}
```

### Edge-case classes

The fixed classes are defined once, in `hooks/ultrablitz-utils.sh`
(`UB_SWEEP_CLASSES`); `render-contract` prints them and `validate-output
--round 1` requires every one of them:

```
empty-or-none  scale  concurrency  partial-failure-and-rollback
permissions-and-identity  time-and-ordering  external-dependency-down
human-misuse  migration-and-compat
```

## Default Framework (used when `--skip-framework` and no `.ultrablitz.json` config)

```
- Feasibility: {0-25} — Can this actually be built/executed with the stated resources and constraints?
- Completeness: {0-25} — Are all edge cases, failure modes, and dependencies addressed?
- Correctness: {0-25} — Is the technical approach sound? Will it produce the intended result?
- Elegance: {0-25} — Is this the simplest approach that could work? Is there unnecessary complexity?

Theoretical Maximum: 100
```

This is labeled "GENERIC" when used. It carries no `attackSurface`, so the
`{ATTACK_SURFACE}` slot renders its generic fallback line (INV-SURFACE-1).

## `framework.json` (the locked contract)

Written by Claude at the end of Phase 1 into the session dir and passed to
`codex-turn --contract`, `validate-output --contract` and `render-contract
--contract`:

```json
{
  "categories": [ { "name": "Category Name", "weight": 25, "definition": "What a high score means" } ],
  "max": 96,
  "attackSurface": [ "concrete failure class 1", "concrete failure class 2", "concrete failure class 3" ]
}
```

`attackSurface` holds the 3–8 lines agreed in Phase 1 (INV-SURFACE-1). It is
optional only for a `--skip-framework` run.

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
    "max": 100,
    "attackSurface": [ "optional, 3-8 one-line failure classes" ]
  }
}
```

`default_framework` is the only supported key.

Validation (applied before use):
- `categories`: array of 3-6 objects, each with `name` (string), `weight` (integer > 0), `definition` (string)
- Category weights must sum to 100
- `max`: integer 50-100
- `attackSurface` (optional): array of 3-8 non-empty strings
- Invalid config: warn user, fall back to generic 4x25
- Unknown keys: warn and ignore (the framework itself is still used if valid)
