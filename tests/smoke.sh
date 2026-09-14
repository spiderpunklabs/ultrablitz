#!/usr/bin/env bash
# tests/smoke.sh — real-companion smoke test. OPT-IN: `make smoke`.
#
# This talks to the REAL Codex companion and therefore spends real API/plan
# usage. It is deliberately not part of `make test` or CI; a human runs it
# before a release (`make release-check`) and it records the result in
# tests/fixtures/companion/last-smoke.json, which `make tag` requires.
set -u

UB_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
UTILS="$UB_ROOT/hooks/ultrablitz-utils.sh"
LAST_SMOKE="$UB_ROOT/tests/fixtures/companion/last-smoke.json"

fail() {
  printf 'smoke: FAIL — %s\n' "$1" >&2
  exit 1
}

# Never let a test stub satisfy the smoke test.
export ULTRABLITZ_TEST=0
export ULTRABLITZ_COMPANION_OVERRIDE=

COMPANION="$(bash "$UTILS" resolve-companion 2>/dev/null)"
if [ -z "$COMPANION" ]; then
  printf 'skipped: codex companion not installed\n'
  exit 0
fi

printf 'smoke: about to run ONE real Codex turn (live paid API).\n'
printf 'smoke: companion: %s\n' "$COMPANION"
printf 'smoke: the turn sends a one-line prompt and expects the reply "OK".\n'

# 1. doctor must pass before we spend a turn.
#
# Scope: every RUNTIME check must pass. `registration` is deliberately excluded
# — it reports whether the gate hook is wired into ~/.claude/settings.json,
# which matters for an installed skill but not for the thing this test proves
# (that the companion contract still holds). A maintainer running `make smoke`
# from a clone has usually not installed the skill, and requiring them to
# modify their live settings just to validate a contract would be wrong.
printf 'smoke: [1/4] doctor --json ...\n'
DOC="$(bash "$UTILS" doctor --json 2>/dev/null)"
[ -n "$DOC" ] || fail "doctor produced no output"
RUNTIME_FAILS="$(printf '%s' "$DOC" |
  jq -r '.checks[] | select(.status=="fail") | select(.name!="registration") | "  - \(.name): \(.detail)"' 2>/dev/null)"
[ -z "$RUNTIME_FAILS" ] || fail "doctor reports runtime failures; fix these first:
$RUNTIME_FAILS"
REG="$(printf '%s' "$DOC" | jq -r '.checks[] | select(.name=="registration") | .status' 2>/dev/null)"
[ "$REG" = "ok" ] || printf 'smoke: WARNING — gate hook %s (not required for this test; run `bash install.sh --register` for a full install)\n' "$REG"
printf 'smoke: doctor runtime checks ok\n'

# 2. fresh session + trivial prompt + model resolution (plan E1: newest-first
#    preference list unless the operator names one).
printf 'smoke: [2/4] creating session ...\n'
SD="$(bash "$UTILS" session-new)" || fail "session-new failed"
trap 'rm -rf "$SD"' EXIT
printf 'Reply with the single word OK and nothing else.\n' > "$SD/prompt.md"
RM_OUT="$(bash "$UTILS" resolve-model --session "$SD" ${ULTRABLITZ_SMOKE_MODEL:+--model "$ULTRABLITZ_SMOKE_MODEL"})" \
  || fail "resolve-model failed"
printf 'smoke: model %s (origin %s)\n' \
  "$(printf '%s' "$RM_OUT" | jq -r '.model // "companion default"')" \
  "$(printf '%s' "$RM_OUT" | jq -r '.origin')"

# 3. one real turn, 5-minute ceiling. No --contract: the reply is a bare OK,
#    we assert on it directly below.
# The turn takes its model from the session (resolve-model above). A refusal
# of a preference-list model downgrades automatically inside codex-turn; a
# refusal of an ULTRABLITZ_SMOKE_MODEL (explicit) stops the run — per
# INV-MODEL-1.
printf 'smoke: [3/4] running one Codex turn (timeout 300000ms) ...\n'
OUT="$(bash "$UTILS" codex-turn --session "$SD" --prompt-file "$SD/prompt.md" \
  --timeout-ms 300000 --label smoke 2>/dev/null)"
[ "$(printf '%s' "$OUT" | jq -r '.ok' 2>/dev/null)" = "true" ] \
  || fail "codex-turn not ok: $(printf '%s' "$OUT" | jq -r '"[\(.failureClass // "?")] \(.message // "no message")"' 2>/dev/null)"

OF="$(printf '%s' "$OUT" | jq -r '.outputFile')"
[ -r "$OF" ] || fail "output file missing: $OF"
REPLY="$(tr -d '[:space:]' < "$OF" | tr '[:lower:]' '[:upper:]')"
[ "$REPLY" = "OK" ] || fail "expected OK, got: $(head -c 200 "$OF")"
printf 'smoke: Codex replied OK (thread %s)\n' "$(printf '%s' "$OUT" | jq -r '.threadId')"

# 4. record the pass for `make tag`.
printf 'smoke: [4/4] recording %s ...\n' "$LAST_SMOKE"
CODEX_VERSION="$(codex --version 2>/dev/null | head -1)"
[ -n "$CODEX_VERSION" ] || CODEX_VERSION="unknown"
PLUGIN_MANIFEST="$(dirname "$(dirname "$COMPANION")")/.claude-plugin/plugin.json"
PLUGIN_VERSION="unknown"
if [ -r "$PLUGIN_MANIFEST" ]; then
  PLUGIN_VERSION="$(jq -r '.version // "unknown"' "$PLUGIN_MANIFEST" 2>/dev/null)"
fi
SMOKE_MODEL="$(printf '%s' "$OUT" | jq -r '.model // "companion default"')"
jq -n \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg cv "$CODEX_VERSION" \
  --arg pv "$PLUGIN_VERSION" \
  --arg m "$SMOKE_MODEL" \
  '{date:$date, codexVersion:$cv, pluginVersion:$pv, model:$m, schemaDiff:[]}' > "$LAST_SMOKE" \
  || fail "could not write $LAST_SMOKE"

printf 'smoke: PASS — codex %s, plugin %s\n' "$CODEX_VERSION" "$PLUGIN_VERSION"
exit 0
