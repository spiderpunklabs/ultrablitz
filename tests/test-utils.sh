#!/usr/bin/env bash
# Unit tests for ultrablitz-utils.sh (plan D1).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

SANDBOX="$(new_sandbox)"
export ULTRABLITZ_STATE_DIR="$SANDBOX/state"
# Cleanup never deletes: it moves to a trash dir. Point it at the sandbox so
# tests do not litter the real ~/.Trash.
export ULTRABLITZ_TRASH_DIR="$SANDBOX/trash"
trap 'rm -rf "$SANDBOX"' EXIT

t "state-dir is created mode 700 with no double slash"
out="$(bash "$UTILS" state-dir)"
mode="$(stat -f '%Lp' "$out" 2>/dev/null || stat -c '%a' "$out")"
assert_eq "$mode" "700"
t "default state-dir path has no '//' even when TMPDIR ends in a slash"
# The default composition is what the gate hook recomputes independently, so it
# must be byte-identical. An explicit ULTRABLITZ_STATE_DIR is used verbatim.
defpath="$(env -u ULTRABLITZ_STATE_DIR TMPDIR="$SANDBOX/tmpslash/" bash "$UTILS" state-dir)"
case "$defpath" in *//*) _no "double slash in $defpath" ;; *) _ok ;; esac

t "gate hook and utils compute the same default state dir"
hookpath="$(env -u ULTRABLITZ_STATE_DIR TMPDIR="$SANDBOX/tmpslash/" bash -c '
  UB_TMP="${TMPDIR:-/tmp}"; UB_TMP="${UB_TMP%/}"
  printf "%s\n" "${ULTRABLITZ_STATE_DIR:-$UB_TMP/ultrablitz-$(id -u)}"')"
assert_eq "$hookpath" "$defpath"

# --- A1: resolve-companion must not require the exec bit (bug #1) -----------
t "resolve-companion accepts a 0644 companion (bug #1)"
fakehome="$SANDBOX/home"
mkdir -p "$fakehome/.claude/plugins/cache/openai-codex/codex/1.0.3/scripts"
comp="$fakehome/.claude/plugins/cache/openai-codex/codex/1.0.3/scripts/codex-companion.mjs"
echo "// stub" > "$comp"
chmod 644 "$comp"
got="$(HOME="$fakehome" bash "$UTILS" resolve-companion 2>&1)"
assert_eq "$got" "$comp"

t "resolve-companion picks the highest version"
mkdir -p "$fakehome/.claude/plugins/cache/openai-codex/codex/1.0.10/scripts"
comp2="$fakehome/.claude/plugins/cache/openai-codex/codex/1.0.10/scripts/codex-companion.mjs"
echo "// stub" > "$comp2"; chmod 644 "$comp2"
got="$(HOME="$fakehome" bash "$UTILS" resolve-companion 2>&1)"
assert_eq "$got" "$comp2"

t "resolve-companion fails with guidance when absent"
empty="$SANDBOX/empty-home"; mkdir -p "$empty"
out="$(HOME="$empty" bash "$UTILS" resolve-companion 2>&1)"; rc=$?
assert_rc "$rc" 1
t "resolve-companion failure names the install command"
assert_contains "$out" "plugin install openai-codex"

# --- sessions ----------------------------------------------------------------
t "session-new creates a session with schema fields"
SD="$(bash "$UTILS" session-new)"
js="$(cat "$SD/session.json")"
assert_json "$js" '.schemaVersion' '1'
t "session-new records authoritative:true"
assert_json "$js" '.authoritative' 'true'
t "session-new starts not completed"
assert_json "$js" '.completed' 'false'
t "session dir is mode 700"
mode="$(stat -f '%Lp' "$SD" 2>/dev/null || stat -c '%a' "$SD")"
assert_eq "$mode" "700"

t "session-write merges a patch atomically"
bash "$UTILS" session-write "$SD" '{"round":3,"threadId":"abc"}' >/dev/null
js="$(cat "$SD/session.json")"
assert_json "$js" '.round' '3'
t "session-write preserves untouched fields"
assert_json "$js" '.schemaVersion' '1'
t "session-write leaves no .tmp behind"
[ -e "$SD/session.json.tmp" ] && _no "tmp file left behind" || _ok

t "session-write rejects invalid JSON patches"
out="$(bash "$UTILS" session-write "$SD" 'not json' 2>&1)"; rc=$?
assert_rc "$rc" 1

t "session-write refuses a symlinked session.json"
SD2="$(bash "$UTILS" session-new)"
rm "$SD2/session.json"; ln -s /etc/hosts "$SD2/session.json"
out="$(bash "$UTILS" session-write "$SD2" '{"round":1}' 2>&1)"; rc=$?
assert_rc "$rc" 1
t "symlink refusal is explained"
assert_contains "$out" "refusing symlink"
rm -f "$SD2/session.json"

t "session-read flags a session owned by another Claude session"
out="$(CLAUDE_SESSION_ID="someone-else" bash "$UTILS" session-read "$SD")"
assert_json "$out" '.foreign' 'true'
t "session-read reports foreign:false for the owner"
own="$(jq -r .claudeSessionId "$SD/session.json")"
out="$(CLAUDE_SESSION_ID="$own" bash "$UTILS" session-read "$SD")"
assert_json "$out" '.foreign' 'false'

# --- single-writer contract inside session-write (plan A7, four rows) --------
t "a foreign session's write is refused"
SDA="$(CLAUDE_SESSION_ID=alice bash "$UTILS" session-new)"
before="$(cat "$SDA/session.json")"
out="$(CLAUDE_SESSION_ID=bob bash "$UTILS" session-write "$SDA" '{"round":9}' 2>&1)"; rc=$?
assert_rc "$rc" 1
t "the refusal names the owning session"
assert_contains "$out" "alice"
t "a refused write leaves the file byte-identical"
assert_eq "$(cat "$SDA/session.json")" "$before"

t "concrete owner + missing env is refused — absent never means matches"
out="$(env -u CLAUDE_SESSION_ID bash "$UTILS" session-write "$SDA" '{"round":9}' 2>&1)"; rc=$?
assert_rc "$rc" 1
t "the missing-env refusal names the deterministic recovery"
assert_contains "$out" "--force-new"

t "an unknown-owner session is adopted by the first concrete session"
SDU="$(env -u CLAUDE_SESSION_ID bash "$UTILS" session-new)"
out="$(CLAUDE_SESSION_ID=carol bash "$UTILS" session-write "$SDU" '{"round":1}' 2>&1)"; rc=$?
assert_rc "$rc" 0
t "adoption claims the session"
assert_json "$(cat "$SDU/session.json")" '.claudeSessionId' 'carol'
t "adoption is timestamped"
[ -n "$(jq -r '.claudeSessionIdAdoptedAt // ""' "$SDU/session.json")" ] && _ok || _no "claudeSessionIdAdoptedAt not recorded"
t "after adoption, a different session is refused"
out="$(CLAUDE_SESSION_ID=dave bash "$UTILS" session-write "$SDU" '{"round":2}' 2>&1)"; rc=$?
assert_rc "$rc" 1

t "both-unknown writes are allowed (single-writer is vacuous)"
SDN="$(env -u CLAUDE_SESSION_ID bash "$UTILS" session-new)"
out="$(env -u CLAUDE_SESSION_ID bash "$UTILS" session-write "$SDN" '{"round":2}' 2>&1)"; rc=$?
assert_rc "$rc" 0

# --- cleanup -----------------------------------------------------------------
t "cleanup-completed leaves incomplete sessions alone"
KEEP="$(bash "$UTILS" session-new)"
DONE="$(bash "$UTILS" session-new)"
touch "$DONE/completed"
bash "$UTILS" cleanup-completed >/dev/null
[ -d "$KEEP" ] && _ok || _no "incomplete session was deleted"
t "cleanup-completed moves completed sessions out of the state dir"
[ -d "$DONE" ] && _no "completed session survived" || _ok
t "cleanup-completed trashes rather than deletes (reversible)"
trashed="$(find "$ULTRABLITZ_TRASH_DIR" -maxdepth 1 -name "ultrablitz-$(basename "$DONE")-*" | head -1)"
[ -n "$trashed" ] && [ -f "$trashed/completed" ] && _ok || _no "completed session not found in trash dir"

t "cleanup-completed honours session.json completed:true without the marker (bug #9)"
D3="$(bash "$UTILS" session-new)"
bash "$UTILS" session-write "$D3" '{"completed":true}' >/dev/null
bash "$UTILS" cleanup-completed >/dev/null
[ -d "$D3" ] && _no "completed-by-json session survived" || _ok

t "cleanup-list prints an exact trash-session command, never rm"
out="$(bash "$UTILS" cleanup-list)"
assert_contains "$out" "trash-session $KEEP"
t "cleanup-list output contains no rm"
assert_not_contains "$out" "rm -r"

t "trash-session moves one exact session to the trash"
out="$(bash "$UTILS" trash-session "$KEEP")"; rc=$?
assert_rc "$rc" 0
t "trash-session leaves nothing behind"
[ -d "$KEEP" ] && _no "session still present" || _ok
t "trash-session refuses a path outside the state dir"
OUTSIDE="$SANDBOX/not-a-session"; mkdir -p "$OUTSIDE"
bash "$UTILS" trash-session "$OUTSIDE" >/dev/null 2>&1; rc=$?
assert_rc "$rc" 2
t "trash-session leaves the refused path untouched"
[ -d "$OUTSIDE" ] && _ok || _no "outside dir was moved"
t "trash-session refuses a symlink inside the state dir"
ln -sfn "$OUTSIDE" "$ULTRABLITZ_STATE_DIR/session-link"
bash "$UTILS" trash-session "$ULTRABLITZ_STATE_DIR/session-link" >/dev/null 2>&1; rc=$?
assert_rc "$rc" 2
rm -f "$ULTRABLITZ_STATE_DIR/session-link"

# --- run lock ----------------------------------------------------------------
t "run-lock succeeds when free"
out="$(bash "$UTILS" run-lock run-a 2>&1)"; rc=$?
assert_rc "$rc" 0
t "run-lock refuses a second live run in the same repo"
# Forge a lock owned by a live process (this shell's parent is alive).
lock="$ULTRABLITZ_STATE_DIR/active-$(bash "$UTILS" repo-hash).lock"
jq -n --arg r other --arg pid "$$" --arg ps "$(ps -o lstart= -p $$ | tr -s ' ' | sed 's/^ *//;s/ *$//')" \
  '{runId:$r, ownerPid:($pid|tonumber), ownerPidStart:$ps}' > "$lock"
out="$(bash "$UTILS" run-lock run-b 2>&1)"; rc=$?
assert_rc "$rc" 1
t "run-lock refusal mentions --force-new"
assert_contains "$out" "--force-new"
t "run-lock --force-new overrides a live lock"
out="$(bash "$UTILS" run-lock run-b --force-new 2>&1)"; rc=$?
assert_rc "$rc" 0
t "run-lock takes over when the owner PID is dead"
jq -n '{runId:"ghost", ownerPid:999999, ownerPidStart:"never"}' > "$lock"
out="$(bash "$UTILS" run-lock run-c 2>&1)"; rc=$?
assert_rc "$rc" 0
bash "$UTILS" run-unlock >/dev/null

finish
