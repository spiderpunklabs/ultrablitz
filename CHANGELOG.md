# Changelog

All notable changes to the ultrablitz skill are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
