---
name: ultrablitz
version: 7.0.0
description: >-
  Adversarial debate loop between Claude and Codex to refine plans, ideas, and
  designs to perfection. Two-phase: first Claude and Codex negotiate the evaluation
  framework (categories, weights, theoretical max), then they evaluate and refine
  the plan against it. Invoke when the user says /ultrablitz, "blitz this",
  "ultrablitz this", or natural language equivalents like "debate this plan",
  "pressure test this", "stress test this idea", "score and improve this",
  "have Claude and Codex argue about this". Use proactively when the user has a
  plan or proposal that would benefit from rigorous adversarial refinement.
---

# Ultrablitz — Adversarial Debate Loop

> **Requires** the [openai-codex plugin](https://github.com/openai/codex-plugin-cc)
> and a one-time `bash install.sh --register`.

Two phases. **Phase 1** negotiates the evaluation framework (categories, weights,
theoretical maximum) until both sides agree. **Phase 2** evaluates the plan against
that locked framework until mechanical consensus or a hard cap.

## How this file is organised

Every mechanical rule has exactly one normative home in
`references/protocol-invariants.md`, cited here as `INV-*`. Where this file cites
an invariant, the invariant text wins. Every mechanical *step* is a subcommand of
`hooks/ultrablitz-utils.sh` (**INV-A9**). Your job is the judgement: framework design, rebuttals,
ledger decisions, reconciliation reasoning, and what to show the user.

```bash
UB="${ULTRABLITZ_ROOT:-$HOME/.claude/skills/ultrablitz}/hooks/ultrablitz-utils.sh"
```

| Subcommand | Use |
|---|---|
| `doctor [--json]` | prerequisites, companion, hook registration |
| `session-new` / `session-read <dir>` / `session-write <dir> <patch>` | run state (`references/session-schema.md`) |
| `run-lock <runId> [--force-new]` / `run-unlock` | one active run per repo |
| `codex-turn --session <dir> --prompt-file <f> [--resume] [--contract <f>] [--repair-template <f>] [--label L] [--round N] [--last-id N] [--confirm-only] [--timeout-ms N] [--model M] [--effort E]` | one validated Codex turn |
| `validate-output --contract <f> --input <f> [--baseline <f>] [--round N] [--last-id N] [--confirm-only]` | enforce the output contract (**INV-ID-1**, **INV-SWEEP-1**, **INV-ADMIT-1**) |
| `render-contract --contract <f> --round N` / `render-contract --contract <f> --part surface` | the `{OUTPUT_CONTRACT}` text for a round / the `{ATTACK_SURFACE}` list (**INV-SURFACE-1**) |
| `render-repair --template <f> --contract <f> --offending <f>` | **INTERNAL — never call during a run.** `codex-turn --repair-template` owns the one repair **INV-FORMAT-1** permits. Exists for `prompt-lint`. |
| `gate-arm <runId>` / `gate-status` / `gate-confirm` / `gate-clear` | post-debate gate; the last two are operator-only once armed (see Termination) |
| `cleanup-completed` / `cleanup-list` / `trash-session <dir>` | session hygiene — sessions are moved to `~/.Trash`, never deleted |

`codex-turn` returns one JSON object:
`{ok, failureClass, jobId, threadId, codexSessionId, outputFile, attempts, formatRepair, message}`.
Its validation record, `$SD/<label>.validation.json`, carries
`{ok, errors, warnings, categories, total, critiques[{id,severity,category}],
lastId, newIds, admissibility{admitted[], noted[{id,reason}]}, sweep}`.
Failure classes and their state effects are **INV-FAIL-1**; none of them mutate
the ledger, scores, or the round counter.

## Argument parsing

- **Plan text**: everything after the trigger, or the file named by `--plan <path>`.
- `--max-rounds N` — Phase 2 soft target (default 5). Soft: the debate continues
  past it while findings remain, to the hard cap of 10.
- `--framework-rounds N` — Phase 1 soft target (default 3), hard cap 5.
- `--skip-framework` — use `.ultrablitz.json`'s `default_framework`
  (**INV-CONFIG-1**), else the generic 4×25 rubric, labelled GENERIC.
- `--reviewer codex|claude` — default `codex`. `claude` is ADVISORY (**INV-TERM-3**).
- `--out <dir>` — where to persist artifacts.
- `--model M`, `--effort E` — passed through to Codex on every turn. `--model` is
  an explicit user choice and is never auto-changed (Pre-flight 4).
- `--cleanup` — run `cleanup-list` and stop. It prints one exact `trash-session`
  command per stale session; nothing is removed without the user running it.
- `--force-new` — take over a stale per-repo run lock.

If no plan text is given, ask what to debate. Flags override implied intent.

## Pre-flight

1. `bash "$UB" doctor --json`. Three outcomes, all of which you must handle:
   - `.ok` false → stop and show the failing check; doctor names the fix.
   - no JSON at all (exit 3) → `jq` is missing. Stop: the gate hook is
     fail-closed without it.
   - `.checks[] | select(.name=="registration").status == "unknown"` → say plainly
     that gate enforcement is **unverified** (`settings.json` unreadable), then
     continue. `unknown` is not `fail`, so `.ok` alone does not cover this.
2. `bash "$UB" gate-status` → if a gate is already active, resolve it first.
3. `bash "$UB" run-lock <runId>` → refuses a second concurrent run in this repo.
4. **Resolve the model, once** (**INV-MODEL-1**). Order: `--model` flag → `ULTRABLITZ_MODEL` →
   `.ultrablitz.json`'s `"model"` → the built-in preference list (newest first:
   `gpt-6-astra`, then `gpt-5.3-codex-spark`, alias `spark`) → the companion's own
   default. Pass the result as `--model` on every turn, `session-write` it, and
   report it in the summary and the `debate-log.md` frontmatter — a score is not
   comparable across models.
5. `bash "$UB" session-new` → the session directory `$SD`. Write the plan to
   `$SD/plan-full.md` and record `planPath`.
6. **Smoke turn.** `doctor` can report ready while the first real turn fails, so
   write `Reply with the single word OK and nothing else.` to `$SD/smoke.md` and
   send `bash "$UB" codex-turn --session "$SD" --prompt-file "$SD/smoke.md"
   --label smoke --model "$MODEL"` (no `--resume`, no `--contract`); require `OK`.
   - refresh-token error → tell the user to run `codex logout && codex login`.
   - model refusal (HTTP 400 `invalid_request_error` naming the model) → a model
     that came from the preference list downgrades to the next candidate; re-run
     the smoke turn with it. A model the **user** named is never changed: stop
     and report the refusal. Costs one turn; keeps the debate off an unusable model.
7. Read `references/debate-protocol.md` and `references/prompts/framework-prompt.md`.
   Load `references/prompts/scoring-prompt.md` when Phase 2 starts, not before.

## Phase 1 — framework negotiation

1. **Propose.** Read the plan's domain and propose 3–6 categories with weights
   summing to 100, a one-sentence definition each, a theoretical maximum with a
   reason, and the domain's attack surface: 3–8 one-line failure classes
   specific to THIS plan, concrete enough to probe ("double charge on payment
   retry", not "reliability") (**INV-SURFACE-1**). Show it to the user.
2. **Critique.** Assemble `references/prompts/framework-prompt.md` for round 1
   (`{ROUND_CONTEXT}`, `{PLAN_SUMMARY}`, `{FRAMEWORK_PROPOSAL}`,
   `{DEBATE_PROTOCOL}`, `{FRAMEWORK_CONTRACT}` from
   `references/output-contract.md`), write it to `$SD/p1-r1-framework.md`, and
   send it with `codex-turn` (no `--resume`; this is the first debate turn).
3. **Debate.** On ACCEPT, lock the framework. On REJECT or COUNTER-PROPOSE,
   answer every objection with CONCEDE, HOLD (with evidence), or COMPROMISE, then
   assemble the same template for round N (`{ROUND_CONTEXT}` for R2+, empty
   `{PLAN_SUMMARY}`, your rebuttal as `{FRAMEWORK_PROPOSAL}`), write it to
   `$SD/p1-r<N>-claude-response.md`, and send with `--resume`. Concede where
   Codex is right; hold where the original is genuinely better. Repeat to the cap.
4. **Cap without ACCEPT.** Per field: the side that held keeps its position; the
   theoretical max takes the LOWER of the two. Unresolved fields go to the user,
   who must resolve them before Phase 2 starts.
5. **Lock.** Write the framework to `framework.json` in the session dir
   (`{categories:[{name,weight,definition}], max, attackSurface:[3–8 strings]}`)
   — this file is the contract passed to `codex-turn --contract` and
   `render-contract --contract`. The attack surface is the list both sides
   accepted under `## ATTACK SURFACE` (**INV-SURFACE-1**); it is as locked as
   the categories. Record it in `session.json` and display it.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ULTRABLITZ — Framework Agreed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  {Category}: {weight}  — {definition}
  ...
Theoretical Maximum: {max}/100   Reason: {why, if < 100}
Attack Surface: {one line per locked failure class}
Framework Rounds: {N}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Phase 2 — plan evaluation

One template, `references/prompts/scoring-prompt.md`, serves every round; its
header lists the slots and which are empty on R1 versus R2+.

Two slots are rendered, never hand-typed (**INV-A9**): `{OUTPUT_CONTRACT}` is
`render-contract --contract "$SD/framework.json" --round "$N"` and
`{ATTACK_SURFACE}` is `render-contract --contract "$SD/framework.json" --part
surface`. Codex names every finding `UB-n` (**INV-ID-1**); `$LAST` below is
`session.json`'s `lastCritiqueId` — the highest id in play, 0 before round 1.

**Round 1.** Assemble it with the R1 `{ROUND_CONTEXT}`, the full `{PLAN_TEXT}`,
`{DEBATE_PROTOCOL}`, `{ATTACK_SURFACE}`, the round-1 `{OUTPUT_CONTRACT}` (it
carries the `## EDGE CASE SWEEP`, **INV-SWEEP-1**) and the `{INCLUDE_DIG_DEEPER}`
block; write to `$SD/p2-r1-scoring.md` and send with `--resume --round 1` so
Codex keeps the framework context. Initialise the ledger from
`validation.json`'s `critiques[]` (one entry per id, status UNRESOLVED) and set
`lastCritiqueId` from its `lastId`. Show the sweep in the round card; every
UNCOVERED class already has its critique by construction.

**Rounds 2–N.** For each ledger entry, respond per
`references/claude-debate-rules.md` (ACCEPTED / REJECTED / PARTIALLY ACCEPTED /
NEEDS_USER) and update the ledger (**INV-LEDGER-1**, **INV-ESC-2**). Push back on
at least one point per round when Codex is genuinely wrong; concede everything
that is genuinely right. Assemble the same template with the R2+
`{ROUND_CONTEXT}`, your rebuttal plus the *full* updated plan as `{PLAN_TEXT}`,
`{ATTACK_SURFACE}`, the round-N `{OUTPUT_CONTRACT}` (it carries the admissibility
rules and `## NOTES`, **INV-ADMIT-1**) and the `{INCLUDE_REBUTTAL_RULES}` block;
write to `$SD/p2-r<N>-rebuttal.md` and send with `--resume --round $N --last-id
$LAST`.

**Confirmation turn.** When your rebuttal leaves every CRITICAL and MAJOR entry
RESOLVED and none REGRESSED, the next turn is confirm-only (**INV-TERM-4**): use
the confirmation `{ROUND_CONTEXT}` from the template header and add
`--confirm-only`. Resolve or park every MINOR you can in that rebuttal — an open
MINOR blocks Consensus (**INV-TERM-2**). If it validates with no REGRESSED entry, no admitted new
finding, and **INV-TERM-2** holds, the run ends by Consensus.

Every turn:

```bash
bash "$UB" codex-turn --session "$SD" --prompt-file "$P" --resume \
  --contract "$SD/framework.json" --round "$N" --last-id "$LAST" \
  --repair-template "${ULTRABLITZ_ROOT:-$HOME/.claude/skills/ultrablitz}/references/prompts/format-repair.md" \
  --label "p2-r$N" --model "$MODEL"
```

Then, in order:

1. `ok:false` → handle by `failureClass` (**INV-FAIL-1**, **INV-CONT-1/2**). Nothing
   is recorded. RETRYABLE: retry once, then ask the user. CONTINUITY: ask the user
   to stop (authoritative through the last good round) or continue DEGRADED.
   FORMAT: show the raw output as non-authoritative and ask retry-or-abort.
2. `ok:true` → the output is already validated against the locked framework. Read
   `$SD/<label>.validation.json` (e.g. `$SD/p2-r$N.validation.json`), which
   `codex-turn` wrote. Apply the cap (**INV-SCORE-1**); on the first cap event of
   the run ask the user once whether the max stands (**INV-CAP-2**); then
   reconcile (**INV-SCORE-2**) — block any delta that no ledger change justifies.
   Add `admissibility.admitted` ids to the ledger as UNRESOLVED; `admissibility.
   noted` ids are shown, never ledgered, and never block termination
   (**INV-ADMIT-1**). Set `lastCritiqueId` to `lastId`. A non-empty
   `warnings` array means the call was mis-assembled (e.g. `--last-id 0` after
   round 1): fix the flags and re-validate before recording anything.
3. `session-write` the new round, scores, ledger, `lastCritiqueId`,
   `ledgerUnchangedRounds` (0 if any status changed or a finding was admitted
   this round, else +1), `threadId`, `codexSessionId`, and `jobIds` entry (with
   `formatRepair` when set).
4. Display the round, then check termination (**INV-TERM-1/2/3/4/5**).

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ULTRABLITZ — Round {N} (soft target {S}, hard cap {H}){ DEGRADED/ADVISORY}{ CONFIRMATION}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Score: {total}/{max} ({+/-delta}){ (format-repaired)}
  {Category}: {score}/{weight}  {RECONCILED|BLOCKED}
Edge Case Sweep: {covered}/{n} covered, UNCOVERED: {classes → UB-n}, N-A: {classes}   (round 1)
Ledger: UB-{n} [{severity}] {category} — {status}{ (PARKED: needs user)}
Claude's Response: {per entry, rounds 2+}
Noted (not debated): {UB-n — reason}   (rounds 2+, if any)
Reconciliation: {which deltas stood, which were blocked, why}
Refined Plan: {if changed}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Anti-gaming.** Enforce the anti-gaming controls on every round (**INV-GAME-1**);
a recycled critique with no new evidence stays RESOLVED (**INV-LEDGER-3**).

**Stalemate is ledger-based.** `ledgerUnchangedRounds >= 2`, or at least one
PARKED entry with every entry that is not RESOLVED PARKED, terminates the run
as a stalemate (**INV-TERM-5**). Score drift without a ledger change is not
progress.

**Escalation is batched.** Findings that remain unresolved when the debate ends
(hard cap or stalemate), PARKED entries included, go to the user in one
AskUserQuestion at termination, never one at a time mid-debate (**INV-ESC-1**,
**INV-ESC-2**). Do not interrupt a round to ask about a single finding.

## Termination and the gate

Terminate only per **INV-TERM-1**. Then:

1. Persist artifacts (**E2**): `debate-log.md` and `refined-plan.md` into `--out`,
   else `in-flight/innovations/<slug>/` when `~/workspace/dev/in-flight` exists,
   else the session dir. Frontmatter: `reviewer`, `model`, `degraded`,
   `authoritative`.
2. `session-write '{"completed":true}'`, print the artifact paths, `run-unlock`.
3. `bash "$UB" gate-arm "$runId"` — **the last Bash call of the run**: the hook
   then denies every Bash/Edit/Write/NotebookEdit call until the gate clears.
   From its JSON keep all three fields — `runId`, `unlockCode`, and `lock` (the
   lock path). You cannot re-read them afterwards.
4. Ask via AskUserQuestion: **Execute** / **Modify** / **Discard**.
   - **Execute** → with the **Write tool**, write exactly
     `{"runId":"<runId>","unlockCode":"<unlockCode>"}` to the `lock` path with its
     `.lock` suffix replaced by `.confirmed`. That pre-validated single Write is
     the hook's only carve-out and the only way to clear the gate from inside the
     session: **no Bash call can clear it** — `gate-confirm` included, because the
     hook denies the Bash call before it runs. Then implement.
     If the Write is refused, **STOP** and tell the user; do not improvise another
     route.
   - **Modify** → the gate stays; discuss, regenerate the summary, re-ask.
   - **Discard** → the run is closed with no implementation authority. Hand the
     user the operator command to run **in their own terminal** (expand `$UB`):
     `bash <skill>/hooks/ultrablitz-utils.sh gate-clear`. It must be typed by
     them; run as a tool call it is denied.

The gate fires after any termination that produced a usable refined plan. It does
not fire if the user cancelled the run or Codex failed fatally before Round 1.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ULTRABLITZ — COMPLETE{ (DEGRADED: reason) | (ADVISORY)}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Final Score: {score}/{max}{ — non-authoritative}
Rounds: {N} framework + {M} evaluation   Codex Calls: {attemptCount}
Model: {resolved model}
Trajectory: {r1} -> ... -> {rM}          Termination: {reason}
Agreed Framework: {categories, max, attack surface}
Final Refined Plan: {text}
Unresolved: {UB-n findings with both positions and the user's ruling, if any}
Noted (not debated): {UB-n — reason, if any}
Artifacts: {paths}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Reviewer fallback

`--reviewer claude` runs the same prompts against an independent Claude subagent.
It is never selected automatically: if Codex pre-flight fails, print the diagnosis
and stop, and let the user re-invoke. ADVISORY runs are labelled in every round
card and the summary (**INV-TERM-3**).

## Prompt hygiene

Plan text goes between explicit delimiters (`THE PLAN:` … `---`), never inside XML
control tags. Quote prior Codex output as `Codex said:` prose. Claude's rebuttals
are markdown only. Keep every assembled prompt within **INV-BUDGET-1**.

## Critical rules

- **NEVER** pass `--write` to Codex, and never let it modify the repo.
- **NEVER** begin implementation before the gate clears.
- **NEVER** hand-roll a Codex invocation, a session write, or a gate file — use the
  subcommands (**INV-A9**). The one exception is the Execute confirmation Write
  above, which no subcommand can reach from inside the session.
- **ALWAYS** show Codex's raw output transparently.
- **ALWAYS** keep the refined plan coherent, not a patchwork of accepted fixes.
- The framework is locked during Phase 2; only the user's one-time answer to the
  first cap event can change the max (**INV-CAP-2**).
- Every file **you** write into the session dir is `.md` (prompts, plan, rebuttals,
  logs). Only the subcommands write `.json`, `.err`, `completed`, `cleanup.error`.
- Never `rm` a session or a gate file: `cleanup-completed` and `trash-session`
  move to `~/.Trash`; `gate-clear` is the operator's.
- Authoritative scores are evidence-backed (**INV-SCORE-2**); a DEGRADED or
  ADVISORY run never claims one.
- Release the run lock (`run-unlock`) and mark the session completed on every exit
  path, including aborts — always before `gate-arm`, after which no Bash runs.
