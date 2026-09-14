#!/usr/bin/env bash
# End-to-end orchestration tests against the stub companion (plan D7).
#
# These cover the seam the old skill executed in prose: launch -> wait ->
# result -> validate -> session mutation, and every failure class.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

SANDBOX="$(new_sandbox)"
export ULTRABLITZ_STATE_DIR="$SANDBOX/state"
export ULTRABLITZ_TEST=1
export ULTRABLITZ_COMPANION_OVERRIDE="$UB_ROOT/tests/stub-companion.mjs"
trap 'rm -rf "$SANDBOX"' EXIT

C="$UB_ROOT/tests/fixtures/framework.json"
REPAIR="$UB_ROOT/references/prompts/format-repair.md"

run_scenario() {
  # run_scenario <scenario> <session-dir> [--resume] [--label L]
  local scen="$1" sd="$2"; shift 2
  STUB_SCENARIO="$scen" STUB_STATE="$sd/stub-state.json" \
    bash "$UTILS" codex-turn --session "$sd" --prompt-file "$sd/prompt.md" \
    --contract "$C" --repair-template "$REPAIR" "$@" 2>/dev/null
}

new_session() {
  local sd
  sd="$(bash "$UTILS" session-new)"
  printf 'a prompt\n' > "$sd/prompt.md"
  printf '%s\n' "$sd"
}

# --- happy path --------------------------------------------------------------
SD="$(new_session)"
t "happy: turn succeeds"
out="$(run_scenario happy "$SD")"
assert_json "$out" '.ok' 'true'
t "happy: threadId captured"
assert_json "$out" '.threadId' '01a0-stub-thread-0001'
t "happy: codex sessionId captured"
assert_json "$out" '.codexSessionId' 'stub-claude-session'
t "happy: no format repair needed"
assert_json "$out" '.formatRepair' 'false'
t "happy: one attempt"
assert_json "$out" '.attempts' '1'
t "happy: output file written and valid"
of="$(printf '%s' "$out" | jq -r .outputFile)"
bash "$UTILS" validate-output --contract "$C" --input "$of" >/dev/null && _ok || _no "output did not validate"

t "happy: session can record the turn and round advances"
bash "$UTILS" session-write "$SD" "$(jq -nc --arg t "$(printf '%s' "$out" | jq -r .threadId)" \
  --arg cs "$(printf '%s' "$out" | jq -r .codexSessionId)" '{round:1, threadId:$t, codexSessionId:$cs}')" >/dev/null
assert_json "$(cat "$SD/session.json")" '.round' '1'

t "happy: second turn on the same thread succeeds (resume)"
out2="$(run_scenario happy "$SD" --resume --label r2)"
assert_json "$out2" '.ok' 'true'
t "happy: thread continuity holds across rounds"
assert_json "$out2" '.threadId' '01a0-stub-thread-0001'

# --- empty output (E12) ------------------------------------------------------
SD="$(new_session)"
t "empty-output: classified RETRYABLE"
out="$(run_scenario empty-output "$SD")"
assert_json "$out" '.failureClass' 'RETRYABLE'
t "empty-output: not ok"
assert_json "$out" '.ok' 'false'
t "empty-output: threadId is discarded, never returned (E12)"
assert_json "$out" '.threadId' 'null'
t "empty-output: session state untouched"
assert_json "$(cat "$SD/session.json")" '.round' '0'

# --- continuity --------------------------------------------------------------
SD="$(new_session)"
t "mismatch: first turn ok"
out="$(run_scenario mismatch "$SD")"
assert_json "$out" '.ok' 'true'
bash "$UTILS" session-write "$SD" "$(jq -nc --arg t "$(printf '%s' "$out" | jq -r .threadId)" '{threadId:$t, round:1}')" >/dev/null
t "mismatch: second turn on a different thread is CONTINUITY"
out="$(run_scenario mismatch "$SD" --resume --label r2)"
assert_json "$out" '.failureClass' 'CONTINUITY'
t "mismatch: message names both thread ids"
assert_contains "$(printf '%s' "$out" | jq -r .message)" "threadId changed"
t "mismatch: round is not advanced by the failed turn"
assert_json "$(cat "$SD/session.json")" '.round' '1'

SD="$(new_session)"
t "session-mismatch: defense-in-depth check fires (E13 says this should never happen)"
out="$(run_scenario session-mismatch "$SD")"
bash "$UTILS" session-write "$SD" "$(jq -nc --arg cs "$(printf '%s' "$out" | jq -r .codexSessionId)" --arg t "$(printf '%s' "$out" | jq -r .threadId)" '{codexSessionId:$cs, threadId:$t, round:1}')" >/dev/null
out="$(run_scenario session-mismatch "$SD" --resume --label r2)"
assert_json "$out" '.failureClass' 'CONTINUITY'
t "session-mismatch: message names the session id"
assert_contains "$(printf '%s' "$out" | jq -r .message)" "sessionId changed"

# --- in-flight job -----------------------------------------------------------
SD="$(new_session)"
t "inflight: a running job is waited out and the turn then succeeds"
out="$(run_scenario inflight "$SD" --resume)"
assert_json "$out" '.ok' 'true'
t "inflight: no re-seed happened (thread preserved)"
assert_json "$out" '.threadId' '01a0-stub-thread-0001'

SD="$(new_session)"
t "inflight-stuck: still running after the bounded wait is RETRYABLE"
out="$(run_scenario inflight-stuck "$SD" --resume)"
assert_json "$out" '.failureClass' 'RETRYABLE'
t "inflight-stuck: message says a task is still running"
assert_contains "$(printf '%s' "$out" | jq -r .message)" "still running"
t "inflight-stuck: session untouched"
assert_json "$(cat "$SD/session.json")" '.round' '0'

# --- timeout -----------------------------------------------------------------
SD="$(new_session)"
t "timeout: unfinished job is RETRYABLE, not a silent pass"
out="$(STUB_SCENARIO=timeout STUB_STATE="$SD/stub-state.json" bash "$UTILS" codex-turn \
  --session "$SD" --prompt-file "$SD/prompt.md" --contract "$C" --timeout-ms 1 2>/dev/null)"
assert_json "$out" '.failureClass' 'RETRYABLE'
t "timeout: ledger/session untouched"
assert_json "$(cat "$SD/session.json")" '.round' '0'

# --- FORMAT policy -----------------------------------------------------------
SD="$(new_session)"
t "invalid-structure: one repair turn fixes it"
out="$(run_scenario invalid-structure "$SD")"
assert_json "$out" '.ok' 'true'
t "invalid-structure: formatRepair recorded"
assert_json "$out" '.formatRepair' 'true'
t "invalid-structure: exactly two attempts"
assert_json "$out" '.attempts' '2'
t "invalid-structure: pre-repair output preserved for audit"
[ -f "$SD/turn.pre-repair.md" ] && _ok || _no "pre-repair output not kept"
t "invalid-structure: repair prompt was rendered from the fixed template"
grep -q "This is a formatting fix only." "$SD/turn.repair-prompt.md" && _ok || _no "repair prompt not from template"
t "repair prompt carries no debate-protocol blocks (INV-FORMAT-1)"
grep -q "operating_stance" "$SD/turn.repair-prompt.md" && _no "protocol block leaked into repair prompt" || _ok
t "repair prompt has no unsubstituted slots"
grep -qE '\{(EXPECTED_HEADERS|CATEGORY_LIST|OFFENDING_OUTPUT)\}' "$SD/turn.repair-prompt.md" && _no "unsubstituted slot" || _ok

SD="$(new_session)"
t "invalid-structure-persistent: second failure is FORMAT"
out="$(run_scenario invalid-structure-persistent "$SD")"
assert_json "$out" '.failureClass' 'FORMAT'
t "invalid-structure-persistent: attempts capped at 2 (one repair only)"
assert_json "$out" '.attempts' '2'
t "invalid-structure-persistent: session untouched"
assert_json "$(cat "$SD/session.json")" '.round' '0'

SD="$(new_session)"
t "repair-changed-substance: a rescoring repair is rejected (INV-FORMAT-1)"
out="$(run_scenario repair-changed-substance "$SD")"
assert_json "$out" '.failureClass' 'FORMAT'
t "repair-changed-substance: reason names the score change"
assert_contains "$(printf '%s' "$out" | jq -r .message)" "repair changed scores"

# --- interrupt / resume ------------------------------------------------------
SD="$(new_session)"
t "interrupt: state survives and the run resumes on the same thread"
out="$(run_scenario happy "$SD")"
bash "$UTILS" session-write "$SD" "$(jq -nc --arg t "$(printf '%s' "$out" | jq -r .threadId)" '{round:1, phase:2, threadId:$t}')" >/dev/null
# simulate a fresh process reading the session back
resumed="$(bash "$UTILS" session-read "$SD")"
assert_json "$resumed" '.threadId' '01a0-stub-thread-0001'
t "interrupt: round preserved across the restart"
assert_json "$resumed" '.round' '1'
t "interrupt: next turn continues on that thread"
out="$(run_scenario happy "$SD" --resume --label after-interrupt)"
assert_json "$out" '.threadId' '01a0-stub-thread-0001'

# --- override safety ---------------------------------------------------------
t "companion override is ignored without ULTRABLITZ_TEST=1"
got="$(ULTRABLITZ_TEST=0 bash "$UTILS" resolve-companion 2>/dev/null)"
assert_ne "$got" "$ULTRABLITZ_COMPANION_OVERRIDE"
t "doctor reports the override loudly when active"
out="$(bash "$UTILS" doctor --json 2>/dev/null)"
assert_contains "$out" "TEST OVERRIDE ACTIVE"

finish
