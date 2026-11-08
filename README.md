# ultrablitz

An adversarial debate loop for plans. Claude proposes, [Codex](https://github.com/openai/codex-plugin-cc)
attacks, and the plan is rewritten until they agree — or until the disagreements
are explicitly handed to you. It is a Claude Code skill: markdown instructions,
prompt templates, and bash subcommands that do everything mechanical.

Two phases:

1. **Framework negotiation** — before anything is scored, both sides argue about
   what "good" means for this domain: categories, weights, and the realistic
   maximum score. The framework is then locked.
2. **Plan evaluation** — Codex scores and critiques, Claude rebuts and rewrites,
   round after round. Score changes must be backed by resolved critiques, so the
   number cannot drift upward on vibes.

## Install

Prerequisites: `node` >= 20, `jq` >= 1.6, `git`, and the `codex` CLI matching your
CPU architecture, plus the openai-codex plugin (`/plugin install openai-codex`).

```bash
git clone https://github.com/spiderpunklabs/ultrablitz.git
cd ultrablitz
bash install.sh --register     # symlinks the skill and registers the gate hook
codex login                    # if you have not already
```

`install.sh` with no arguments checks prerequisites, prints the settings snippet,
and exits 2 without installing anything — "printed" never means "installed".
`bash install.sh --uninstall` reverses it. Verify any time with:

```bash
bash hooks/ultrablitz-utils.sh doctor
```

Doctor names the fix for every failure it reports, including the two that bite
most often: a wrong-architecture `codex` install, and an unregistered hook.

## Use

```
/ultrablitz <your plan text>
/ultrablitz --plan plans/migration.md --max-rounds 8
/ultrablitz --skip-framework --reviewer claude   # advisory run, no Codex
```

| Flag | Meaning |
|---|---|
| `--plan <path>` | read the plan from a file instead of the prompt |
| `--max-rounds N` | Phase 2 soft target (default 5; hard cap 10) |
| `--framework-rounds N` | Phase 1 soft target (default 3; hard cap 5) |
| `--skip-framework` | use `.ultrablitz.json`'s framework, or a generic 4×25 rubric |
| `--reviewer codex\|claude` | `claude` runs ADVISORY: labelled, never authoritative |
| `--out <dir>` | where to write `debate-log.md` and `refined-plan.md` |
| `--model M` | pin the Codex model for the run; passed through on every turn, never auto-changed |
| `--effort E` | Codex reasoning effort; passed through on every turn |
| `--cleanup` | list stale sessions and the exact command to trash each (nothing is ever rm'd) |
| `--force-new` | take over a stale per-repo run lock |

A run ends with a confirmation gate: until you choose Execute, Modify, or Discard,
a PreToolUse hook blocks Edit/Write/NotebookEdit/Bash so a refined plan cannot
quietly become an implementation. Execute is the one thing Claude can clear by
itself, through a single pre-validated confirmation write the hook carves out;
everything else — including discarding — is a command you run yourself (see
[Troubleshooting](#troubleshooting)).

### What a run looks like

```
ULTRABLITZ — Framework Agreed
  Runtime contract fidelity & execution robustness: 25 — does it work on a stock install?
  Gate & safety integrity: 20 — is the confirmation gate fail-closed?
  ...
Theoretical Maximum: 96/100
Attack Surface: gate bypass via a path the hook does not see; session state
  mutated by a turn that later fails validation; ...

ULTRABLITZ — Round 1 (soft target 5, hard cap 10)
Score: 62/96
  Runtime contract fidelity & execution robustness: 14/25  RECONCILED
  ...
Edge Case Sweep: 7/9 covered, UNCOVERED: concurrency → UB-3, N-A: migration-and-compat
Ledger:
  UB-1 [CRITICAL] Runtime contract fidelity — Claims stock-install executability while requiring a manual step — UNRESOLVED
  ...

ULTRABLITZ — COMPLETE
Final Score: 96/96   Rounds: 2 framework + 6 evaluation
Trajectory: 62 -> 83 -> 89 -> 93 -> 94 -> 96   Termination: consensus
Artifacts: in-flight/innovations/ultrablitz/self-blitz/debate-log.md
```

That transcript is real: v6 of this skill was designed by running v5 against its
own improvement plan. v7 added what the transcript lacked: stable `UB-n` ids
with a category per finding, a round-1 edge-case sweep, an admissibility bar
for findings raised after round 1, a confirmation turn once the serious
findings are closed, and a stalemate rule that reads the ledger rather than
the score (`references/protocol-invariants.md`, INV-ID-1 through INV-TERM-5).

## Design

| Piece | Role |
|---|---|
| `SKILL.md` | what Claude does — judgement only, nothing mechanical |
| `references/protocol-invariants.md` | the single normative home of every mechanical rule (`INV-*`) |
| `references/session-schema.md` | `session.json` fields, atomic writes, the run lock |
| `references/prompts/*.md` | prompt templates; every legal `{SLOT}` is listed in `tests/prompt-lint.sh` |
| `hooks/ultrablitz-utils.sh` | every mechanical step, as testable subcommands |
| `hooks/ultrablitz-gate.sh` | the PreToolUse confirmation gate |
| `tests/` | unit, gate, contract, and end-to-end suites |

The split matters: prose cannot be tested, so nothing mechanical lives in prose.
`codex-turn` runs one Codex turn end to end — launch in the background, wait with
a real timeout, fetch the result, validate it against the locked framework, repair
one malformed response, and verify thread continuity — and returns a single JSON
verdict. Failure is always one of `RETRYABLE`, `CONTINUITY`, `FORMAT`, `FATAL`,
and **none of them mutate debate state**.

## Tests

```bash
make test          # everything below, no network, no API key
make lint          # shellcheck, if installed
make smoke         # one real Codex turn (costs money; needed before a release)
make release-check # test + smoke
make tag           # refuses unless a fresh, clean smoke record exists
```

`tests/stub-companion.mjs` impersonates the Codex companion so the whole
orchestration seam runs in CI: happy path, timeout, in-flight job, thread
mismatch, session mismatch, empty output, malformed output, a repair that
silently rescores, and interruption with resume. `tests/fixtures/companion/`
holds payloads recorded from the real companion (1.0.3), and `make smoke`
re-records them and fails on any schema drift.

## Security audit

A 20-finding audit was run on 2026-04-13. Status as of v6.0.0:

| # | Severity | Finding | Status |
|---|---|---|---|
| 1 | Critical | TOCTOU race on the confirmation file | **FIXED** — `set -C` noclobber creation, pre-validated single-use carve-out (`test-gate.sh`: carve-out cases) |
| 2 | Critical | Unsafe JSON parsing of tool input | **FIXED** — stdin JSON, `jq -e` validation, malformed input denies (`test-gate.sh`: malformed confirmation) |
| 3 | High | Shell injection via paths interpolated into JSON | **FIXED** — all hook output built with `jq -n --arg` |
| 4 | High | Symlink attacks on predictable lock names | **FIXED** — per-user 700 state dir, symlink/owner/mode checks on dir and leaves (`test-gate.sh`: symlink + permission cases) |
| 5 | High | Concurrent cleanup race (`rm -rf /tmp/ultrablitz-*`) | **FIXED** — cleanup iterates exact paths, never a glob (`test-utils.sh`: cleanup cases) |
| 6 | High | Unescaped user input in prompts | **FIXED** — delimiter discipline in SKILL.md, enforced by `prompt-lint.sh` |
| 7 | Medium | Unsafe `git rev-parse` output | **FIXED** — hashed, never interpolated into JSON unescaped |
| 8 | Medium | Glob expansion in cleanup instructions | **FIXED** — `cleanup-list` prints one exact `trash-session <path>` per session; nothing is ever `rm`d |
| 9 | Medium | Missing directory creation validation | **FIXED** — `mkdir -m 700` then verified before every use |
| 10 | Medium | Fragile stale-lock timestamp parsing (epoch=0 fallback) | **FIXED** — unparseable timestamps deny (`test-gate.sh`: unparseable createdAt) |
| 11 | Medium | PID validation promised but not implemented | **FIXED** — PID + process start time, documented as advisory only (never an authorization input) |
| 12 | Medium | Weak unlock code | **FIXED** — `uuidgen` per gate, compared only after both sides are non-empty |
| 13 | Medium | No mutual exclusion on concurrent hook invocations | **TRACKED** — `in-flight/bugs/ultrablitz/`. The hook is read-only against the lock; the only writer is `gate-arm`, which is noclobber-atomic |
| 14 | Medium | No ownership check on session cleanup | **FIXED** — state dir is per-uid and ownership-checked |
| 15 | Low | No timeout on hook execution | **WONTFIX** — the hook does bounded file reads and jq calls with no network or subprocess fan-out; a timeout would add a failure mode without removing one |
| 16 | Low | Silent error suppression | **FIXED** — every deny path emits a reason and a JSON-lines audit record |
| 17 | Low | No audit logging of gate decisions | **FIXED** — `gate.log`, one JSON object per line (`test-gate.sh`: audit log cases) |
| 18 | Low | No TTL on incomplete sessions | **FIXED (partly)** — completed sessions are removed and `--cleanup` lists the rest; incomplete sessions are still never auto-deleted, by design |
| 19 | Low | Repeated hash computation | **WONTFIX** — one `shasum` per hook invocation is not worth a cache that could go stale |
| 20 | Low | Opaque error messages | **FIXED** — every denial names the exact command that clears it |

No Critical or High finding remains open, which is the release gate for 6.0.0.

## Troubleshooting

**`codex --version` fails with `ENOENT ... codex-darwin-x64`** — npm installed the
wrong architecture. From a shell where `arch` prints your real CPU:
`npm uninstall -g @openai/codex && npm install -g @openai/codex`.

**Doctor says ready but the first turn fails on a refresh token** — the setup probe
does not exercise token refresh. Run `codex logout && codex login`.

**`The '<model>' model is not supported when using Codex with a ChatGPT account`** —
your plan cannot use that model. The skill now picks one for you: `--model`, then
`ULTRABLITZ_MODEL`, then `.ultrablitz.json`'s `"model"`, then its built-in
preference list (newest first: `gpt-6-astra`, then `gpt-5.3-codex-spark`, alias
`spark`), then whatever the companion defaults to. A refusal is a 400 at turn time,
so the run spends one throwaway pre-flight turn to find it: a model taken from the
preference list is silently downgraded to the next candidate, and the debate starts
on a model that works. A model **you** named is never swapped behind your back — the
run stops and names the alternatives. Set `ULTRABLITZ_MODEL=spark` for a session,
`"model": "spark"` in `.ultrablitz.json` for a repo, or
`ULTRABLITZ_SMOKE_MODEL=spark make smoke` for the release smoke test.

**Everything is blocked and the gate will not clear** — this is the human's route,
and it is the only one that works. Run it **in your own terminal**:

```bash
bash hooks/ultrablitz-utils.sh gate-status    # which run is holding the gate
bash hooks/ultrablitz-utils.sh gate-confirm   # approve: clears the gate
bash hooks/ultrablitz-utils.sh gate-clear     # discard: removes the lock
```

A command you type yourself is not a Claude tool call, so the PreToolUse hook never
sees it. Claude cannot run these while the gate is armed — the hook denies its Bash
calls first, `gate-confirm` included. From inside the session Claude has exactly one
route, the pre-validated confirmation write the hook carves out for Execute.

**"a Codex task is still running"** — another Codex job in this Claude session holds
the thread. Wait for it, or check `/codex:status`. Ultrablitz waits once with a
five-minute budget before giving up; it never re-seeds for this reason.

**A run is marked DEGRADED or ADVISORY** — thread continuity was lost and re-seeded,
or the reviewer was Claude rather than Codex. The refined plan is still useful; the
score is not authoritative and the run cannot reach consensus.

**`settings.json` is not readable in your environment** — doctor reports
registration as `unknown` and the skill will not claim the gate is enforced.
Register the hook by hand from `hooks/settings-snippet.json`.

## License

See the repository.
