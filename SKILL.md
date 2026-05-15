---
name: ultrablitz
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

> **Requires**: [openai-codex plugin](https://github.com/openai/codex-plugin-cc) for Claude Code.
> Install via `/install-plugin openai-codex` and run `/codex:setup` before first use.

Two-phase adversarial refinement between Claude and Codex.

**Phase 1 — Framework Negotiation**: Claude and Codex debate the evaluation
criteria before scoring anything. What categories matter for this domain?
What weights? What's the theoretical maximum? They argue until both agree.

**Phase 2 — Plan Evaluation**: Using the agreed framework, Codex scores the
plan, Claude argues back, and they loop until mechanical consensus or round cap.

## Argument Parsing

Parse the user's input for:
- **Plan text**: everything after the command trigger (or flags)
- `--max-rounds N`: soft target for Phase 2 rounds (default: 5). Debate auto-extends past this if findings remain unresolved, up to hard cap of 10.
- `--framework-rounds N`: soft target for Phase 1 rounds (default: 3). Auto-extends up to hard cap of 5.
- `--skip-framework`: skip Phase 1, use default rubric (generic 4x25 or custom from `.ultrablitz.json`)
- `--cleanup`: list and interactively delete incomplete sessions, then exit
- `--effort <none|minimal|low|medium|high|xhigh>`: passed to Codex if set
- `--model <model>`: passed to Codex if set

If no plan text is provided, ask the user what they want to debate/refine.
All triggers normalize to the same invocation with the same defaults.
Flags always override implied intent.

## Pre-Flight

Four steps. Execute in order before Phase 1.

### 1. Resolve Codex Companion

```bash
CODEX_COMPANION=$(bash "$(dirname "$0")/hooks/ultrablitz-utils.sh" resolve-companion)
```

The helper checks the openai-codex plugin cache (highest version) then the
marketplace, verifying existence and executability. If neither is found it
fails with a diagnostic listing the paths checked. Only those two locations
are supported.

### 2. Verify Codex Is Ready (and handle `--cleanup`)

```bash
node "$CODEX_COMPANION" setup --json
```

If not ready, direct the user to `/codex:setup` and stop.

If `--cleanup` is set: run
`bash "$(dirname "$0")/hooks/ultrablitz-utils.sh" cleanup-interactive`
to list incomplete `/tmp/ultrablitz-*/` sessions; prompt per session
(`y/n/all`); then exit without starting a new debate.

### 3. Create Session Directory

```bash
session_dir=$(bash "$(dirname "$0")/hooks/ultrablitz-utils.sh" create-session)
runId=$(basename "$session_dir" | sed 's/^ultrablitz-//')
```

The helper performs `mkdir -m 700 /tmp/ultrablitz-<runId>/` and prints the
full path. `runId` is the canonical identifier — every artifact filename,
every helper subcommand session argument, and the gate lock + confirmation
JSON `runId` fields all use it. Do not invent alternate identifiers.

Artifacts follow this naming schema. Content artifacts MUST use `.md`; any
other extension is a protocol violation.

```
/tmp/ultrablitz-<runId>/
  session.json                          # session state — JSON
  completed                             # extensionless completion marker
  cleanup.error                         # error log (only on cleanup failure)
  plan-full.md                          # full plan when digested (Stage 1 overflow)
  p1-r1-framework.md                    # Phase 1 round 1 prompt
  p1-r<N>-claude-response.md            # Phase 1 rounds 2+ rebuttals
  p2-r1-scoring.md                      # Phase 2 round 1 prompt
  p2-r<N>-rebuttal.md                   # Phase 2 rounds 2+ rebuttals (N >= 2)
```

Store in `session.json`: runId (UUID), createdAt (ISO-8601), lastActiveAt
(updated each round).

### 4. Session Hygiene Scan

```bash
bash "$(dirname "$0")/hooks/ultrablitz-utils.sh" legacy-scan
bash "$(dirname "$0")/hooks/ultrablitz-utils.sh" cleanup-completed
```

`legacy-scan` classifies each pre-existing `/tmp/ultrablitz-*/` as
`conforming`, `completed`, `nonconforming-older-than-4h`, or
`nonconforming-recent` (output is for the operator; the helper never
auto-acts on non-conforming directories). `cleanup-completed` then trashes
each session with a `completed` marker via `trash-session`, which moves it
to `~/.Trash/ultrablitz-<runId>-<ts>-<pid>/`. Failures are surfaced.
Incomplete sessions are NEVER auto-deleted regardless of age.

Reference files are read on demand when assembling prompts; no separate
load step.

---

## PHASE 1: Framework Negotiation

Skip if `--skip-framework` is set. When skipped:
- If `.ultrablitz.json` has a `default_framework`, validate it (3-6 categories, weights
  sum to 100, max 50-100) and use it. Invalid config: warn, fall back to generic 4x25.
- Otherwise use generic 4x25 rubric (Feasibility/Completeness/Correctness/Elegance),
  labeled "GENERIC — Framework negotiation recommended for domain-specific evaluation."

### Step 1: Claude Proposes a Framework

Based on the plan's domain and content, Claude proposes:
- **3-6 scoring categories** with weights summing to 100
- **Definition** for each category (one sentence)
- **Theoretical maximum**: can this domain reach 100? If not, what's the max and why?
- **Domain-specific attack surface**: what failure modes matter most?

Present to user, then send to Codex.

### Step 2: Codex Critiques the Framework

Read `references/prompts/framework-prompt.md`. Assemble with:
- `{ROUND_CONTEXT}` — R1 framing (see template)
- `{PLAN_SUMMARY}` — 2-3 sentence plan summary
- `{FRAMEWORK_PROPOSAL}` — Claude's proposed framework
- `{INCLUDE_MISSING_DIMENSIONS}` — the R1 MISSING DIMENSIONS block
- `{DEBATE_PROTOCOL}` — tone blocks

Write to session temp dir. Invoke: `node "$CODEX_COMPANION" task --prompt-file ...`

On rounds 2+, reuse the same template with the R2+ values for
`{ROUND_CONTEXT}` and `{INCLUDE_MISSING_DIMENSIONS}` (and Claude's rebuttal
text as `{FRAMEWORK_PROPOSAL}`), and submit via `--resume-last`.

### Step 3: Framework Debate Loop

If ACCEPT: lock framework. Move to Phase 2.

If REJECT or COUNTER-PROPOSE:
1. For each objection, Claude responds:
   - **CONCEDE**: accept Codex's position
   - **HOLD**: maintain original with evidence
   - **COMPROMISE**: propose middle ground
2. Claude MUST concede where Codex is right.
3. Claude MUST hold where the original is genuinely better.
4. Send via `--resume-last`.
5. Repeat until ACCEPT or cap.

### Step 4: Framework Resolution (if cap reached)

If cap reached without full ACCEPT:
- For each field: use Codex's last position if Claude conceded, Claude's if held.
- Unresolved fields: marked explicitly with both positions recorded.
- Theoretical max: use LOWER of two positions (conservative).
- User MUST explicitly resolve unresolved fields before Phase 2 starts.
  Options: accept reviewer positions, accept proposer positions, or set custom values.
  If user does not choose, session pauses.

### Step 5: Lock the Framework

Framework is LOCKED into an artifact:
`{ categories: [{name, weight, definition}], max, unresolved: [] }`

Display to user:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ULTRABLITZ — Framework Agreed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Categories:
  {Category 1}: {weight}/{total}  — {definition}
  {Category 2}: {weight}/{total}  — {definition}
  ...

Theoretical Maximum: {max}/100
Reason: {why this max, if < 100}

Framework Rounds: {N}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Generate dynamic output contract from artifact using the template in
`references/output-contract.md`.

---

## PHASE 2: Plan Evaluation

### Thread Continuity

- Phase 2 Round 1 uses `--resume-last` to continue the Phase 1 thread
  (Codex retains framework context). If `--skip-framework`, Round 1 is a fresh task.
- Capture the threadId emitted by codex-companion after Round 1 and persist
  it in `session.json` for audit. If the thread is lost between rounds,
  the next `--resume-last` will surface the runtime error from
  codex-companion itself — no separate per-round verification ritual.

### Score Sanity Check

After each Codex scoring round, before displaying anything, Claude verifies:

1. **Parse**: the response has `## CATEGORY SCORES`, `## CRITIQUES`,
   `## STRENGTHS`, `## VERDICT`. Category names match the locked framework
   exactly (case-insensitive, trimmed, no extras, no duplicates). Each score
   is in `[0, weight]`. Each critique has Evidence, Impact, Suggestion.
   Parse failure: retry once with a correction prompt; second failure presents
   raw output, marks the round non-authoritative, and asks the user.
2. **Reconcile**: every per-category score *change* must cite a critique
   whose status moved this round — an *increase* requires a critique in
   that category newly RESOLVED with a specific plan-diff anchor; a
   *decrease* requires a new or REGRESSED critique in that category.
   Unjustified deltas are BLOCKED — the authoritative score for that
   category retains the prior round's value (the model's number is shown
   separately as "proposed (unreconciled)").
3. **Cap**: the authoritative total is `min(sum(category scores),
   theoretical_max)`. If the raw sum exceeds the cap, display as
   `Score: {max}/{max} (raw: {sum}, capped)`. On the *first* cap event in
   a run, ask the user once via AskUserQuestion whether the agreed
   framework's theoretical max needs recalibration (the only legitimate
   grounds: a capability or constraint that was excluded from the Phase 1
   negotiation). User accepts → update the locked max for subsequent
   rounds; rejects → cap stays. No silent recalibration.

Only fully validated rounds mutate critique ledger / score history /
consensus state. The reconciliation result is shown in the round card so
the user can see which deltas were honored and which were blocked.

### Critique Lifecycle

See `references/claude-debate-rules.md` (Critique Lifecycle Tracking + Re-Raising Rules) for the ledger states and re-raise policy.

### Round 1: Initial Submission

1. Read `references/prompts/scoring-prompt.md`.
2. Assemble prompt with R1 values for `{ROUND_CONTEXT}`,
   `{INCLUDE_DIG_DEEPER}`, and `{INCLUDE_REBUTTAL_RULES}`, plus
   `{PLAN_TEXT}`, `{DEBATE_PROTOCOL}`, `{OUTPUT_CONTRACT}` (the dynamic
   contract from the agreed framework).
3. Write to session temp dir.
4. Submit: `node "$CODEX_COMPANION" task --resume-last --prompt-file ...`
   (or fresh task if `--skip-framework`). No `--write`.
5. Parse and validate output. Compute score from category sum.
6. Initialize critique ledger.
7. Display Round 1 results.
8. Update lastActiveAt. Check termination.

### Rounds 2-N: Debate Loop

1. Analyze Codex's feedback.
2. For each critique, per `references/claude-debate-rules.md`:
   - **ACCEPTED**: incorporate, state what changed, update critique status to RESOLVED.
   - **REJECTED**: push back with evidence, status stays UNRESOLVED.
   - **PARTIALLY ACCEPTED**: take valid part, propose alternative, status to PARTIALLY_RESOLVED.
3. MUST push back on at least one point per round if genuinely wrong.
4. Assemble rebuttal using `references/prompts/scoring-prompt.md` with
   R2+ values for `{ROUND_CONTEXT}`, `{INCLUDE_DIG_DEEPER}` (empty), and
   `{INCLUDE_REBUTTAL_RULES}`; the rebuttal body fills `{PLAN_TEXT}` with
   per-critique responses plus the full updated plan.
5. Submit via `--resume-last` (`--prompt-file` for content >= 500 chars).
6. Parse, validate, reconcile.
7. Display round results with reconciliation.
8. Update lastActiveAt and critique ledger. Check termination.

### Termination

One rule. No termination path silently drops unresolved findings —
PARTIALLY_RESOLVED counts as unresolved here.

1. **Consensus**: all critiques RESOLVED AND score within 3% of the
   theoretical max → terminate normally.
2. **User abort**: terminate immediately; final summary lists every
   unresolved finding as "terminated by user abort."
3. **Round-cap reached OR score unchanged 2 consecutive rounds**: escalate
   every UNRESOLVED / REGRESSED finding to the user, one at a time, in
   severity order (CRITICAL → MAJOR → MINOR, then by critique ID). For
   each, present both positions (Claude vs Codex) and offer "Accept
   Claude" / "Accept Codex" / "Provide your own." After every finding is
   disposed, terminate. If interrupted mid-resolution, on resume reprompt
   only the still-unresolved findings.

User resolutions are final — no re-scoring or debate resumption after
escalation. A user-resolved finding may only be re-raised in a future
session if Codex cites plan text added or modified after the resolution.

Per-finding mid-debate auto-escalation (oscillation, stuck) is subsumed
by this rule: every escalation path now runs once at the end, in one
batch, rather than firing repeatedly during the debate.

### Budget Controls

- **Max prompt size**: 30,000 characters (hard cap).
- **Stage 1 overflow** (plan text > 20K chars): summarize into Plan Digest (key
  sections, decisions, open questions). Full plan stored as `plan-full.md` in
  session dir, referenced in Debate State Summary. If Codex cites a critique about
  digested text, Claude MUST include that section verbatim in the next round.
- **Stage 2 overflow** (active findings exceed remaining budget): cap at top 10
  by severity (CRITICAL first, then MAJOR, then MINOR). Remaining referenced by
  ID only: "See findings UB-11 through UB-15 from Round N."
- **Debate State Summary** (used when prior context overflows): unresolved critique
  IDs + summaries, resolved critique IDs (list only), current score and categories,
  score trajectory, strongest remaining concern, latest plan text.
- **Timeout**: 5 minutes per Codex call. Progress note at 3 minutes.
- **Final summary** includes: total rounds (framework + evaluation), total Codex calls.

### Prompt Sanitization

- User plan text placed between explicit delimiters ("THE PLAN:" header + "---"
  separator), never inside XML control tags.
- Prior Codex output quoted in rebuttals: prefixed with "Codex said:", never in
  control blocks.
- Claude rebuttal text: markdown only, never XML tags.
- Framework text: interpolated into output contract template only.

### Error Handling

| Class | Examples | Behavior |
|-------|----------|----------|
| RETRYABLE | Malformed output, Codex timeout | Retry once (with correction prompt for malformed). Second failure: escalate to user. |
| FATAL | Thread resume fail, auth fail, companion not found | Abort. Show all completed rounds. Prior rounds remain valid. |
| SALVAGEABLE | Partial output (some sections parsed) | Present parsed portions, flag missing sections, mark non-authoritative. Partial rounds do NOT update critique ledger, reconciliation state, consensus checks, or category scores. Only fully validated rounds mutate debate state. |

Prior completed rounds are always preserved and shown regardless of error class.

### Round Counting

- **attemptCount**: total Codex calls including retries and partial/non-authoritative rounds.
- **authoritativeRound**: only fully validated rounds that mutate debate state.
- Round cap and stalemate logic use `authoritativeRound` only.
- Display shows both: "Round 3/5 (attempt 4)" when they differ.
- Non-authoritative attempts do not count toward cap or stalemate.

## Display Format

After each Phase 2 round:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ULTRABLITZ — Round {N}/{MAX}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Score: {COMPUTED_SUM}/{MAX} ({+/-DELTA})

Category Breakdown:
  {Category 1}:  {score}/{weight}  {RECONCILED|BLOCKED}
  {Category 2}:  {score}/{weight}  {RECONCILED|BLOCKED}
  ...

Codex's Key Critiques:
{bulleted list with severity and lifecycle status}

Claude's Response: (rounds 2+ only)
{ACCEPTED/REJECTED/PARTIALLY ACCEPTED per critique}

Reconciliation:
{which deltas were justified, which were blocked, with reasons}

Refined Plan: (if changes were made)
{updated plan text}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Final summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ULTRABLITZ — COMPLETE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Final Score: {SCORE}/{MAX}
Rounds: {N} (framework) + {M} (evaluation)
Codex Calls: {total}
Score Trajectory: {R1} -> {R2} -> ... -> {RM}
Termination: {reason}

Agreed Framework:
  {categories with weights}
  Theoretical Maximum: {max}

Final Refined Plan:
{the plan as it stands after all rounds}

Unresolved Disagreements: (if any)
{points where Claude and Codex could not agree, with both positions}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Post-Debate Confirmation Gate

After the debate completes and the ULTRABLITZ — COMPLETE summary is displayed,
a mechanical confirmation gate activates to prevent unintended implementation.

### Gate Activation

1. Write the gate lock file as the LAST Bash call (uses noclobber for atomicity):
   ```bash
   set -C && echo '{"runId":"UUID","repoRoot":"PATH","createdAt":"ISO-8601","unlockCode":"UUID","pid":PID}' > /tmp/ultrablitz-gate-{REPO_HASH}.lock
   ```
   - `REPO_HASH`: first 16 chars of SHA256 of repo root in a git context, or of `"$(pwd -P)|$RUN_ID"` otherwise (per-runId scoping for non-git CWDs)
   - `unlockCode`: fresh UUID generated at gate creation time
   - If the file already exists (noclobber fails): an active gate exists for this repo.
     Error: "An active ultrablitz gate exists. Complete or clear it first."

2. The PreToolUse hook (`ultrablitz-gate.sh`) now blocks ALL Edit, Write,
   NotebookEdit, and Bash calls while the lock exists.

3. Read, Grep, Glob, AskUserQuestion, Agent, WebSearch, WebFetch remain available.

### User Confirmation

Use AskUserQuestion immediately after the lock is created:

**"The refined plan is ready. How would you like to proceed?"**

Options:
- **Execute** — "Implement the refined plan now"
- **Modify** — "I want to make changes first"
- **Discard** — "Don't implement, keep the refinement for reference"

### Gate Resolution

**On Execute:**
1. Read the lock file to obtain the `unlockCode`.
2. Write the confirmation file (the hook has a narrow, single-use carve-out for this):
   ```
   /tmp/ultrablitz-gate-{REPO_HASH}.confirmed
   Content: {"runId":"UUID","unlockCode":"UUID"}
   ```
3. The hook validates the confirmation token against the lock pre-execution.
   If valid: gate clears. All tools become available.
4. As the first post-gate action, remove both lock and confirmation files (best-effort cleanup).
5. Proceed with implementation of the refined plan.

**On Modify:**
- Lock stays active. Discuss changes with user.
- When ready, re-present the AskUserQuestion gate with the modified plan.
- Each modification cycle gets a fresh gate prompt.

**On Discard:**
- Run is closed. No implementation authority carried forward.
- Instruct user to clear the lock: `! rm /tmp/ultrablitz-gate-*.lock /tmp/ultrablitz-gate-*.confirmed 2>/dev/null`
- To implement later, user must make a new explicit request.

### Gate Rules

- The gate fires after ANY debate termination that produces a usable refined plan
  (consensus, round cap, stalemate, user stops debate).
- The gate does NOT fire when the user cancels ultrablitz entirely or Codex fails fatally.
- **Implementation before confirmation is INVALID.** If the next assistant action
  after the final summary would move toward implementation without gate clearance,
  the hook blocks it mechanically.
- The gate always reflects the CURRENT plan state. If modifications occurred,
  regenerate the summary before re-presenting.

### Singleton Invariant

One active gate per repo when ultrablitz runs inside a git checkout (lock keyed by
repo-root hash). When invoked from a non-git CWD — e.g., a workspace parent that
contains multiple sibling project repos — the lock is keyed by `(cwd, runId)`,
which is per-active-run rather than per-CWD. Two parallel ultrablitz sessions
auditing different siblings under the same non-git parent will no longer collide.

Enforced atomically via `set -C` (noclobber) on lock creation.
Pre-flight also checks for existing locks as an advisory early warning:
- Lock exists + <4h old + PID alive → refuse to start new run
- Lock exists + <4h old + PID dead → warn (likely crashed), offer to clear
- Lock exists + >4h old → warn (stale), offer to clear

### Stale Lock Policy

Stale locks (>4h) are NEVER auto-allowed. The hook denies with clear instructions
to manually remove. No silent policy expiry.

### Recovery

If something goes wrong, the user can always force-clear:
```
! rm /tmp/ultrablitz-gate-*.lock /tmp/ultrablitz-gate-*.confirmed 2>/dev/null
```

## Iteration Caps

| Phase | Soft Default | Hard Cap |
|-------|-------------|----------|
| Phase 1 (Framework) | 3 | **5** |
| Phase 2 (Evaluation) | 5 | **10** |

**Defaults are soft targets, not stop signals.** If unresolved findings remain when
the default round count is reached, the debate CONTINUES automatically up to the
hard cap. Rounds are never cut short to hit a default — every finding must be
addressed before consensus.

- `--framework-rounds N` and `--max-rounds N` set the soft target (user suggestion).
- If N exceeds the hard cap, clamp with a warning.
- The debate stops ONLY when: consensus is reached (all findings resolved), the
  hard cap is hit, the user aborts, or stalemate is detected.
- If the hard cap is reached with findings still unresolved, display them explicitly
  in the final summary as "Unresolved at hard cap."

## Critical Rules

- **NEVER** add `--write` to any Codex invocation.
- **NEVER** modify files in the user's repository during the debate.
- **NEVER** begin implementation without gate confirmation.
- **ALWAYS** present Codex's raw output transparently.
- **ALWAYS** maintain the current refined plan state across rounds.
- **All content artifacts** written under `/tmp/ultrablitz-<runId>/` MUST use
  the `.md` extension. State files use `session.json` and `completed`. The
  `cleanup.error` file is written only by `trash-session` on
  failure. Gate files (`/tmp/ultrablitz-gate-*.{lock,confirmed}`) keep their
  semantic extensions and are unaffected. Any other extension under the
  session directory is a protocol violation.
- **Every Codex invocation** (`task` or `--resume-last`, in BOTH phases) MUST
  be preceded by `bash "$(dirname "$0")/hooks/ultrablitz-utils.sh" validate-session "$runId"`.
  Nonzero exit aborts the round and surfaces the offending files. Run
  `validate-session` immediately after each prompt-file Write so contract
  violations are caught at the write site, not just before Codex consumption.
- **Use the helper** for: session creation (`create-session`), session cleanup
  (`trash-session`, `cleanup-completed`), gate-lock creation
  (`create-gate-lock`), and validation (`validate-session`). Do NOT call
  `mkdir`, `mv`, `rm`, or `set -C` on ultrablitz paths directly — every
  shell side-effect must go through a helper subcommand whose permission
  rule is explicitly granted.
- The agreed framework is LOCKED during Phase 2.
- Authoritative scores are always evidence-backed via reconciliation.
- Clean up session temp directory after loop completes (mark completed).
- Track across rounds:
  - `agreedFramework` — locked artifact from Phase 1
  - `currentPlan` — plan text as refined
  - `critiqueLedger` — critique IDs, statuses, lifecycle
  - `scores[]` — authoritative scores per round
  - `threadId` — verified each round
