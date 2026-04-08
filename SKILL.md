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
- `--max-rounds N`: soft target for Phase 2 rounds (default: 5). Debate auto-extends past this if findings remain unresolved, up to hard cap of 20.
- `--framework-rounds N`: soft target for Phase 1 rounds (default: 3). Auto-extends up to hard cap of 10.
- `--skip-framework`: skip Phase 1, use default rubric (generic 4x25 or custom from `.ultrablitz.json`)
- `--cleanup`: list and interactively delete incomplete sessions, then exit
- `--effort <none|minimal|low|medium|high|xhigh>`: passed to Codex if set
- `--model <model>`: passed to Codex if set

If no plan text is provided, ask the user what they want to debate/refine.
All triggers normalize to the same invocation with the same defaults.
Flags always override implied intent.

## Pre-Flight

### 1. Resolve Codex Companion Path

Check in priority order:

```bash
# 1. Explicit config (highest priority)
# Check ULTRABLITZ_CODEX_COMPANION env var
# or "codex_companion_path" in .ultrablitz.json

# 2. Plugin context
CODEX_COMPANION="${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs"

# 3. Cache (highest version)
if [ ! -f "$CODEX_COMPANION" ]; then
  CODEX_COMPANION=$(ls ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)
fi

# 4. Marketplace source
if [ ! -f "$CODEX_COMPANION" ]; then
  CODEX_COMPANION=~/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs
fi
```

Each step: check existence AND executability.
Log resolved path and version at pre-flight.
If none found: hard fail with diagnostic listing all checked paths.

### 2. Verify Codex Is Ready

```bash
node "$CODEX_COMPANION" setup --json
```

If not ready, direct user to `/codex:setup` and stop.

### 3. Handle --cleanup (if set)

List all `/tmp/ultrablitz-*` directories that are incomplete (no `completed` marker).
Display: runId, createdAt, lastActiveAt, round count.
Prompt per session: "Delete session {runId} from {date}? (y/n/all)".
Then exit — do not start a new debate.

### 4. Create Session Directory

Create `/tmp/ultrablitz-$(uuidgen)/` with mode 700.
All prompt files and session state go in this directory.
Store: runId (UUID), createdAt (ISO-8601), lastActiveAt (updated each round).

### 5. Clean Completed Sessions

Remove any `/tmp/ultrablitz-*` directories that have a `completed` marker.
Incomplete sessions are NEVER auto-deleted regardless of age.

### 6. Load Reference Files

Read all before starting:
- `references/debate-protocol.md`
- `references/output-contract.md`
- `references/claude-debate-rules.md`
- `references/prompts/framework-proposal.md`
- `references/prompts/framework-rebuttal.md`
- `references/prompts/initial-scoring.md`
- `references/prompts/rebuttal-scoring.md`

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

Read `references/prompts/framework-proposal.md`. Assemble with:
- `{PLAN_SUMMARY}` — 2-3 sentence plan summary
- `{FRAMEWORK_PROPOSAL}` — Claude's proposed framework
- `{DEBATE_PROTOCOL}` — tone blocks

Write to session temp dir. Invoke: `node "$CODEX_COMPANION" task --prompt-file ...`

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
- After Round 1: capture threadId from codex-companion stdout. Store in session state.
  If Round 1 fails to emit a threadId: retry once (RETRYABLE). If retry also lacks
  threadId: FATAL — abort. If retry produces a different threadId: use the retry's
  (latest valid). Store final verified threadId.
- Before each subsequent round: verify resumed threadId matches stored value.
  On mismatch: abort with "Another Codex task ran between rounds. Debate context lost."

### Output Parsing (Strict)

Codex returns `## CATEGORY SCORES` only. No `## SCORE` line.
Total score is computed deterministically by Claude as the sum of category scores,
**capped at the theoretical maximum** from the agreed framework.

If the raw category sum exceeds the theoretical max, the authoritative score is
the max. Display as: `Score: {max}/{max} (raw: {sum}, capped at theoretical max)`.
This prevents impossible scores where individual categories are valid but their
sum exceeds the agreed ceiling.

Validation steps:
1. All required section headers present: `## CATEGORY SCORES`, `## CRITIQUES`,
   `## STRENGTHS`, `## VERDICT`
2. Exact category-key matching against locked framework: same count, names match
   (case-insensitive, trimmed), no extras, no duplicates
3. Each category score bounded by 0 to that category's weight
4. Category sum capped at theoretical max (authoritative score = min(sum, max))
5. Each critique has Evidence, Impact, Suggestion sub-fields

Validation failure: retry ONCE with correction prompt specifying exact expected
categories and format. Second failure: present raw output, mark non-authoritative,
ask user to continue or abort.

### Score Reconciliation (ENFORCED)

After each Codex scoring round, Claude performs reconciliation before displaying:

- **Category increase**: must map to at least one critique in that category marked
  RESOLVED with a specific plan change cited. If no mapping: the increase is
  **BLOCKED** — authoritative score retains prior round's value for that category.
  Model-proposed score shown separately as "proposed (unreconciled)."
- **Category decrease**: must map to a new or REGRESSED critique in that category.
  If no mapping: decrease is **BLOCKED**.
- The authoritative score displayed to the user is always evidence-backed.
- Reconciliation results shown in the round card for transparency.

### Critique Lifecycle

Claude maintains a critique status ledger across rounds:

| Status | Meaning |
|--------|---------|
| UNRESOLVED | Active critique, not yet addressed |
| PARTIALLY_RESOLVED | Addressed but fix is incomplete |
| RESOLVED | Fully addressed with plan change |
| REGRESSED | Previously resolved, re-opened with evidence |

- Codex CAN re-raise a previously addressed critique if it provides new evidence
  or argues the fix was inadequate.
- Pure recycling (same concern, no new evidence, plan text changed in that area)
  is flagged by Claude and not re-addressed.

### Anti-Gaming Controls

- **Score-change justification**: enforced via reconciliation — increases require
  resolved critique + plan change citation.
- **First-principles restatement**: every 3 rounds, Codex must restate its single
  strongest remaining concern from first principles (not referencing prior critiques).
- **Verbosity check**: critiques evaluated by specificity, not length. Claude may
  reject verbose critiques lacking concrete evidence.
- **Anchoring guard**: if Round 1 score < 30% of max, subsequent rounds cannot
  jump more than 25% of max per round without proportionate critique resolution.

### Round 1: Initial Submission

1. Read `references/prompts/initial-scoring.md`.
2. Assemble prompt: `{PLAN_TEXT}`, `{DEBATE_PROTOCOL}`, `{OUTPUT_CONTRACT}`
   (dynamic contract from agreed framework).
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
4. Assemble rebuttal with per-critique responses AND full updated plan.
5. Submit via `--resume-last` (`--prompt-file` for content >= 500 chars).
6. Parse, validate, reconcile.
7. Display round results with reconciliation.
8. Update lastActiveAt and critique ledger. Check termination.

### Termination (Precedence Order)

1. **Consensus** (mechanical): score within 3% of theoretical max AND zero
   UNRESOLVED or REGRESSED critiques of ANY severity (CRITICAL, MAJOR, and MINOR —
   all must be RESOLVED or PARTIALLY_RESOLVED) AND zero blocked score deltas in
   current round. All three required. No findings may be skipped.
2. **User abort**: stop immediately.
3. **Hard cap**: stop at hard limit (Phase 1: 10, Phase 2: 20). If unresolved
   findings remain, list them as "Unresolved at hard cap" in the final summary.
   The soft default (`--max-rounds`) does NOT stop the debate if findings remain.
4. **Stalemate**: score unchanged for 2 consecutive rounds.
5. **Regression**: score decreased for 2 consecutive rounds → **WARNING** displayed
   to user, who chooses continue or abort. Not automatic termination.

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
   - `REPO_HASH`: first 16 chars of SHA256 of repo root (or canonical CWD if non-git)
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

One active gate per repo. Enforced atomically via `set -C` (noclobber) on lock creation.
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
| Phase 1 (Framework) | 3 | **10** |
| Phase 2 (Evaluation) | 5 | **20** |

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
- The agreed framework is LOCKED during Phase 2.
- Authoritative scores are always evidence-backed via reconciliation.
- Clean up session temp directory after loop completes (mark completed).
- Track across rounds:
  - `agreedFramework` — locked artifact from Phase 1
  - `currentPlan` — plan text as refined
  - `critiqueLedger` — critique IDs, statuses, lifecycle
  - `scores[]` — authoritative scores per round
  - `threadId` — verified each round
