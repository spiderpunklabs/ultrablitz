#!/usr/bin/env bash
# Tests for validate-output: the contract enforcement that used to live in prose.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

SANDBOX="$(new_sandbox)"
trap 'rm -rf "$SANDBOX"' EXIT
C="$UB_ROOT/tests/fixtures/framework.json"

mk() { printf '%s\n' "$1" > "$SANDBOX/out.md"; }
v() { bash "$UTILS" validate-output --contract "$C" --input "$SANDBOX/out.md" "$@"; }

# Responses are assembled from parts in plain bash (BSD sed cannot insert
# multi-line text portably).
scores='## CATEGORY SCORES:
- Runtime contract fidelity & execution robustness: 24
- Gate & safety integrity: 18
- Verifiability & regression resistance: 19
- Protocol coherence & drift resistance: 15
- Operability & maintenance economics: 18
'
crit1='UB-1 **[MAJOR]** Something
   - Category: Gate & safety integrity
   - Evidence: e
   - Impact: i
   - Suggestion: s
'
crit2='UB-2 **[MINOR]** Second
   - Category: Operability & maintenance economics
   - Evidence: e
   - Impact: i
   - Suggestion: s
'
sweep_txt='## EDGE CASE SWEEP:
- empty-or-none: COVERED — section 2
- scale: COVERED — section 4
- concurrency: UNCOVERED — see UB-1
- partial-failure-and-rollback: COVERED — section 5
- permissions-and-identity: N-A — single-user CLI
- time-and-ordering: COVERED — section 3
- external-dependency-down: COVERED — section 6
- human-misuse: COVERED — section 7
- migration-and-compat: N-A — greenfield
'
tail_txt='## STRENGTHS:
- One.

## VERDICT:
Ship it.'

# compose [--sweep TEXT] [--crit1 TEXT] [--crit2 TEXT] [--notes TEXT]
compose() {
  local sweep="" c1="$crit1" c2="" notes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sweep) sweep="$2"; shift 2 ;;
      --crit1) c1="$2"; shift 2 ;;
      --crit2) c2="$2"; shift 2 ;;
      --notes) notes="$2"; shift 2 ;;
      *) echo "compose: bad arg $1" >&2; return 2 ;;
    esac
  done
  printf '%s\n%s## CRITIQUES:\n%s%s\n%s%s' "$scores" "$sweep" "$c1" "$c2" "$notes" "$tail_txt"
}

good="$(compose)"

t "valid output passes"
mk "$good"
out="$(v)"; rc=$?
assert_rc "$rc" 0
t "valid output reports ok:true"
assert_json "$out" '.ok' 'true'
t "total is the sum of category scores"
assert_json "$out" '.total' '94'
t "critique count is parsed"
assert_json "$out" '.critiqueCount' '1'
t "critique id, severity and category are reported (INV-ID-1)"
assert_json "$out" '.critiques[0] | "\(.id) \(.severity) \(.category)"' 'UB-1 MAJOR Gate & safety integrity'
t "lastId is the highest id seen"
assert_json "$out" '.lastId' '1'

t "missing section header fails"
# NB: ${var/## X/y} would anchor on '#', so build this with sed.
mk "$(printf '%s\n' "$good" | sed 's/^## VERDICT:$/## FINAL WORD:/')"
out="$(v)"; rc=$?
assert_rc "$rc" 1
t "missing header is named in errors"
assert_contains "$out" "missing section header: ## VERDICT"

t "out-of-bounds score fails"
mk "${good/: 24/: 99}"
out="$(v)"; rc=$?
assert_rc "$rc" 1
t "out-of-bounds error names the category"
assert_contains "$out" "out of bounds"

t "unexpected category fails"
mk "$(printf '%s\n' "$good" | sed 's/^- Gate & safety integrity: 18$/- Vibes: 18/')"
out="$(v)"; rc=$?
assert_rc "$rc" 1
t "both the missing and the extra category are reported"
assert_contains "$out" "missing categories: Gate & safety integrity"

t "critique missing Suggestion fails"
mk "${good/   - Suggestion: s/}"
out="$(v)"; rc=$?
assert_rc "$rc" 1
t "missing sub-field is counted"
assert_contains "$out" "Suggestion fields"

t "empty output fails"
: > "$SANDBOX/out.md"
out="$(v)"; rc=$?
assert_rc "$rc" 1

t "zero-critique response is valid (consensus round)"
mk "$(compose --crit1 '- None.
')"
out="$(v)"; rc=$?
assert_rc "$rc" 0

# --- INV-ID-1: stable ids, Category line -------------------------------------
t "a numbered critique without a UB id fails (INV-ID-1)"
mk "${good/UB-1 \*\*\[MAJOR\]\*\*/1. **[MAJOR]**}"
out="$(v)"; rc=$?
assert_rc "$rc" 1
t "the missing id is named"
assert_contains "$out" "without a UB-n id"

t "a critique without a Category line fails (INV-ID-1)"
mk "${good/   - Category: Gate & safety integrity/}"
out="$(v)"; rc=$?
assert_rc "$rc" 1
t "the missing Category is named"
assert_contains "$out" "without a Category line"

t "a Category outside the locked framework fails"
mk "${good/   - Category: Gate & safety integrity/   - Category: Vibes}"
out="$(v)"; rc=$?
assert_rc "$rc" 1
t "the foreign category is named with its id"
assert_contains "$out" "UB-1=Vibes"

t "Category matching is case- and space-insensitive"
mk "${good/   - Category: Gate & safety integrity/   - Category:  gate & SAFETY integrity }"
v >/dev/null; rc=$?
assert_rc "$rc" 0

t "a leading list number and bold around the id are tolerated"
mk "${good/UB-1 \*\*\[MAJOR\]\*\*/1. **UB-1** **[MAJOR]**}"
out="$(v)"; rc=$?
assert_rc "$rc" 0

t "duplicate ids fail"
mk "$(compose --crit2 "${crit2//UB-2/UB-1}")"
out="$(v)"; rc=$?
assert_rc "$rc" 1
t "the duplicate id is named"
assert_contains "$out" "duplicate critique ids: UB-1"

t "new ids must continue the sequence (gap fails)"
mk "$(compose --crit2 "${crit2//UB-2/UB-3}")"
out="$(v)"; rc=$?
assert_rc "$rc" 1
t "the sequence error names the expected id"
assert_contains "$out" "continue from UB-1"

t "an id at or below --last-id is an existing finding, not a new one"
mk "$good"
out="$(v --round 2 --last-id 1)"; rc=$?
assert_rc "$rc" 0
t "existing findings produce no newIds"
assert_json "$out" '.newIds | length' '0'

t "--round and --last-id must be integers"
mk "$good"
v --round one >/dev/null 2>&1; rc=$?
assert_rc "$rc" 2

# --- INV-SWEEP-1: round-1 edge case sweep ------------------------------------
with_sweep="$(compose --sweep "$sweep_txt")"

t "round 1 without an EDGE CASE SWEEP fails (INV-SWEEP-1)"
mk "$good"
out="$(v --round 1)"; rc=$?
assert_rc "$rc" 1
t "the missing sweep is named"
assert_contains "$out" "## EDGE CASE SWEEP"
t "the same output passes without --round (rounds 2+ carry no sweep)"
v >/dev/null; rc=$?
assert_rc "$rc" 0

t "round 1 with a complete sweep passes"
mk "$with_sweep"
out="$(v --round 1)"; rc=$?
assert_rc "$rc" 0
t "sweep statuses are reported"
assert_json "$out" '.sweep.uncovered | join(",")' 'concurrency'
t "N-A classes are reported"
assert_json "$out" '.sweep.notApplicable | length' '2'
t "sweep is null when not round 1"
out="$(v --round 2)"
assert_json "$out" '.sweep' 'null'

t "a sweep missing a class fails"
mk "$(compose --sweep "$(printf '%s\n' "$sweep_txt" | grep -v -e '^- scale:')")"
out="$(v --round 1)"; rc=$?
assert_rc "$rc" 1
t "the missing class is named"
assert_contains "$out" "missing classes: scale"

t "a sweep with an unknown class fails"
mk "$(compose --sweep "${sweep_txt/- scale:/- vibes:}")"
out="$(v --round 1)"; rc=$?
assert_rc "$rc" 1
t "the unknown class is named"
assert_contains "$out" "unknown classes: vibes"

t "an UNCOVERED row that names no critique fails"
mk "$(compose --sweep "${sweep_txt/UNCOVERED — see UB-1/UNCOVERED}")"
out="$(v --round 1)"; rc=$?
assert_rc "$rc" 1
t "the unreferenced row is named"
assert_contains "$out" "must name their critique (UB-n): concurrency"

# --- INV-ADMIT-1: admissibility of new findings on rounds 2+ -----------------
add_new() {
  # add_new <extra-line-or-empty> <severity>  → output with UB-2 appended
  local extra="$1" sev="${2:-MAJOR}" entry
  entry="UB-2 **[$sev]** Second
   - Category: Operability & maintenance economics
"
  [ -n "$extra" ] && entry="$entry   - $extra
"
  entry="$entry   - Evidence: e
   - Impact: i
   - Suggestion: s
"
  mk "$(compose --crit2 "$entry")"
}

t "round 2: a new finding with Triggered-by is admitted"
add_new "Triggered-by: UB-1" MAJOR
out="$(v --round 2 --last-id 1)"; rc=$?
assert_rc "$rc" 0
t "admitted id is reported"
assert_json "$out" '.admissibility.admitted | join(",")' 'UB-2'
t "newIds lists it"
assert_json "$out" '.newIds | join(",")' 'UB-2'

t "round 2: a new finding with neither line is noted, not failed"
add_new "" MAJOR
out="$(v --round 2 --last-id 1)"; rc=$?
assert_rc "$rc" 0
t "the noted id and reason are reported"
assert_json "$out" '.admissibility.noted[0].id' 'UB-2'
t "nothing is admitted"
assert_json "$out" '.admissibility.admitted | length' '0'

t "round 2: MAJOR with Missed-because is admitted"
add_new "Missed-because: the section was added in the rebuttal" MAJOR
out="$(v --round 2 --last-id 1)"
assert_json "$out" '.admissibility.admitted | join(",")' 'UB-2'
t "round 2: MINOR with Missed-because only is noted"
add_new "Missed-because: whatever" MINOR
out="$(v --round 2 --last-id 1)"
assert_json "$out" '.admissibility.noted[0].id' 'UB-2'
t "round 2: MINOR with Triggered-by is admitted"
add_new "Triggered-by: UB-1" MINOR
out="$(v --round 2 --last-id 1)"
assert_json "$out" '.admissibility.admitted | join(",")' 'UB-2'

t "round 1 admits everything (no admissibility bar)"
mk "$with_sweep"
out="$(v --round 1)"
assert_json "$out" '.admissibility.admitted | join(",")' 'UB-1'

t "confirm-only: a MAJOR new finding is noted even with Triggered-by (INV-TERM-4)"
add_new "Triggered-by: UB-1" MAJOR
out="$(v --round 4 --last-id 1 --confirm-only)"; rc=$?
assert_rc "$rc" 0
t "confirm-only: the noted id is reported"
assert_json "$out" '.admissibility.noted[0].id' 'UB-2'
t "confirm-only: a CRITICAL new finding with Triggered-by is admitted"
add_new "Triggered-by: UB-1" CRITICAL
out="$(v --round 4 --last-id 1 --confirm-only)"
assert_json "$out" '.admissibility.admitted | join(",")' 'UB-2'
t "confirm-only: a CRITICAL new finding with neither line is noted"
add_new "" CRITICAL
out="$(v --round 4 --last-id 1 --confirm-only)"
assert_json "$out" '.admissibility.noted[0].id' 'UB-2'

t "entries under ## NOTES are not counted as critiques"
mk "$(compose --notes '## NOTES:
- A loose observation about naming.

')"
out="$(v --round 2 --last-id 1)"; rc=$?
assert_rc "$rc" 0
t "critique count excludes notes"
assert_json "$out" '.critiqueCount' '1'

# --- INV-FORMAT-1 substance check -------------------------------------------
t "repair that preserves scores passes the baseline check"
printf '%s\n' "$good" > "$SANDBOX/base.md"
printf '%s\n' "$good" > "$SANDBOX/out.md"
out="$(v --baseline "$SANDBOX/base.md")"; rc=$?
assert_rc "$rc" 0

t "repair that silently rescores is rejected (INV-FORMAT-1)"
printf '%s\n' "${good/: 24/: 20}" > "$SANDBOX/out.md"
out="$(v --baseline "$SANDBOX/base.md")"; rc=$?
assert_rc "$rc" 1
t "rescoring error is explicit"
assert_contains "$out" "repair changed scores"

t "repair that drops a critique is rejected"
# Second critique must live INSIDE the CRITIQUES section to be counted.
compose --crit2 "$crit2" > "$SANDBOX/base.md"
printf '%s\n' "$good" > "$SANDBOX/out.md"
out="$(v --baseline "$SANDBOX/base.md")"; rc=$?
assert_rc "$rc" 1
t "critique-count change is explicit"
assert_contains "$out" "repair changed critique count"

t "a legacy numbered baseline still counts toward the critique count"
printf '%s\n' "${good/UB-1 \*\*\[MAJOR\]\*\*/1. **[MAJOR]**}" > "$SANDBOX/base.md"
printf '%s\n' "$good" > "$SANDBOX/out.md"
v --baseline "$SANDBOX/base.md" >/dev/null; rc=$?
assert_rc "$rc" 0

finish
