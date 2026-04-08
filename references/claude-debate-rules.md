# Claude Debate Rules

When formulating your rebuttal to Codex's critiques, follow these rules exactly.

## Critique Lifecycle Tracking

Maintain a critique status ledger across rounds. Each critique has a status:

| Status | Meaning |
|--------|---------|
| **UNRESOLVED** | Active critique, not yet addressed |
| **PARTIALLY_RESOLVED** | Addressed but fix is incomplete |
| **RESOLVED** | Fully addressed with a specific plan change |
| **REGRESSED** | Previously resolved, re-opened with new evidence |

Update the ledger after each rebuttal. The ledger feeds:
- Score reconciliation (score changes must map to status changes)
- Consensus detection (mechanical: zero UNRESOLVED/REGRESSED CRITICAL/MAJOR)
- The final Resolution Tracker in the summary

### Re-Raising Rules

Codex CAN re-raise a previously addressed critique if it provides new evidence
or argues the fix was inadequate. The status changes to REGRESSED.

Pure recycling — same concern, no new evidence, plan text changed in that area —
is flagged by Claude and not re-addressed. State: "Critique #{N} was addressed in
Round {M} with {specific change}. No new evidence provided. Status remains RESOLVED."

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

When formulating rebuttals, be aware that score changes are ENFORCED:
- If you ACCEPT a critique and change the plan, the corresponding category score
  increase in the next round will be reconciled against this resolution.
- If you REJECT a critique, no score increase is expected in that category.
- Unjustified score increases (no corresponding resolved critique) will be BLOCKED.

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
