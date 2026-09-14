---
name: ultrablitz
version: 6.0.0
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
> and a one-time `bash install.sh --register`. See `README.md`.

Two phases. **Phase 1** negotiates the evaluation framework (categories, weights,
theoretical maximum) until both sides agree. **Phase 2** evaluates the plan against
that locked framework until mechanical consensus or a hard cap.

## How this file is organised

Every mechanical rule has exactly one normative home in
`references/protocol-invariants.md`, cited here as `INV-*`. Where this file cites
an invariant, the invariant text wins. Every mechanical *step* is a subcommand of
`hooks/ultrablitz-utils.sh` — never re-derive its internals here or reimplement it
inline (**INV-A9**). Your job is the judgement: framework design, rebuttals,
ledger decisions, reconciliation reasoning, and what to show the user.

```bash
UB="${ULTRABLITZ_ROOT:-$HOME/.claude/skills/ultrablitz}/hooks/ultrablitz-utils.sh"
```

| Subcommand | Use |
|---|---|
| `doctor [--json]` | prerequisites, companion, hook registration |
| `session-new` / `session-read <dir>` / `session-write <dir> <patch>` | run state (`references/session-schema.md`) |
| `run-lock <runId> [--force-new]` / `run-unlock` | one active run per repo |
| `codex-turn --session <dir> --prompt-file <f> [--resume] [--contract <f>] [--repair-template <f>] [--label L] [--timeout-ms N] [--model M] [--effort E]` | one validated Codex turn |
| `validate-output --contract <f> --input <f> [--baseline <f>]` | enforce the output contract |
| `render-repair --template <f> --contract <f> --offending <f>` | **INTERNAL — never call during a run.** `codex-turn --repair-template` owns the one repair **INV-FORMAT-1** permits. Exists for `prompt-lint`. |
| `gate-arm <runId>` / `gate-status` / `gate-confirm` / `gate-clear` | post-debate gate; the last two are operator-only once armed (see Termination) |
| `cleanup-completed` / `cleanup-list` | session hygiene |

`codex-turn` returns one JSON object:
`{ok, failureClass, jobId, threadId, codexSessionId, outputFile, attempts, formatRepair, message}`.
Failure classes and their state effects are **INV-FAIL-1**; none of them mutate
the ledger, scores, or the round counter.

## Argument parsing

- **Plan text**: everything after the trigger, or the file named by `--plan <path>`.
- `--max-rounds N` — Phase 2 soft target (default 5). Soft: the debate continues
  past it while findings remain, to the hard cap of 20.
- `--framework-rounds N` — Phase 1 soft target (default 3), hard cap 10.
- `--skip-framework` — use `.ultrablitz.json`'s `default_framework`, else the
  generic 4×25 rubric, labelled GENERIC.
- `--reviewer codex|claude` — default `codex`. `claude` is ADVISORY (**INV-TERM-3**).
- `--out <dir>` — where to persist artifacts.
- `--model M`, `--effort E` — passed through to Codex on every turn. `--model` is
  an explicit user choice and is never auto-changed (Pre-flight 4).
- `--cleanup` — run `cleanup-list` and stop.
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
7. Read `references/debate-protocol.md` and the Phase 1 prompts. Load the Phase 2
   prompts when Phase 2 starts, not before.

## Phase 1 — framework negotiation

1. **Propose.** Read the plan's domain and propose 3–6 categories with weights
   summing to 100, a one-sentence definition each, a theoretical maximum with a
   reason, and the domain's attack surface. Show it to the user.
2. **Critique.** Assemble `references/prompts/framework-proposal.md`
   (`{PLAN_SUMMARY}`, `{FRAMEWORK_PROPOSAL}`, `{DEBATE_PROTOCOL}`) and send it with
   `codex-turn` (no `--resume`; this is the first debate turn).
3. **Debate.** On ACCEPT, lock the framework. On REJECT or COUNTER-PROPOSE,
   answer every objection with CONCEDE, HOLD (with evidence), or COMPROMISE, then
   send `references/prompts/framework-rebuttal.md` with `--resume`. Concede where
   Codex is right; hold where the original is genuinely better. Repeat to the cap.
4. **Cap without ACCEPT.** Per field: the side that held keeps its position; the
   theoretical max takes the LOWER of the two. Unresolved fields go to the user,
   who must resolve them before Phase 2 starts.
5. **Lock.** Write the framework to `framework.json` in the session dir
   (`{categories:[{name,weight,definition}], max}`) — this file is the contract
   passed to `codex-turn --contract`. Record it in `session.json` and display it.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ULTRABLITZ — Framework Agreed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  {Category}: {weight}  — {definition}
  ...
Theoretical Maximum: {max}/100   Reason: {why, if < 100}
Framework Rounds: {N}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Phase 2 — plan evaluation

**Round 1.** Assemble `references/prompts/initial-scoring.md` (`{PLAN_TEXT}`,
`{DEBATE_PROTOCOL}`, `{OUTPUT_CONTRACT}` generated from the locked framework) and
send with `--resume` so Codex keeps the framework context. Initialise the ledger.

**Rounds 2–N.** For each critique, respond per `references/claude-debate-rules.md`
(ACCEPTED / REJECTED / PARTIALLY ACCEPTED) and update the ledger (**INV-LEDGER-1**).
Push back on at least one point per round when Codex is genuinely wrong; concede
everything that is genuinely right. Assemble the rebuttal plus the *full* updated
plan with `references/prompts/rebuttal-scoring.md` and send with `--resume`.

Every turn:

```bash
bash "$UB" codex-turn --session "$SD" --prompt-file "$P" --resume \
  --contract "$SD/framework.json" \
  --repair-template "${ULTRABLITZ_ROOT:-$HOME/.claude/skills/ultrablitz}/references/prompts/format-repair.md" \
  --label "p2-r$N" --model "$MODEL"
```

Then, in order:

1. `ok:false` → handle by `failureClass` (**INV-FAIL-1**, **INV-CONT-1/2**). Nothing
   is recorded. RETRYABLE: retry once, then ask the user. CONTINUITY: ask the user
   to stop (authoritative through the last good round) or continue DEGRADED.
   FORMAT: show the raw output as non-authoritative and ask retry-or-abort.
2. `ok:true` → the output is already validated against the locked framework. Read
   the totals from `$SD/<label>.validation.json` (e.g. `$SD/p2-r$N.validation.json`),
   which `codex-turn` wrote. Apply the cap (**INV-SCORE-1**), the
   consistency check (**INV-CAP-1**), and reconciliation (**INV-SCORE-2**) — block
   any delta that no ledger change justifies.
3. `session-write` the new round, scores, ledger, `threadId`, `codexSessionId`,
   and `jobIds` entry (with `formatRepair` when set).
4. Display the round, then check termination (**INV-TERM-1/2/3**).

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ULTRABLITZ — Round {N} (soft target {S}, hard cap {H}){ DEGRADED/ADVISORY}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Score: {total}/{max} ({+/-delta}){ (format-repaired)}
  {Category}: {score}/{weight}  {RECONCILED|BLOCKED}
Codex's Key Critiques: {severity, id, lifecycle status}
Claude's Response: {per critique, rounds 2+}
Reconciliation: {which deltas stood, which were blocked, why}
Refined Plan: {if changed}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Anti-gaming.** Every third round, require Codex to restate its single strongest
remaining concern from first principles. Judge critiques by specificity, not
length. If Round 1 scored under 30% of max, later rounds cannot jump more than 25%
of max in one round without proportionate resolutions. Pure recycling of an
addressed critique with no new evidence is refused and stays RESOLVED
(**INV-LEDGER-2**).

**Per-finding escalation.** A finding that oscillates (RESOLVED → REGRESSED twice)
or is unchanged for three rounds goes to the user as a tie. That resolves one
finding and the debate continues; it is not a termination.

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
Agreed Framework: {categories, max}
Final Refined Plan: {text}
Unresolved: {findings with both positions, if any}
Artifacts: {paths}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Reviewer fallback

`--reviewer claude` runs the same prompts against an independent Claude subagent.
It is never selected automatically: if Codex pre-flight fails, print the diagnosis
and stop, and let the user re-invoke. ADVISORY runs are labelled in every round
card and the summary, are `authoritative: false`, and cannot reach Consensus
(**INV-TERM-3**).

## Prompt hygiene

Plan text goes between explicit delimiters (`THE PLAN:` … `---`), never inside XML
control tags. Quote prior Codex output as `Codex said:` prose. Claude's rebuttals
are markdown only. Keep every assembled prompt within **INV-BUDGET-1**; overflow
becomes a Plan Digest with the full text on disk and findings referenced by ID.

## Critical rules

- **NEVER** pass `--write` to Codex, and never let it modify the repo.
- **NEVER** begin implementation before the gate clears.
- **NEVER** hand-roll a Codex invocation, a session write, or a gate file — use the
  subcommands (**INV-A9**). The one exception is the Execute confirmation Write
  above, which no subcommand can reach from inside the session.
- **ALWAYS** show Codex's raw output transparently.
- **ALWAYS** keep the refined plan coherent, not a patchwork of accepted fixes.
- The framework is locked during Phase 2 except by recalibration (**INV-CAP-2**).
- Authoritative scores are evidence-backed (**INV-SCORE-2**); a DEGRADED or
  ADVISORY run never claims one.
- Release the run lock (`run-unlock`) and mark the session completed on every exit
  path, including aborts — always before `gate-arm`, after which no Bash runs.
