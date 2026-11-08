#!/usr/bin/env bash
# tests/contract.bats.sh — companion contract tests (plain bash; the .bats.sh
# name only keeps it discoverable next to the other suites, bats is NOT used).
#
# Two layers:
#   1. The recorded fixtures in tests/fixtures/companion/ must keep describing
#      the payload shape ultrablitz reads. If a field the skill depends on is
#      renamed here, this file is the tripwire.
#   2. If the real codex companion is installed, its --help must still
#      advertise the flags the skill invokes. Skipped (not failed) when the
#      plugin is absent, e.g. in CI.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

FIX="$UB_ROOT/tests/fixtures/companion"

# --- task-success.json ---------------------------------------------------------
js="$(cat "$FIX/task-success.json")"
t "task-success: .status exists"
assert_json "$js" 'has("status")' 'true'
t "task-success: .threadId exists"
assert_json "$js" 'has("threadId")' 'true'
t "task-success: .rawOutput exists"
assert_json "$js" 'has("rawOutput")' 'true'
t "task-success: succeeded turn has status 0"
assert_json "$js" '.status' '0'
t "task-success: succeeded turn has non-empty rawOutput"
assert_json "$js" '.rawOutput | length > 0' 'true'

# --- task-failure.json (evidence E12) -------------------------------------------
js="$(cat "$FIX/task-failure.json")"
t "task-failure: .status exists"
assert_json "$js" 'has("status")' 'true'
t "task-failure: .threadId exists"
assert_json "$js" 'has("threadId")' 'true'
t "task-failure: .rawOutput exists"
assert_json "$js" 'has("rawOutput")' 'true'
t "task-failure: .status is 1"
assert_json "$js" '.status' '1'
t "task-failure: .rawOutput is empty"
assert_json "$js" '.rawOutput' ''
t "task-failure: threadId is STILL non-empty on failure (E12: a threadId is not proof of a usable thread)"
assert_json "$js" '.threadId | length > 0' 'true'

# --- result.json -----------------------------------------------------------------
js="$(cat "$FIX/result.json")"
t "result: .job.sessionId exists"
assert_json "$js" '.job | has("sessionId")' 'true'
t "result: .job.threadId exists"
assert_json "$js" '.job | has("threadId")' 'true'
t "result: .storedJob.result.status exists"
assert_json "$js" '.storedJob.result | has("status")' 'true'
t "result: .storedJob.result.rawOutput exists"
assert_json "$js" '.storedJob.result | has("rawOutput")' 'true'
t "result: .storedJob.result.threadId exists"
assert_json "$js" '.storedJob.result | has("threadId")' 'true'

# --- status-all.json ---------------------------------------------------------------
js="$(cat "$FIX/status-all.json")"
t "status-all: .running is an array"
assert_json "$js" '.running | type' 'array'
t "status-all: .latestFinished.id exists"
assert_json "$js" '.latestFinished | has("id")' 'true'
t "status-all: .latestFinished.sessionId exists"
assert_json "$js" '.latestFinished | has("sessionId")' 'true'
t "status-all: .latestFinished.threadId exists"
assert_json "$js" '.latestFinished | has("threadId")' 'true'

# --- setup.json ----------------------------------------------------------------------
js="$(cat "$FIX/setup.json")"
t "setup: .ready exists"
assert_json "$js" 'has("ready")' 'true'
t "setup: .auth.loggedIn exists"
assert_json "$js" '.auth | has("loggedIn")' 'true'

# --- live companion --help contract (skipped when not installed) ----------------------
# Resolve OUTSIDE test mode so a stub override can never satisfy this check.
COMPANION="$(ULTRABLITZ_TEST=0 ULTRABLITZ_COMPANION_OVERRIDE= bash "$UTILS" resolve-companion 2>/dev/null)"
if [ -z "$COMPANION" ]; then
  printf '  skipped: companion not installed — live --help contract not checked\n'
else
  HELP="$(node "$COMPANION" --help 2>&1)"
  for flag in "--json" "--resume-last" "--background" "status" "result"; do
    t "companion --help still advertises $flag"
    assert_contains "$HELP" "$flag"
  done

  # --prompt-file is FUNCTIONAL but UNDOCUMENTED: it is parsed by the companion
  # yet absent from printUsage(). Verified against 1.0.3 and used by every
  # ultrablitz turn. Asserting on --help would fail forever, so assert on the
  # option definition in the source — that is the contract we actually depend on.
  t "companion still parses --prompt-file (undocumented in --help)"
  if grep -q '"prompt-file"' "$COMPANION"; then _ok; else
    _no "the companion no longer defines the prompt-file option — codex-turn must switch to positional prompts"
  fi
fi

finish
