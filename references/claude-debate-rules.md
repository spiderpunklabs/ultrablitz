# Claude Debate Rules

How Claude writes its rebuttal to Codex's critiques. The mechanical protocol
rules this file leans on are defined once in
`references/protocol-invariants.md` — they are cited here by ID, never
restated.

## Critique Lifecycle Tracking

Maintain the critique status ledger across rounds using the lifecycle states
defined in INV-LEDGER-1, keyed by the `UB-n` id Codex assigned (INV-ID-1).
Update the ledger after each rebuttal. The ledger feeds score reconciliation
(INV-SCORE-2), consensus detection (INV-TERM-2), stalemate detection
(INV-TERM-5), and the final Resolution Tracker in the summary.

Only findings `validate-output` reports under `admissibility.admitted` enter
the ledger on rounds 2+ (INV-ADMIT-1). A noted finding is shown to the user in
the round card and is not rebutted; if it is genuinely important, Codex can
re-raise it with a `Triggered-by` or `Missed-because` line next round.

### Re-Raising Rules

Re-raising a previously RESOLVED critique is governed by INV-LEDGER-3.
Re-raising a finding the USER resolved is gated mechanically by INV-LEDGER-2
— check that gate before engaging with the re-raise at all.

When refusing a pure re-raise, state: "UB-{n} was addressed in Round {M} with
{specific change}. No new evidence provided. Status remains RESOLVED."

## Response Structure

For each ledger entry Codex still holds, respond with ONE of:

### ACCEPTED → status: RESOLVED
> **UB-{n}: {summary}** — ACCEPTED → RESOLVED
> Change: {exactly what you changed in the plan and why}

### REJECTED → status: UNRESOLVED (unchanged)
> **UB-{n}: {summary}** — REJECTED → UNRESOLVED
> Counterargument: {why the original approach is better}
> Evidence: {specific reasoning, precedent, or constraint that supports your position}

### PARTIALLY ACCEPTED → status: PARTIALLY_RESOLVED
> **UB-{n}: {summary}** — PARTIALLY ACCEPTED → PARTIALLY_RESOLVED
> What I took: {the valid part of the critique}
> What I changed instead: {your alternative solution}
> Why not their suggestion: {why your approach is better than what Codex proposed}

### NEEDS_USER → status unchanged, `needsUser:true` (PARKED)
> **UB-{n}: {summary}** — NEEDS_USER → PARKED
> Decision required: {the one question only the user can answer}
> Options: {the two or three positions, one line each, with what each costs}

Use NEEDS_USER only when the disagreement turns on a decision outside the
plan's stated goals — scope, budget, risk appetite, a choice between two
designs the goals do not settle (INV-ESC-2). It is not a way to avoid a hard
argument: if the plan's own goals decide the question, argue it. A parked entry
is not rebutted again; tell Codex to hold its position and score on it. Parked
entries go to the user in the single termination batch (INV-ESC-1), never
mid-debate.

## Score Reconciliation Awareness

Score changes are enforced per INV-SCORE-2. When formulating rebuttals:
- If you ACCEPT a critique and change the plan, cite the change explicitly —
  a vague citation cannot be reconciled.
- If you REJECT a critique, no score increase is expected in that category.
- Never claim a resolution you did not actually make; it wastes a round.

## Debate Posture

- You represent the plan author. Defend the work with intellectual honesty.
- If Codex found a genuine flaw, accept it. Stubbornness on valid points wastes rounds.
- If Codex is nitpicking, manufacturing problems, or wrong, fight back hard. Cite specifics.
- You MUST push back on at least one point per round if you genuinely believe
  Codex is wrong. Do not capitulate on every point.
- But if every critique is genuinely valid, accept them all. Never reject valid
  points just to appear independent.
- Keep the updated plan coherent. Do not let it become a patchwork of fixes.
- After addressing all critiques, present the FULL updated plan (not cumulative diffs).
- When every CRITICAL and MAJOR entry is RESOLVED, do not invite new scope:
  send the confirmation turn (INV-TERM-4) and let the ledger close.

## Rebuttal Format

Structure your message to Codex as:

```
REBUTTAL — Round {N}

{For each ledger entry: your ACCEPTED/REJECTED/PARTIALLY ACCEPTED/NEEDS_USER
response with status, in UB-n order}

PARKED (do not re-argue; hold your position and score):
{UB-n list, or "none"}

UPDATED PLAN:
{The complete refined plan incorporating all accepted changes}

QUESTIONS FOR REVIEWER:
{Any clarifying questions about critiques you found ambiguous — max 2}
```
