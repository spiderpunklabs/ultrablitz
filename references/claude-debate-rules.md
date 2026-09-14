# Claude Debate Rules

How Claude writes its rebuttal to Codex's critiques. The mechanical protocol
rules this file leans on are defined once in
`references/protocol-invariants.md` — they are cited here by ID, never
restated.

## Critique Lifecycle Tracking

Maintain the critique status ledger across rounds using the lifecycle states
defined in INV-LEDGER-1 (UNRESOLVED, PARTIALLY_RESOLVED, RESOLVED, REGRESSED).
Update the ledger after each rebuttal. The ledger feeds:
- Score reconciliation — score changes must map to status changes (INV-SCORE-2)
- Consensus detection (per INV-TERM-2)
- The final Resolution Tracker in the summary

### Re-Raising Rules

Codex CAN re-raise a previously addressed critique if it provides new evidence
or argues the fix was inadequate; the critique's status moves to REGRESSED
(INV-LEDGER-1). Re-raising a finding the USER resolved is gated mechanically
by INV-LEDGER-2 — check that gate before engaging with the re-raise at all.

Pure recycling — same concern, no new evidence, even though the plan text was
already changed in that area — is flagged and not re-addressed. State: "Critique #{N} was addressed in
Round {M} with {specific change}. No new evidence provided. Status remains
RESOLVED."

## Response Structure

For each Codex critique, respond with ONE of:

### ACCEPTED → status: RESOLVED
> **Critique #{N}: {summary}** — ACCEPTED → RESOLVED
> Change: {exactly what you changed in the plan and why}

### REJECTED → status: UNRESOLVED (unchanged)
> **Critique #{N}: {summary}** — REJECTED → UNRESOLVED
> Counterargument: {why the original approach is better}
> Evidence: {specific reasoning, precedent, or constraint that supports your position}

### PARTIALLY ACCEPTED → status: PARTIALLY_RESOLVED
> **Critique #{N}: {summary}** — PARTIALLY ACCEPTED → PARTIALLY_RESOLVED
> What I took: {the valid part of the critique}
> What I changed instead: {your alternative solution}
> Why not their suggestion: {why your approach is better than what Codex proposed}

## Score Reconciliation Awareness

Score changes are enforced per INV-SCORE-2. When formulating rebuttals:
- If you ACCEPT a critique and change the plan, cite the change explicitly —
  the corresponding category increase in the next round is reconciled against
  this resolution, and a vague citation gets the delta BLOCKED.
- If you REJECT a critique, no score increase is expected in that category.
- Never claim a resolution you did not actually make; unbacked increases are
  BLOCKED and shown as unreconciled, which wastes a round.

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

## Rebuttal Format

Structure your message to Codex as:

```
REBUTTAL — Round {N}

{For each critique: your ACCEPTED/REJECTED/PARTIALLY ACCEPTED response with status}

UPDATED PLAN:
{The complete refined plan incorporating all accepted changes}

QUESTIONS FOR REVIEWER:
{Any clarifying questions about critiques you found ambiguous — max 2}
```
