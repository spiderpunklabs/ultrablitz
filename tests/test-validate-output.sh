#!/usr/bin/env bash
# Tests for validate-output: the contract enforcement that used to live in prose.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

SANDBOX="$(new_sandbox)"
trap 'rm -rf "$SANDBOX"' EXIT
C="$UB_ROOT/tests/fixtures/framework.json"

mk() { printf '%s\n' "$1" > "$SANDBOX/out.md"; }

good='## CATEGORY SCORES:
- Runtime contract fidelity & execution robustness: 24
- Gate & safety integrity: 18
- Verifiability & regression resistance: 19
- Protocol coherence & drift resistance: 15
- Operability & maintenance economics: 18

## CRITIQUES:
1. **[MAJOR]** Something
   - Evidence: e
   - Impact: i
   - Suggestion: s

## STRENGTHS:
- One.

## VERDICT:
Ship it.'

t "valid output passes"
mk "$good"
out="$(bash "$UTILS" validate-output --contract "$C" --input "$SANDBOX/out.md")"; rc=$?
assert_rc "$rc" 0
t "valid output reports ok:true"
assert_json "$out" '.ok' 'true'
t "total is the sum of category scores"
assert_json "$out" '.total' '94'
t "critique count is parsed"
assert_json "$out" '.critiqueCount' '1'

t "missing section header fails"
# NB: ${var/## X/y} would anchor on '#', so build this with sed.
mk "$(printf '%s\n' "$good" | sed 's/^## VERDICT:$/## FINAL WORD:/')"
out="$(bash "$UTILS" validate-output --contract "$C" --input "$SANDBOX/out.md")"; rc=$?
assert_rc "$rc" 1
t "missing header is named in errors"
assert_contains "$out" "missing section header: ## VERDICT"

t "out-of-bounds score fails"
mk "${good/: 24/: 99}"
out="$(bash "$UTILS" validate-output --contract "$C" --input "$SANDBOX/out.md")"; rc=$?
assert_rc "$rc" 1
t "out-of-bounds error names the category"
assert_contains "$out" "out of bounds"

t "unexpected category fails"
mk "${good/Gate & safety integrity/Vibes}"
out="$(bash "$UTILS" validate-output --contract "$C" --input "$SANDBOX/out.md")"; rc=$?
assert_rc "$rc" 1
t "both the missing and the extra category are reported"
assert_contains "$out" "missing categories: Gate & safety integrity"

t "critique missing Suggestion fails"
mk "${good/   - Suggestion: s/}"
out="$(bash "$UTILS" validate-output --contract "$C" --input "$SANDBOX/out.md")"; rc=$?
assert_rc "$rc" 1
t "missing sub-field is counted"
assert_contains "$out" "Suggestion fields"

t "empty output fails"
: > "$SANDBOX/out.md"
out="$(bash "$UTILS" validate-output --contract "$C" --input "$SANDBOX/out.md")"; rc=$?
assert_rc "$rc" 1

t "zero-critique response is valid (consensus round)"
printf '%s\n' "$good" | sed '/^1\. /,/Suggestion: s$/d' | sed 's/^## CRITIQUES:$/## CRITIQUES:\
- None./' > "$SANDBOX/out.md"
out="$(bash "$UTILS" validate-output --contract "$C" --input "$SANDBOX/out.md")"; rc=$?
assert_rc "$rc" 0

# --- INV-FORMAT-1 substance check -------------------------------------------
t "repair that preserves scores passes the baseline check"
printf '%s\n' "$good" > "$SANDBOX/base.md"
printf '%s\n' "$good" > "$SANDBOX/out.md"
out="$(bash "$UTILS" validate-output --contract "$C" --input "$SANDBOX/out.md" --baseline "$SANDBOX/base.md")"; rc=$?
assert_rc "$rc" 0

t "repair that silently rescores is rejected (INV-FORMAT-1)"
printf '%s\n' "${good/: 24/: 20}" > "$SANDBOX/out.md"
out="$(bash "$UTILS" validate-output --contract "$C" --input "$SANDBOX/out.md" --baseline "$SANDBOX/base.md")"; rc=$?
assert_rc "$rc" 1
t "rescoring error is explicit"
assert_contains "$out" "repair changed scores"

t "repair that drops a critique is rejected"
# Second critique must live INSIDE the CRITIQUES section to be counted.
printf '%s\n' "$good" | sed 's/^## STRENGTHS:$/2. **[MINOR]** Second\
   - Evidence: e\
   - Impact: i\
   - Suggestion: s\
\
## STRENGTHS:/' > "$SANDBOX/base.md"
printf '%s\n' "$good" > "$SANDBOX/out.md"
out="$(bash "$UTILS" validate-output --contract "$C" --input "$SANDBOX/out.md" --baseline "$SANDBOX/base.md")"; rc=$?
assert_rc "$rc" 1
t "critique-count change is explicit"
assert_contains "$out" "repair changed critique count"

finish
