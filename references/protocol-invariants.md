# Protocol Invariants

This file is the SINGLE normative home for every mechanical rule of the
ultrablitz protocol. Each invariant has a stable ID and one normative
paragraph. Every other document — SKILL.md, the other references, the prompt
templates — cites these IDs and never restates the rule; where a paraphrase
elsewhere disagrees with this file, this file wins.

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

### INV-CAP-1 — Cap events are recorded, never hidden

A **cap event** is a round whose raw category sum exceeds the theoretical max.
Every cap event is recorded in the ledger with the round, the raw sum, and the
overflow, and the round card shows the capped total alongside the raw sum. A
cap event is evidence about the framework, not about the plan: it never raises
the authoritative score above the max (INV-SCORE-1), and it never by itself
changes any ledger status. An unanswered cap question (INV-CAP-2) blocks
consensus until the user has answered it.

### INV-CAP-2 — Theoretical max is locked; one user question per run

The theoretical maximum is locked when Phase 1 completes. During Phase 2 it can
change only by the user's answer to a single question, asked once per run, on
the **first** cap event: *keep the agreed max* or *raise it to the raw sum of
this round*. Claude states the raw sum, the max, and which categories drove the
overflow, then asks. If the user raises the max, the new max applies from that
round on and is recorded (prior max, new max, round, reason); prior rounds are
not rescored. If the user keeps it, or does not answer, the max holds and every
later cap event in the run is capped silently (still recorded per INV-CAP-1).
There is no second question and no recalibration motion between evaluators.

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

A finding the user resolved (via the termination batch of INV-ESC-1 or any
other user-mediated path) may be re-raised only if the new critique cites specific
plan text that was added or modified AFTER the round in which the user
resolved it. Claude checks mechanically: does the critique reference a plan
diff from a later round? If yes, the re-raise is allowed under a fresh id (the
next UB-n per INV-ID-1, recorded in the ledger as linked to the original). If
no, the re-raise is rejected automatically — no debate, no ledger change.

### INV-LEDGER-3 — Pure recycling is refused

A previously RESOLVED critique that is re-raised with no new evidence and no
relevant plan change since its resolution is refused, and the critique keeps
its RESOLVED status — no debate, no ledger change. A re-raise that does carry
new evidence, or an argument that the fix was inadequate, moves the critique
to REGRESSED per INV-LEDGER-1.

### INV-ID-1 — Stable critique identity

Every critique carries a run-unique id `UB-n`, assigned by Codex when it first
raises the finding by continuing from the highest id in play. Ids are never
reused and never renumbered — a RESOLVED finding keeps its id for the rest of
the run. Every entry names exactly one `Category:` spelled as in the locked
framework and one of the three severities defined in the output contract
(CRITICAL: the plan fails its goal or causes irreversible harm; MAJOR: a
material defect with a workaround that must be fixed before execution; MINOR:
a real but contained weakness). `validate-output` fails a turn whose critiques
lack an id, repeat an id, break the new-id sequence, or name a category outside
the framework; a failure is a FORMAT failure (INV-FAIL-1). A line in the
CRITIQUES section that carries a UB id or a severity tag but does not parse as
an entry header, a field line outside any entry, a field repeated within one
entry, and a CRITIQUES section with neither an entry nor `- None.` are
failures too: no finding is ever dropped silently. The ledger, round cards,
rebuttals and final summary refer to findings by this id only.

## Anti-Gaming

### INV-GAME-1 — Anti-gaming controls

Three controls apply throughout Phase 2. (1) Every third round, Codex must
restate its single strongest remaining concern from first principles.
(2) Critiques are judged by specificity, not length. (3) Anchoring guard: if
Round 1's authoritative score was under 30% of the theoretical maximum, no
later round may increase the authoritative score by more than 25% of the
theoretical maximum in a single round unless the jump is backed by
proportionate critique resolutions.

## Escalation

### INV-ESC-1 — Escalation is batched at termination

Findings are never escalated to the user one at a time during the debate. When
a run terminates by hard cap or stalemate (INV-TERM-1), every finding that is
not RESOLVED is presented to the user in **one batch**, each with Codex's
position, Claude's position, and the round history, and the user rules on each
(accept Codex, accept Claude, or dictate). Those rulings are recorded in the
ledger as user-resolved and are then protected by the re-raise gate of
INV-LEDGER-2. The debate does not resume after the batch; the refined plan is
updated with the rulings and the run proceeds to the gate.

### INV-ESC-2 — NEEDS_USER is a parked disposition, batched with the rest

Claude may mark a critique NEEDS_USER when its resolution turns on a decision
only the user can make — product scope, budget, risk appetite, or a choice
between two designs that the plan's stated goals do not settle. The entry keeps
its INV-LEDGER-1 state and gains `needsUser:true`: it is **parked**. Claude does
not rebut it further, Codex is told to hold its position and its score on it,
and the parked entry counts as unresolved for termination (INV-TERM-1). Parked
entries are never asked about mid-debate; they go to the user with the
INV-ESC-1 batch in ONE AskUserQuestion at termination. When at least one entry
is parked and every entry that is not RESOLVED is parked, the run terminates at
once by stalemate (INV-TERM-5) rather than spend rounds re-arguing a question
only the user can answer. A ledger with every entry RESOLVED is never a
stalemate; it goes to the confirmation turn (INV-TERM-4).

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

### INV-TERM-4 — Confirm-only final turn

When, after Claude's rebuttal, every CRITICAL and MAJOR ledger entry is
RESOLVED and none is REGRESSED, the next Codex turn is a **confirmation turn**:
`codex-turn --round N --confirm-only` (N >= 2; round 1 is never confirm-only)
with the confirmation `{ROUND_CONTEXT}`. Codex confirms each RESOLVED entry
against the current plan text or REGRESSES it with evidence, holds or drops
each open MINOR entry against the changes in this rebuttal, and re-scores.
Ledger states still change only as INV-LEDGER-1 says: Claude resolves an entry
with a plan change, Codex can only regress or hold. On that turn only a
CRITICAL new finding carrying `Triggered-by` or `Missed-because` is admitted
(INV-ADMIT-1); every other new finding is noted. A confirmation turn that
validates with zero REGRESSED entries, zero admitted new findings and
INV-TERM-2 satisfied (every MINOR included) ends the run by Consensus;
otherwise the debate continues with normal rounds and becomes confirm-only
again only when the condition holds again. Claude therefore resolves or parks
every MINOR it can in the rebuttal that precedes a confirmation turn.

### INV-TERM-5 — Stalemate is ledger-based

Stalemate is declared when two consecutive authoritative rounds (INV-ROUND-1)
end with no ledger status change (INV-LEDGER-1) and no admitted new finding
(INV-ADMIT-1), or at once when at least one entry is parked and every entry
that is not RESOLVED is parked (INV-ESC-2). Score movement alone neither causes nor prevents stalemate, and a
round whose only change is in `## NOTES` is not progress. Stalemate is checked
from round 3 on, before the soft target as well as after it, and terminates
through the INV-ESC-1 batch.

## Review Coverage

### INV-SURFACE-1 — The attack surface is locked in Phase 1

The domain attack surface — 3 to 8 concrete, one-line failure classes specific
to THIS plan — is proposed by Claude, negotiated in Phase 1 under the `##
ATTACK SURFACE` section of the framework contract, and locked into
`framework.json` as `attackSurface[]` together with the categories and the
max. Every Phase 2 prompt carries it through the `{ATTACK_SURFACE}` slot
(rendered by `render-contract --part surface`); the generic failure classes are
listed after it and never replace it. It is immutable during Phase 2. A
`--skip-framework` run with no configured list renders the generic fallback
line and the run is labelled GENERIC.

### INV-SWEEP-1 — Round 1 sweeps the fixed edge-case classes

The round 1 scoring response carries a `## EDGE CASE SWEEP` section with
exactly one line per fixed class (`UB_SWEEP_CLASSES` in
`hooks/ultrablitz-utils.sh`: empty-or-none, scale, concurrency,
partial-failure-and-rollback, permissions-and-identity, time-and-ordering,
external-dependency-down, human-misuse, migration-and-compat), each marked
COVERED, UNCOVERED or N-A. An UNCOVERED line must name the `UB-n` critique
raised for it, and that critique must be in the same response. `validate-output --round 1` fails the turn when the section, a
class, or an UNCOVERED line's critique reference is missing (a FORMAT failure,
INV-FAIL-1). The sweep result is shown in the round 1 card and persisted with
the round.

### INV-ADMIT-1 — Admissibility of new findings after round 1

From round 2 on, a finding whose id is above the highest id in play is
**admitted** to the ledger only if it carries `Triggered-by: UB-m` naming a
finding already in play (UB-1 up to `--last-id`; the change made for UB-m
created or exposed it) or, for a CRITICAL or MAJOR finding, a non-empty
`Missed-because:` (what round 1 could not see). `--last-id 0` on round 2 or
later is reported as a warning, because it makes every finding new; it is
advisory only when round 1 genuinely recorded no findings. Any other new finding is
**noted**: `validate-output` reports it under `admissibility.noted`, it is
shown in the round card and the final summary under "Noted (not debated)", it
never enters the ledger and it never blocks termination. Codex is told to place
such observations under `## NOTES` without an id. Admissibility is a
classification, never a validation failure.

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
round. The repaired output must preserve the pre-repair score vector, critique
count, and the id, severity and Category of every id'd critique — a repair may
fix shape only, never substance — otherwise the turn is a FORMAT failure. The
one exception is round 1: a repair may add one critique per UNCOVERED sweep row
that named none, or named an id absent from the response (INV-SWEEP-1), since
adding it is the only shape-preserving fix. When the pre-repair parse was
itself broken (a header not recognised, field lines outside any entry), the
pre-repair count is unreliable, so the repair is held only to dropping no id'd
critique; the per-id severity and Category checks still apply. Rounds that went through repair are recorded with
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

## Configuration

### INV-CONFIG-1 — .ultrablitz.json contract

`.ultrablitz.json` is looked up in the repo root first, then the current
working directory; the first file found wins. A valid `default_framework`
defines 3–6 categories with integer weights summing to 100 and a theoretical
maximum between 50 and 100. The optional `model` key names the model for the
run (resolved per INV-MODEL-1). An invalid config produces a warning and a
fallback to the generic 4×25 rubric — it never aborts the run.

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
