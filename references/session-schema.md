# Session Schema

The on-disk session state for an ultrablitz run, exactly as implemented by the
`session-new`, `session-read`, and `session-write` subcommands of
`hooks/ultrablitz-utils.sh`. Per INV-A9, those subcommands are the normative
implementation — this document describes them and must not drift from them.

## Location

- **State directory**: `${ULTRABLITZ_STATE_DIR:-$TMPDIR/ultrablitz-$(id -u)}`
  (trailing slashes normalised; `/tmp` when `TMPDIR` is unset). Created with
  mode 700. Every access is preceded by a fail-closed trust check: the
  directory must exist, must not be a symlink, must be owned by the current
  user, and must have mode exactly 700.
- **Session directory**: `mktemp -d "$STATE_DIR/session-XXXXXXXX"`, chmod 700.
  `session-new` prints this path; all later calls take it as an argument.
- **Session file**: `<session-dir>/session.json`. Before every read or write
  it passes a leaf check: regular file, not a symlink, owned by the current
  user.

## `session.json` Fields

Created by `session-new` with these initial values:

| Field | Type | Initial | Meaning |
|---|---|---|---|
| `schemaVersion` | number | `1` | Schema version of this file. |
| `runId` | string | fresh UUID | Stable identity of this run; also used by the gate and run lock. |
| `createdAt` | string | now | ISO-8601 UTC (`date -u +%Y-%m-%dT%H:%M:%SZ`). |
| `lastActiveAt` | string | now | Refreshed automatically on EVERY `session-write`. |
| `claudeSessionId` | string | `$CLAUDE_SESSION_ID` or `"unknown"` | Owner key for the single-writer rule (below). |
| `codexSessionId` | string\|null | `null` | OBSERVED from the first validated Codex turn — see below. |
| `ownerPid` | number | `$$` of the creating shell | Advisory liveness only, never an authorization input. |
| `ownerPidStart` | string | `ps -o lstart=` of that PID | Paired with `ownerPid` to defeat PID reuse. |
| `phase` | number | `1` | `1` = framework negotiation, `2` = plan evaluation. |
| `round` | number | `0` | The authoritative round counter (INV-ROUND-1). |
| `attemptCount` | number | `0` | Every Codex call, including retries and repair turns (INV-ROUND-1). |
| `threadId` | string\|null | `null` | Codex thread identity, verified every turn (INV-CONT-1). |
| `jobIds` | array | `[]` | Companion job ids issued for this run. |
| `framework` | object\|null | `null` | The locked framework artifact after Phase 1 (`{categories, max, attackSurface, unresolved}`, INV-SURFACE-1). |
| `ledger` | array | `[]` | Critique ledger entries, one per admitted `UB-n` (shape below); states per INV-LEDGER-1. |
| `lastCritiqueId` | number | `0` | Highest `UB-n` in play; passed as `codex-turn --last-id` (INV-ID-1, INV-ADMIT-1). |
| `ledgerUnchangedRounds` | number | `0` | Consecutive authoritative rounds with no status change and no admitted finding; `>= 2` is stalemate (INV-TERM-5). |
| `scores` | array | `[]` | Authoritative per-round score records (INV-SCORE-1, INV-SCORE-2). |
| `planPath` | string\|null | `null` | Path to `plan-full.md` in the session dir when the plan was digested (INV-BUDGET-1). |
| `degraded` | object | `{"reason": null}` | Non-null `reason` marks the run DEGRADED (INV-CONT-2, INV-TERM-3). |
| `authoritative` | boolean | `true` | Set `false` for DEGRADED/ADVISORY artifacts (INV-TERM-3). |
| `completed` | boolean | `false` | Terminal marker; authoritative for cleanup. |

`session-read` additionally injects a computed field (never stored):
`foreign: false` when `claudeSessionId` matches the caller's
`$CLAUDE_SESSION_ID`, otherwise `foreign: true` plus a `foreignDetail` string
naming both session ids.

### Ledger entry shape

```json
{ "id": "UB-3", "severity": "MAJOR", "category": "Gate & safety integrity",
  "summary": "one line", "status": "UNRESOLVED", "raisedRound": 1,
  "statusRound": 2, "needsUser": false, "linkedTo": null,
  "history": [ { "round": 2, "from": "UNRESOLVED", "to": "PARTIALLY_RESOLVED", "change": "what changed" } ] }
```

`id` is Codex's (INV-ID-1), never renumbered. `needsUser:true` marks a PARKED
entry (INV-ESC-2); the status itself stays one of the four INV-LEDGER-1 states.
`linkedTo` names the original id when the entry is a permitted re-raise
(INV-LEDGER-2). Noted findings (INV-ADMIT-1) are not ledger entries; they live
in the round's `validation.json` only.

### `codexSessionId` is observed, never minted

The openai-codex plugin owns `CODEX_COMPANION_SESSION_ID`; ultrablitz never
generates a Codex session id of its own. The field starts as `null` and is
filled with the value OBSERVED on the first fully validated Codex turn
(`codex-turn` reports it in its result JSON). From then on every turn must
match it, along with `threadId`, or the turn is a CONTINUITY failure
(INV-CONT-1).

### `completed` and cleanup

A run is treated as completed if the `completed` marker file exists in the
session dir OR `session.json` has `completed: true`. The JSON field is
authoritative because /tmp reapers can delete the marker file without touching
the directory. `cleanup-completed` removes only completed sessions, by exact
path — incomplete sessions are never auto-deleted.

## Atomic Write Protocol

`session-write <dir> <json-patch>` never modifies `session.json` in place:

1. The patch must parse as JSON (`jq -e .`), else the write is refused.
2. The merged document is written to `session.json.tmp` in the same
   directory: `jq '. * $patch * {lastActiveAt: now}'`. jq's `*` merge is
   recursive for objects; arrays and scalars in the patch replace the stored
   value wholesale (so `ledger`/`scores` updates must send the full array).
3. `mv -f session.json.tmp session.json` publishes it — rename is atomic on
   the same filesystem, so a reader never sees a torn file.

`session-new` uses the same tmp-then-rename sequence for the initial file.

## Single-Writer Rule

The writer key is `claudeSessionId`. Exactly one Claude session — the one
whose `$CLAUDE_SESSION_ID` matches the stored value — may mutate a session.
`session-read` surfaces violations mechanically via `foreign: true`; a caller
that sees a foreign session must treat it as read-only (inspect, list,
clean up if completed) and must not `session-write` to it. The utils script
deliberately does not hard-block foreign writes: enforcement is the skill's
responsibility at the call site, and the foreign flag is the mechanical
signal it keys on.

## Per-Repo Active-Run Lock

Independent of session dirs, at most one ultrablitz run may be active per
repository:

- **File**: `<state-dir>/active-<repohash>.lock`, where `<repohash>` is the
  first 16 hex chars of the SHA-256 of the repo root (`git rev-parse
  --show-toplevel`, falling back to `pwd -P` outside git).
- **Content**: `{runId, ownerPid, ownerPidStart}`.
- **Acquire**: `run-lock <runId> [--force-new]`. If the lock exists, the owner
  is probed for liveness: alive means `kill -0 <ownerPid>` succeeds AND the
  process's current `ps -o lstart=` equals the stored `ownerPidStart`
  (PID+start-time pair, so a recycled PID does not count as alive). A live
  owner blocks the new run unless `--force-new` is passed; a dead owner's
  lock is replaced automatically.
- **Release**: `run-unlock` removes the lock file.

The PID/start-time pair is advisory liveness only — it decides whether a
stale lock can be reclaimed, never whether an action is authorized (the
post-debate gate has its own unlock-code mechanism).
