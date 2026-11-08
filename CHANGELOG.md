# Changelog

All notable changes to the ultrablitz skill are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [7.0.0] - 2026-11-08

The debate protocol gains identity, scope and a stopping rule. v6's
executable subcommands are integrated onto the current main line; v7 makes
what they validate precise.

### Upgrade notes

- **State moved out of `/tmp`.** Sessions now live in the per-user state
  directory and the gate lock in `$TMPDIR/ultrablitz-<uid>/`. An installed copy
  is a symlink to the checkout, so pulling switches over at once: an armed
  pre-7 gate lock becomes invisible to the new hook and pre-7 sessions are not
  listed by `cleanup-list`. Finish or abandon any run in flight first, then
  move the old files to the Trash:
  `/tmp/ultrablitz-gate-*.lock` and `/tmp/ultrablitz-*/`.
- **Permission allowlists need the new subcommand names.** Each turn calls
  `hooks/ultrablitz-utils.sh` with one of: `doctor`, `session-new`,
  `session-read`, `session-write`, `resolve-model`, `run-lock`, `run-unlock`,
  `codex-turn`, `validate-output`, `render-contract`, `gate-arm`,
  `gate-status`, `gate-confirm`, `gate-clear`, `cleanup-list`,
  `cleanup-completed`, `trash-session`. An allowlist written for 6.x
  (`cleanup-interactive`, `mkdir -m 700 /tmp/ultrablitz-*`,
  `touch /tmp/ultrablitz-*/completed`) prompts on every turn until updated.
- Re-run `install.sh --register` after pulling so the gate hook entry points at
  the current script.

### Added

- **Stable critique identity (INV-ID-1).** Every finding is `UB-n`, assigned by
  Codex, never renumbered, with a `Category:` line from the locked framework
  and a defined severity. `validate-output` rejects un-id'd, duplicate,
  out-of-sequence or foreign-category entries; the ledger, rebuttals and
  summary refer to findings by id only.
- **Round-1 edge-case sweep (INV-SWEEP-1).** The first scoring response must
  mark nine fixed classes (empty-or-none, scale, concurrency,
  partial-failure-and-rollback, permissions-and-identity, time-and-ordering,
  external-dependency-down, human-misuse, migration-and-compat) as COVERED,
  UNCOVERED or N-A, and every UNCOVERED class names the critique raised for
  it. `validate-output --round 1` fails the turn otherwise.
- **Admissibility of new findings (INV-ADMIT-1).** From round 2 on, a new
  finding enters the ledger only with `Triggered-by: UB-m` or, for CRITICAL or
  MAJOR severity, `Missed-because:`. Anything else is *noted*: shown to the
  user, never debated, never blocking termination. Codex places such
  observations under `## NOTES`.
- **Confirmation turn (INV-TERM-4).** Once every CRITICAL and MAJOR entry is
  RESOLVED, the next turn runs `--confirm-only`: Codex confirms or regresses
  with evidence and only a CRITICAL new finding is admissible, so a converging
  debate closes instead of inviting new scope.
- **Ledger-based stalemate (INV-TERM-5)** — two consecutive rounds with no
  ledger status change and no admitted finding — and the **NEEDS_USER
  disposition (INV-ESC-2)**: a critique that turns on a decision only the user
  can make is parked, not re-argued, and goes to the user in the one
  termination batch. `session.json` gains `lastCritiqueId` and
  `ledgerUnchangedRounds`.
- **Domain attack surface locked in Phase 1 (INV-SURFACE-1).** Phase 1
  negotiates 3–8 concrete failure classes under `## ATTACK SURFACE`; they are
  locked into `framework.json` as `attackSurface[]` and reach every scoring
  prompt through `{ATTACK_SURFACE}`. The generic list in debate-protocol.md
  is gone.
- **`render-contract` subcommand.** Prints the per-round `{OUTPUT_CONTRACT}`
  from the single template in output-contract.md and the `{ATTACK_SURFACE}`
  list from framework.json, so neither is ever hand-typed (INV-A9).
- `codex-turn --round N --last-id N [--confirm-only]`, checked before any
  Codex call is spent and forwarded to validation; `validate-output` reports
  `critiques[]`, `lastId`, `newIds`, `admissibility{admitted,noted}`, `sweep`
  and `warnings` (e.g. `--last-id 0` after round 1).
- **No finding is dropped silently.** The critique scanner tolerates the
  common header variants (bullet or number prefix, bold anywhere, any case,
  `###` section headings) and fails the turn on anything it still cannot
  parse: a line with a UB id or severity tag that is not a header, field lines
  outside an entry or repeated within one, or an empty CRITIQUES section
  without `- None.`.
- `## NOTES` is required on rounds 2+. `Triggered-by` must name a finding in
  play and `Missed-because` must carry text, or the finding is noted. An
  UNCOVERED sweep row must name a critique present in the same response.
- A format repair must also keep every critique's id, severity and Category;
  on round 1 it may add the critiques an UNCOVERED sweep row owed.

### Changed

- The format-repair prompt lists the round's required headers (sweep on round
  1, notes on rounds 2+) and the four critique sub-fields; it still carries
  exactly three slots (INV-FORMAT-1).
- Phase 1 and Phase 2 soft/hard caps, batched escalation, the single cap
  question, trash-not-delete cleanup and the non-git gate scoping from the
  6.x main line are preserved; the v6 test harness (`make test`, 8 suites)
  runs in CI alongside the existing lint jobs.
- Tests: validate-output 19 → 66 assertions, prompt-lint 28 → 44, doc-lint
  requires the seven new invariants.


- `validate-output` consolidated to one awk scan per file plus one jq filter:
  70 lines (from 127) and 4–5 processes per call (from ~25), with the response
  grammar in a single shared scanner so the baseline parse can never drift from
  the main parse. All 19 existing assertions pass unmodified.
- The Phase 1 output contract is authored once (`{FRAMEWORK_CONTRACT}` in
  output-contract.md) and interpolated by both negotiation prompts — round 1
  and rounds 2+ previously demanded different shapes. Prompt headers lost their
  stale v5 invocation instructions (`codex-turn` owns invocation); net −1.2 KB
  across the templates, enforced by four new prompt-lint checks.
- Four more rules moved into protocol-invariants.md — INV-GAME-1 (anti-gaming),
  INV-ESC-1 (per-finding escalation), INV-CONFIG-1 (.ultrablitz.json contract),
  INV-LEDGER-3 (pure recycling) — and SKILL.md's recycling rule now cites the
  right invariant (it previously pointed at the user-resolution re-raise gate).
- Both gate.log writers emit the same five keys; doctor derives `.ok` once and
  its exit code reads it back instead of tracking a parallel flag.

### Removed

- Dead subcommands `version` and `cleanup-interactive` (no callers), the inert
  constructs in the repair renderer, duplicated resume/fresh selection, and
  ~35 lines of cite-and-restate and constrains-nothing prose across SKILL.md,
  claude-debate-rules.md and output-contract.md.

### Added

- Automatic model selection (INV-MODEL-1): resolved once per run — `--model` →
  `ULTRABLITZ_MODEL` → `.ultrablitz.json` `model` → the newest-first preference
  list (`gpt-6-astra`, `gpt-5.3-codex-spark`) — recorded in `session.json` and
  reported in the summary and artifacts. A user-named model is never
  substituted; a preference-list model auto-downgrades once on a recognised
  account refusal, and an unrecognised 400 gets one bounded probe
  (`modelSelectionUnknown`) instead of a retry loop. New `resolve-model`
  subcommand.
- Single-writer enforcement moved inside `session-write` with a four-row
  environment contract (adopt / refuse-on-missing-env / refuse-on-mismatch /
  vacuous), no override flag.
- The resume predicate is mechanical and fail-closed: `codex-turn --resume` is
  honoured only when a validated non-smoke debate turn is recorded, refusals
  are reported as `resumeRefused`, and validated turns record
  `lastTurnLabel`/`threadId`/`codexSessionId` themselves.
- The validation artifact is a hard gate: missing or unparseable validation
  output fails the turn (`validationUnreadable`) instead of reading as success,
  and validator stderr is kept beside the JSON.
- The repair turn now gets the same payload and continuity guards as the main
  turn; a timed-out repair is RETRYABLE, a thread-hopping repair is CONTINUITY.
- `install.sh` builds the hook entry once for both the printed snippet and the
  `--register` edit, and the uninstall path checks every step instead of
  failing silently; new `tests/test-install.sh` covers both against a sandbox
  HOME.

### Fixed

- The documented gate-clearing path was unreachable: SKILL.md told the
  assistant to run `gate-confirm` via Bash, which the armed gate denies. The
  Write-tool carve-out is now the single documented in-session path; the
  operator's own terminal is the human route.
- `gate-arm` deleted an existing confirmation before attempting its lock write,
  so a failed re-arm destroyed the previous run's confirmation and locked the
  user out. The removal now happens only after the lock write succeeds.
- A quote or backslash in a category name silently voided validation
  (awk-built JSON broke and the error was discarded); the score array is now
  built by jq and a non-JSON contract fails loudly instead of validating
  vacuously.
- Pre-flight order in SKILL.md created the session after the smoke turn that
  needs it; `doctor`'s `registration: unknown` and missing-jq cases are now
  handled explicitly; `session-read` no longer crashes on a null
  `claudeSessionId`; `cleanup-completed` reports paths it could not delete;
  the gate hook no longer writes its audit log into a state directory it just
  refused to trust.

## [6.0.0] - 2026-09-14

### Added

- Stock-install executability: companion resolution no longer requires the
  exec bit (the companion is always run via `node`), the skill root is
  resolved via `ULTRABLITZ_ROOT`, and the gate hook now reads the PreToolUse
  stdin JSON contract instead of never-set environment variables — the old
  env-var read dead-locked the Execute path on every stock install.
- Codex turns run as background + wait + result through the companion, with
  real timeout enforcement (`--timeout-ms`) instead of an unbounded wait.
- Explicit failure classes on every turn: `RETRYABLE`, `CONTINUITY`, `FORMAT`,
  `FATAL` — callers branch on a machine-readable class, never on prose.
- Atomic `session.json` state (write-to-tmp + rename) with a per-repo
  active-run lock (`run-lock` / `run-unlock`).
- Gate hardening: all gate JSON is built with `jq` (never string-spliced), the
  state directory is per-user mode 700 with symlink and ownership checks,
  unparseable timestamps deny fail-closed, every gate event lands in a
  JSON-lines audit log, and lock liveness is a PID + process-start-time
  advisory pair.
- A test suite that needs no LLM and no API spend: a stub companion
  (`tests/stub-companion.mjs`) drives every failure class end to end, and
  recorded companion fixtures pin the payload contract the skill reads
  (`tests/contract.bats.sh`).
- `tests/doc-lint.sh` and `tests/prompt-lint.sh`: SKILL.md and the prompt
  templates are linted for drift — unknown placeholder slots can never ship,
  and the format-repair prompt is pinned to exactly its three slots
  (INV-FORMAT-1).
- CI (GitHub Actions): shellcheck + the offline suite on every push and pull
  request. The live smoke test stays a human, release-time act
  (`make release-check`), and `make tag` refuses without fresh smoke evidence.
- This changelog.

### Fixed

- Gate lock timestamps were parsed as local time by BSD `date -j -f`, so every
  fresh lock read as stale on hosts east of UTC and the gate denied forever.
  Timestamps are now parsed as UTC.
- The session `completed` marker file could be reaped from `/tmp`, leaving
  finished sessions uncollectable; cleanup now also honours `completed: true`
  inside `session.json`.
