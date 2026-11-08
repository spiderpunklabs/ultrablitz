#!/usr/bin/env bash
# ultrablitz-gate.sh — PreToolUse hook for the post-debate confirmation gate.
#
# Blocks Edit/Write/NotebookEdit/Bash after an ultrablitz debate completes until
# the user confirms. Fail-closed: anything unexpected denies.
#
# Input contract: Claude Code sends the tool call as JSON on STDIN
# ({tool_name, tool_input, ...}). There is no env-var input path — a second
# input channel would be a second attack surface (plan A3, bug #2).
#
# Part of the ultrablitz skill: https://github.com/spiderpunklabs/ultrablitz
set -uo pipefail

# TMPDIR often ends in a slash (macOS); normalise before composing so this path
# is byte-identical to the one ultrablitz-utils.sh computes.
UB_TMP="${TMPDIR:-/tmp}"
UB_TMP="${UB_TMP%/}"
STATE_DIR="${ULTRABLITZ_STATE_DIR:-$UB_TMP/ultrablitz-$(id -u)}"
STATE_DIR="${STATE_DIR%/}"
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
REPO_ROOT="${GIT_ROOT:-$(pwd -P)}"
GATE_LOG="$STATE_DIR/gate.log"

# Resolve the lock for this CWD. Git context: hash(repoRoot), one deterministic
# path. Non-git: gate-arm hashes "pwd|runId" so parallel runs under a shared
# non-git parent do not collide; walk the candidates and match the recorded
# repoRoot. Plain [ -f ] here (no jq yet): a candidate that is not a readable
# regular file is left for the trust checks below to deny.
LOCK_FILE=""
if [ -n "$GIT_ROOT" ]; then
  REPO_HASH="$(printf '%s' "$REPO_ROOT" | shasum -a 256 | cut -c1-16)"
  LOCK_FILE="$STATE_DIR/gate-${REPO_HASH}.lock"
elif command -v jq >/dev/null 2>&1; then
  for cand in "$STATE_DIR"/gate-*.lock; do
    [ -e "$cand" ] || continue
    if [ "$(jq -r '.repoRoot // empty' "$cand" 2>/dev/null)" = "$REPO_ROOT" ]; then
      LOCK_FILE="$cand"
      break
    fi
  done
else
  # No jq → cannot read repoRoot; fail closed on ANY lock in a non-git CWD.
  for cand in "$STATE_DIR"/gate-*.lock; do
    [ -e "$cand" ] && { LOCK_FILE="$cand"; break; }
  done
fi
CONF_FILE="${LOCK_FILE%.lock}.confirmed"
CLEAR_CMD="bash \${ULTRABLITZ_ROOT:-\$HOME/.claude/skills/ultrablitz}/hooks/ultrablitz-utils.sh gate-clear"

allow() { exit 0; }

deny() {
  # JSON built with jq so paths containing quotes/backslashes cannot break it (C1).
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg r "$1" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Ultrablitz gate active (jq missing, cannot format reason)."}}\n'
  fi
  gate_log deny "$1"
  exit 0
}

STATE_DIR_UNTRUSTED=0

gate_log() {
  command -v jq >/dev/null 2>&1 || return 0
  # Never write into a directory the trust check just rejected (defect S13):
  # [ -d ] follows symlinks, so without this flag the log line would land
  # wherever the symlink points.
  [ "$STATE_DIR_UNTRUSTED" = 1 ] && return 0
  [ -d "$STATE_DIR" ] || return 0
  # One JSON object per line, SAME five keys as ultrablitz-utils.sh's writer
  # (defect S4: two writers, one file, one schema). runId is whatever the lock
  # parse has established by the time of the event; null before that.
  jq -n -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ev "$1" --arg detail "$2" \
    --arg run "${LOCK_RUN_ID:-}" --arg repo "$REPO_ROOT" --arg tool "${TOOL_NAME:-?}" \
    '{ts:$ts, event:$ev, runId:(if $run == "" then null else $run end), repo:$repo, tool:$tool, detail:$detail}' >>"$GATE_LOG" 2>/dev/null || true
}

# Read the tool call from stdin (never blocks: hooks always get input).
INPUT="$(cat 2>/dev/null || true)"
TOOL_NAME=""
TOOL_INPUT=""
if command -v jq >/dev/null 2>&1 && [ -n "$INPUT" ]; then
  TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
  TOOL_INPUT="$(printf '%s' "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null)"
fi

# No lock → nothing to enforce. Cheapest check first.
[ -n "$LOCK_FILE" ] && [ -e "$LOCK_FILE" ] || allow

# jq is required to validate the lock. Fail closed.
if ! command -v jq >/dev/null 2>&1; then
  deny "Ultrablitz gate requires jq and is fail-closed without it. Install: brew install jq (macOS) or apt-get install jq"
fi

# --- path trust (C2): the state dir and every leaf must be ours -------------
path_untrusted() {
  local p="$1"
  [ -L "$p" ] && return 0
  local owner
  owner="$(stat -c '%u' "$p" 2>/dev/null || stat -f '%u' "$p" 2>/dev/null)"
  [ "$owner" = "$(id -u)" ] || return 0
  return 1
}

if [ -L "$STATE_DIR" ] || path_untrusted "$STATE_DIR"; then
  STATE_DIR_UNTRUSTED=1
  deny "Ultrablitz gate: state directory is a symlink or not owned by you ($STATE_DIR). Refusing to trust it. Clear with: $CLEAR_CMD"
fi
STATE_MODE="$(stat -c '%a' "$STATE_DIR" 2>/dev/null || stat -f '%Lp' "$STATE_DIR" 2>/dev/null)"
if [ "$STATE_MODE" != "700" ]; then
  STATE_DIR_UNTRUSTED=1
  deny "Ultrablitz gate: state directory mode is $STATE_MODE, expected 700 ($STATE_DIR). Clear with: $CLEAR_CMD"
fi
if path_untrusted "$LOCK_FILE" || [ ! -f "$LOCK_FILE" ]; then
  deny "Ultrablitz gate: lock file is a symlink, missing, or not owned by you. Clear with: $CLEAR_CMD"
fi

# --- lock contents -----------------------------------------------------------
LOCK_JSON="$(cat "$LOCK_FILE" 2>/dev/null)"
printf '%s' "$LOCK_JSON" | jq -e . >/dev/null 2>&1 ||
  deny "Ultrablitz gate: lock file is not valid JSON. Clear with: $CLEAR_CMD"

LOCK_RUN_ID="$(printf '%s' "$LOCK_JSON" | jq -re '.runId // empty' 2>/dev/null || true)"
LOCK_CODE="$(printf '%s' "$LOCK_JSON" | jq -re '.unlockCode // empty' 2>/dev/null || true)"
LOCK_CREATED="$(printf '%s' "$LOCK_JSON" | jq -re '.createdAt // empty' 2>/dev/null || true)"
LOCK_REPO="$(printf '%s' "$LOCK_JSON" | jq -re '.repoRoot // empty' 2>/dev/null || true)"

if [ -z "$LOCK_RUN_ID" ] || [ -z "$LOCK_CODE" ]; then
  deny "Ultrablitz gate: lock file is missing runId or unlockCode. Clear with: $CLEAR_CMD"
fi

# Lock belongs to a different repo → not ours to enforce.
[ -n "$LOCK_REPO" ] && [ "$LOCK_REPO" != "$REPO_ROOT" ] && allow

# --- confirmation ------------------------------------------------------------
if [ -e "$CONF_FILE" ]; then
  if path_untrusted "$CONF_FILE" || [ ! -f "$CONF_FILE" ]; then
    deny "Ultrablitz gate: confirmation file is a symlink or not owned by you. Clear with: $CLEAR_CMD"
  fi
  CONF_JSON="$(cat "$CONF_FILE" 2>/dev/null)"
  if printf '%s' "$CONF_JSON" | jq -e . >/dev/null 2>&1; then
    CONF_RUN_ID="$(printf '%s' "$CONF_JSON" | jq -re '.runId // empty' 2>/dev/null || true)"
    CONF_CODE="$(printf '%s' "$CONF_JSON" | jq -re '.unlockCode // empty' 2>/dev/null || true)"
    if [ -n "$CONF_RUN_ID" ] && [ -n "$CONF_CODE" ] &&
      [ "$CONF_RUN_ID" = "$LOCK_RUN_ID" ] && [ "$CONF_CODE" = "$LOCK_CODE" ]; then
      gate_log allow "confirmed run $LOCK_RUN_ID"
      allow
    fi
  fi
  deny "Ultrablitz gate: confirmation file present but does not match the lock. Clear with: $CLEAR_CMD"
fi

# --- staleness (no epoch=0 fallback: unparseable timestamp denies) -----------
if [ -n "$LOCK_CREATED" ]; then
  # TZ=UTC is load-bearing: BSD `date -j -f` interprets the string in LOCAL
  # time, so without it a freshly created lock reads as hours old on any host
  # east of UTC and the gate denies forever.
  created_epoch="$(
    TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LOCK_CREATED" +%s 2>/dev/null ||
      date -u -d "$LOCK_CREATED" +%s 2>/dev/null ||
      echo ""
  )"
  if [ -z "$created_epoch" ]; then
    deny "Ultrablitz gate: lock timestamp '$LOCK_CREATED' could not be parsed; refusing to treat the lock as fresh. Clear with: $CLEAR_CMD"
  fi
  age=$(($(date +%s) - created_epoch))
  if [ "$age" -gt 14400 ]; then
    deny "Ultrablitz gate: stale lock ($((age / 3600))h old, run $LOCK_RUN_ID). Stale locks are never auto-allowed. Clear with: $CLEAR_CMD"
  fi
else
  deny "Ultrablitz gate: lock has no createdAt. Clear with: $CLEAR_CMD"
fi

# --- single-use carve-out: the confirmation write itself ---------------------
# gate-confirm normally writes this file directly, but if the assistant uses the
# Write tool the hook must let exactly that one write through, pre-validated.
if [ "$TOOL_NAME" = "Write" ] && [ -n "$TOOL_INPUT" ]; then
  WRITE_PATH="$(printf '%s' "$TOOL_INPUT" | jq -r '.file_path // empty' 2>/dev/null)"
  if [ "$WRITE_PATH" = "$CONF_FILE" ] && [ ! -e "$CONF_FILE" ]; then
    WRITE_CONTENT="$(printf '%s' "$TOOL_INPUT" | jq -r '.content // empty' 2>/dev/null)"
    if printf '%s' "$WRITE_CONTENT" | jq -e . >/dev/null 2>&1; then
      W_RUN="$(printf '%s' "$WRITE_CONTENT" | jq -re '.runId // empty' 2>/dev/null || true)"
      W_CODE="$(printf '%s' "$WRITE_CONTENT" | jq -re '.unlockCode // empty' 2>/dev/null || true)"
      if [ -n "$W_RUN" ] && [ -n "$W_CODE" ] && [ "$W_RUN" = "$LOCK_RUN_ID" ] && [ "$W_CODE" = "$LOCK_CODE" ]; then
        gate_log allow "confirmation write for run $LOCK_RUN_ID"
        allow
      fi
    fi
  fi
fi

deny "Ultrablitz confirmation gate active (run $LOCK_RUN_ID). Review the refined plan, then confirm with: bash \${ULTRABLITZ_ROOT:-\$HOME/.claude/skills/ultrablitz}/hooks/ultrablitz-utils.sh gate-confirm — or discard with: $CLEAR_CMD"
