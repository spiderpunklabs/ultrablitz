# Protocol Invariants

This file is the SINGLE normative home for every mechanical rule of the
ultrablitz protocol. Each invariant has a stable ID and one normative
paragraph. Every other document — SKILL.md, the other references, the prompt
templates — cites these IDs and never restates the rule; where a paraphrase
elsewhere disagrees with this file, this file wins.

Definition convention: each invariant is a `### INV-…` heading. The doc-lint
suite (`tests/doc-lint.sh`) enforces that every cited ID is defined here and
warns on defined-but-never-cited IDs.

## Scoring

### INV-SCORE-1 — Total is the capped category sum

The authoritative total score for a round is computed deterministically by
Claude as the sum of the category scores Codex emitted, capped at the locked
framework's theoretical maximum: `total = min(sum(categories), max)`. Codex
never emits a total line, so there is exactly one source of truth. When the
cap is active (raw sum exceeds the max), the individual category scores are
labelled **diagnostic** — they explain where the points came from but are not
individually authoritative — and the authoritative total is the cap, displayed
as `Score: {max}/{max} (raw: {sum}, capped at theoretical max)`.

### INV-SCORE-2 — Score reconciliation

Every category score delta between consecutive authoritative rounds must be
evidence-backed. A category **increase** requires at least one critique in
that category marked RESOLVED in the current round with a specific plan change
cited; if no such mapping exists, the increase is **BLOCKED** and the
authoritative value for that category remains the prior round's value (the
model's number may be shown separately as "proposed (unreconciled)"). A
category **decrease** requires a new critique or a REGRESSED critique in that
category; if no such mapping exists, the decrease is **BLOCKED** and the prior
value stands. The score displayed to the user is always the reconciled,
evidence-backed one, and reconciliation results appear in the round card.

## Cap Events and Recalibration

### INV-CAP-1 — Framework consistency check

A cap event (raw category sum exceeding the theoretical max) triggers a
**framework consistency check** when ANY of these fire: (a) the overflow
exceeds the weight of the smallest category; (b) the overflow is greater than
or equal to `ceil(0.05 * theoretical_max)`; or (c) two or more cap events have
occurred across rounds. A triggered check **blocks consensus** until it is
resolved — either through a recalibration motion (INV-CAP-2) or the user's
explicit acceptance of the current framework. Overshoots below all three
thresholds are capped silently as single-category-scale variance, not treated
as a framework defect.

### INV-CAP-2 — Theoretical max is locked; recalibration motion

The theoretical maximum is locked when Phase 1 completes and may change during
Phase 2 only via a formal recalibration motion on exactly two admissible
grounds: (1) **ceiling too low** — a critique demonstrates a previously
excluded capability or plan path consistent with the agreed domain; or
(2) **ceiling too high** — a critique demonstrates a newly recognized hard
constraint that materially reduces achievable performance. Both evaluators
must agree for the motion to pass; if they disagree, the round is marked
"framework disputed" and the pre-motion max remains authoritative. The user is
the tiebreaker (accept, reject, or set a custom max that itself states one of
the two grounds); if the user does not respond, the pre-motion max holds. At
most one recalibration per evaluation unless new objective evidence surfaces,
and every recalibration records prior max, new max, ground, reason, and
whether prior scores need reinterpretation.

## Critique Ledger

### INV-LEDGER-1 — Critique lifecycle states

Every critique in the ledger is in exactly one of four states:
**UNRESOLVED** — active critique, not yet addressed; **PARTIALLY_RESOLVED** —
addressed but the fix is incomplete (counts as unresolved for termination, per
INV-TERM-1); **RESOLVED** — fully addressed with a specific plan change; and
**REGRESSED** — previously resolved, re-opened with new evidence or an
argument that the fix was inadequate. Only these four states exist, and every
state change is recorded in the ledger with the round in which it happened.

### INV-LEDGER-2 — Re-raise gate for user-resolved findings

A finding the user resolved (via per-finding escalation or a user-mediated
termination path) may be re-raised only if the new critique cites specific
plan text that was added or modified AFTER the round in which the user
resolved it. Claude checks mechanically: does the critique reference a plan
diff from a later round? If yes, the re-raise is allowed under a fresh linked
ID (e.g. UB-7b). If no, the re-raise is rejected automatically — no debate, no
ledger change.

## Termination

### INV-TERM-1 — Termination precedence and the no-silent-drop rule

Termination paths are evaluated in strict precedence order: (1) Consensus,
(2) user abort, (3) hard cap, (4) stalemate, (5) regression. The core
invariant across all five: **no termination path silently drops unresolved
findings** — every path either requires all findings RESOLVED or obtains
explicit user sign-off on each finding that is not, and the final summary
lists every finding that was not fully resolved. PARTIALLY_RESOLVED counts as
unresolved for termination purposes; its distinct label is documentary only.

### INV-TERM-2 — Consensus condition

Consensus is mechanical and requires all three of: (a) the authoritative score
is within 3% of the theoretical maximum; (b) zero UNRESOLVED or REGRESSED
critiques of ANY severity — CRITICAL, MAJOR and MINOR alike must all be fully
RESOLVED; and (c) zero blocked score deltas in the current round. No finding
may be skipped or waived on severity grounds, and a pending framework
consistency check (INV-CAP-1) blocks consensus regardless.

### INV-TERM-3 — Degraded and advisory runs never reach Consensus

A run marked DEGRADED (e.g. after a continuity re-seed per INV-CONT-2) or
ADVISORY (e.g. validation could not be enforced) can never terminate by
Consensus, whatever its score or ledger state. Its only terminal states are
`DEGRADED COMPLETE — <reason>` and `ADVISORY COMPLETE`, and every artifact
persisted from such a run carries `authoritative:false` so downstream
consumers cannot mistake it for a consensus result.

## Continuity

### INV-CONT-1 — Per-turn identity verification

Every Codex turn must verify BOTH the threadId and the codexSessionId of the
response against the values recorded in the session state. A mismatch in
either is a CONTINUITY failure: the round is discarded with no state mutation
(no ledger update, no score update, no round increment — per INV-FAIL-1), and
the failure is surfaced rather than papered over.

### INV-CONT-2 — Continuity loss is a user decision

When continuity is lost, the choice belongs to the user, presented as exactly
two options: (1) **stop here** — the run terminates and is authoritative
through the last fully validated round N; or (2) **continue DEGRADED** — the
debate is re-seeded onto a fresh thread exactly once (Debate State Summary as
seed), and the run is marked DEGRADED from that point (see INV-TERM-3). A
second continuity failure after the one permitted re-seed is FATAL: the run
aborts, and all prior validated rounds remain preserved and displayed.

## Format Repair

### INV-FORMAT-1 — Bounded format repair

The format-repair stub is a fixed template with exactly three interpolation
slots: the expected section headers, the category list with per-category
bounds, and the offending output quoted verbatim. It carries no debate
protocol blocks and no plan text. At most ONE repair turn is permitted per
round. The repaired output must preserve the pre-repair score vector and
critique count — a repair may fix shape only, never substance — otherwise the
turn is a FORMAT failure. Rounds that went through repair are recorded with
`formatRepair:true` and listed in the debate log.

## Failure Classes

### INV-FAIL-1 — Failure classes never mutate state

Turn failures are classified as RETRYABLE (transient launch/timeout/empty
output — retry is permitted), CONTINUITY (identity mismatch per INV-CONT-1 —
handled per INV-CONT-2), FORMAT (output failed validation and could not be
repaired within INV-FORMAT-1 — escalate), or FATAL (companion missing, auth
failure, unrecoverable state — abort with prior rounds preserved). None of
these mutates the ledger, the scores, or the session round counter. Only a
fully validated turn mutates debate state.

## Round Counting

### INV-ROUND-1 — attemptCount vs authoritativeRound

`attemptCount` counts every Codex call, including retries and repair turns.
`authoritativeRound` counts only fully validated rounds — the ones that
mutated debate state per INV-FAIL-1. Round caps, soft targets, and stalemate
detection are computed from `authoritativeRound` ONLY; attempts never burn
rounds. When the two differ, the display shows both (e.g. "Round 3/5
(attempt 4)").

## Implementation Authority

### INV-A9 — The subcommands are the implementation

SKILL.md must invoke the `ultrablitz-utils.sh` subcommands by name
(`session-new`, `codex-turn`, `validate-output`, `gate-arm`, …) and must never
restate their internals — no inline reimplementation of validation, locking,
session I/O, or gate logic in prose or ad-hoc Bash. The subcommands are the
normative implementation; if SKILL.md's description and a subcommand's
behavior diverge, the subcommand wins and SKILL.md is the bug.

## Model selection

### INV-MODEL-1 — Explicit model choices are never auto-changed

The model for a run is resolved once, before the first debate turn, in this
order: `--model` flag, then `ULTRABLITZ_MODEL`, then `.ultrablitz.json`'s
`model` key, then the built-in newest-first preference list, then the
companion's own default. A model named by the user (flag or environment) is
**explicit** and is never substituted: if the account refuses it, the run stops
and reports the refusal with alternatives. Only a model chosen from the
preference list may be downgraded, at most once per turn, and only on a
recognised refusal (HTTP 400 `invalid_request_error` naming the model) or, once
per run, on an unrecognised 400 (recorded as `modelSelectionUnknown`). Every
substitution is written to `session.json` in the same step that performs it; if
that write fails the run aborts rather than proceed with state that names a
different model than the one in use. The resolved model is reported in the
final summary and the persisted artifacts, because a score is not comparable
across models.

## Budget

### INV-BUDGET-1 — Prompt budget

The maximum assembled prompt size is 30,000 characters, hard. Plan text over
20,000 characters is replaced in the prompt by a Plan Digest (key sections,
decisions, open questions) with the full plan stored in the session directory
and referenced from the Debate State Summary; if Codex critiques digested
text, the affected section is included verbatim in the next round. When active
findings overflow the remaining budget, they are capped at the top 10 by
severity (CRITICAL, then MAJOR, then MINOR) and the rest are referenced by ID
only.
