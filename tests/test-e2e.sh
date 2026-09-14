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

# --- resume predicate (plan A3 / defect C3) -----------------------------------
SD="$(new_session)"
t "resume on a fresh session is refused, not honoured (no debate turn exists)"
out="$(run_scenario happy "$SD" --resume)"
assert_json "$out" '.ok' 'true'
t "resume refusal is reported"
rr="$(printf '%s' "$out" | jq -r '.resumeRefused // ""')"
assert_contains "$rr" "no validated debate turn"
t "refused resume launches fresh — no --resume-last reached the companion"
argv="$(jq -r '.argv[0]' "$SD/stub-state.json")"
assert_not_contains "$argv" "--resume-last"

SD="$(new_session)"
t "resume after only a smoke turn is refused (would graft onto the smoke thread)"
out="$(run_scenario happy "$SD" --label smoke)"
out="$(run_scenario happy "$SD" --resume --label p2-r1)"
assert_json "$out" '.ok' 'true'
rr="$(printf '%s' "$out" | jq -r '.resumeRefused // ""')"
assert_contains "$rr" "smoke"
t "smoke-refused resume also launched fresh"
argv="$(jq -r '.argv[1]' "$SD/stub-state.json")"
assert_not_contains "$argv" "--resume-last"

SD="$(new_session)"
t "resume after a validated debate turn IS honoured"
out="$(run_scenario happy "$SD" --label p1-r1)"
out="$(run_scenario happy "$SD" --resume --label p1-r2)"
assert_json "$out" '.resumeRefused' 'null'
argv="$(jq -r '.argv[1]' "$SD/stub-state.json")"
assert_contains "$argv" "--resume-last"
t "codex-turn recorded the turn for the predicate itself (sessionRecorded)"
assert_json "$out" '.sessionRecorded' 'true'
t "session.json carries lastTurnLabel from the code, not the caller"
assert_json "$(cat "$SD/session.json")" '.lastTurnLabel' 'p1-r2'

# --- in-flight job -----------------------------------------------------------
SD="$(new_session)"
t "inflight: seed turn succeeds"
out="$(run_scenario inflight "$SD" --label p1-r1)"
assert_json "$out" '.ok' 'true'
t "inflight: a running job is waited out and the resumed turn then succeeds"
out="$(run_scenario inflight "$SD" --resume --label p1-r2)"
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

# --- model resolution and account refusals (plan E1/E2/E5) --------------------
SD="$(new_session)"
t "resolve-model with no input picks the newest preference model"
out="$(env -u ULTRABLITZ_MODEL bash "$UTILS" resolve-model --session "$SD")"
assert_json "$out" '.model' 'gpt-6-astra'
t "resolve-model records origin preference"
assert_json "$out" '.origin' 'preference'
t "resolve-model persists into session.json"
assert_json "$(cat "$SD/session.json")" '.model' 'gpt-6-astra'
t "resolve-model: --model flag wins and is explicit"
out="$(ULTRABLITZ_MODEL=envmodel bash "$UTILS" resolve-model --session "$SD" --model flagmodel)"
assert_json "$out" '.model' 'flagmodel'
t "resolve-model: flag origin is explicit"
assert_json "$out" '.origin' 'explicit'
t "resolve-model: ULTRABLITZ_MODEL is explicit too"
out="$(ULTRABLITZ_MODEL=envmodel bash "$UTILS" resolve-model --session "$SD")"
assert_json "$out" '.origin' 'explicit'
t "resolve-model: .ultrablitz.json model is used when nothing explicit is set"
cfgdir="$SANDBOX/cfgrepo"; mkdir -p "$cfgdir"
printf '{"model":"cfg-model"}\n' > "$cfgdir/.ultrablitz.json"
out="$(cd "$cfgdir" && env -u ULTRABLITZ_MODEL bash "$UTILS" resolve-model --session "$SD")"
assert_json "$out" '.model' 'cfg-model'
t "resolve-model: config origin is config"
assert_json "$out" '.origin' 'config'

SD="$(new_session)"
env -u ULTRABLITZ_MODEL bash "$UTILS" resolve-model --session "$SD" >/dev/null
t "model-refused: preference model is downgraded once and the turn succeeds"
out="$(run_scenario model-refused "$SD")"
assert_json "$out" '.ok' 'true'
t "model-refused: the turn ran on the fallback model"
assert_json "$out" '.model' 'gpt-5.3-codex-spark'
t "model-refused: the downgrade is reported"
assert_json "$out" '.modelDowngraded.from' 'gpt-6-astra'
t "model-refused: two attempts (refusal + retry)"
assert_json "$out" '.attempts' '2'
t "model-refused: session.json now names the model actually in use"
assert_json "$(cat "$SD/session.json")" '.model' 'gpt-5.3-codex-spark'
t "model-refused: the downgrade is recorded with its reason"
assert_json "$(cat "$SD/session.json")" '.modelDowngraded.from' 'gpt-6-astra'
t "model-refused: the fallback flag actually reached the companion"
argv="$(jq -r '.argv[1]' "$SD/stub-state.json")"
assert_contains "$argv" "--model gpt-5.3-codex-spark"

SD="$(new_session)"
env -u ULTRABLITZ_MODEL bash "$UTILS" resolve-model --session "$SD" >/dev/null
t "model-refused-all: every candidate refused ends FATAL"
out="$(run_scenario model-refused-all "$SD")"
assert_json "$out" '.failureClass' 'FATAL'
t "model-refused-all: the message says models were refused"
assert_contains "$(printf '%s' "$out" | jq -r .message)" "refused"
t "model-refused-all: session untouched by the failed turn"
assert_json "$(cat "$SD/session.json")" '.round' '0'

SD="$(new_session)"
t "model-explicit-refused: a user-named model is never downgraded"
out="$(run_scenario model-refused-all "$SD" --model gpt-6-astra)"
assert_json "$out" '.failureClass' 'FATAL'
t "model-explicit-refused: the refusal is reported, with alternatives"
assert_contains "$(printf '%s' "$out" | jq -r .message)" "refused by this account"
t "model-explicit-refused: exactly one attempt — no silent substitution"
assert_json "$out" '.attempts' '1'
t "model-explicit-refused: no downgrade recorded"
assert_json "$out" '.modelDowngraded' 'null'

SD="$(new_session)"
env -u ULTRABLITZ_MODEL bash "$UTILS" resolve-model --session "$SD" >/dev/null
t "unknown-shape 400: one bounded probe of the next candidate, then success"
out="$(run_scenario model-refused-unknown-shape "$SD")"
assert_json "$out" '.ok' 'true'
t "unknown-shape 400: probe recorded as modelSelectionUnknown"
assert_json "$(cat "$SD/session.json")" '.modelSelectionUnknown.from' 'gpt-6-astra'
t "unknown-shape 400: the run continues on the probed model"
assert_json "$out" '.model' 'gpt-5.3-codex-spark'

# --- validation artifact is a hard gate (plan A9 / defect S2) ------------------
SD="$(new_session)"
printf 'this is not a contract\n' > "$SD/bad-contract.json"
t "an unusable validation artifact is FORMAT, never success"
out="$(STUB_SCENARIO=happy STUB_STATE="$SD/stub-state.json" bash "$UTILS" codex-turn \
  --session "$SD" --prompt-file "$SD/prompt.md" --contract "$SD/bad-contract.json" 2>/dev/null)"
assert_json "$out" '.ok' 'false'
t "the failure names the validation artifact problem"
assert_json "$out" '.validationUnreadable' 'true'
t "validator stderr is preserved for diagnosis, not discarded"
[ -s "$SD/turn.validation.err" ] && _ok || _no "validation stderr file empty or missing"
t "hard-gated turn mutated nothing"
assert_json "$(cat "$SD/session.json")" '.round' '0'

# --- model / effort passthrough ----------------------------------------------
# A live account can be refused the companion's default model ("not supported
# when using Codex with a ChatGPT account"), so these flags must actually reach
# the companion rather than being silently dropped.
SD="$(new_session)"
t "model and effort flags reach the companion"
out="$(STUB_SCENARIO=happy STUB_STATE="$SD/stub-state.json" bash "$UTILS" codex-turn \
  --session "$SD" --prompt-file "$SD/prompt.md" --model spark --effort high 2>/dev/null)"
argv="$(jq -r '.argv[0]' "$SD/stub-state.json")"
assert_contains "$argv" "--model spark"
t "effort flag reaches the companion"
assert_contains "$argv" "--effort high"
t "the turn still succeeds with both flags"
assert_json "$out" '.ok' 'true'

SD="$(new_session)"
t "no model flag is sent when none is requested"
out="$(STUB_SCENARIO=happy STUB_STATE="$SD/stub-state.json" bash "$UTILS" codex-turn \
  --session "$SD" --prompt-file "$SD/prompt.md" 2>/dev/null)"
argv="$(jq -r '.argv[0]' "$SD/stub-state.json")"
assert_not_contains "$argv" "--model"
t "no effort flag is sent when none is requested"
assert_not_contains "$argv" "--effort"

SD="$(new_session)"
t "ULTRABLITZ_MODEL env var is honoured"
out="$(ULTRABLITZ_MODEL=spark STUB_SCENARIO=happy STUB_STATE="$SD/stub-state.json" bash "$UTILS" codex-turn \
  --session "$SD" --prompt-file "$SD/prompt.md" 2>/dev/null)"
argv="$(jq -r '.argv[0]' "$SD/stub-state.json")"
assert_contains "$argv" "--model spark"

# --- override safety ---------------------------------------------------------
t "companion override is ignored without ULTRABLITZ_TEST=1"
got="$(ULTRABLITZ_TEST=0 bash "$UTILS" resolve-companion 2>/dev/null)"
assert_ne "$got" "$ULTRABLITZ_COMPANION_OVERRIDE"
t "doctor reports the override loudly when active"
out="$(bash "$UTILS" doctor --json 2>/dev/null)"
assert_contains "$out" "TEST OVERRIDE ACTIVE"

finish
