# Changelog

All notable changes to the ultrablitz skill are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

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
