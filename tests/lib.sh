#!/usr/bin/env bash
# tests/lib.sh — tiny assertion harness.
#
# bats-core is not assumed to be installed (installing it is the user's call),
# so the suite is plain bash. Each test file sources this, calls `t <name>`
# before each case, and uses the assert helpers. Exit status is the failure
# count, so `run.sh` can sum them.

# bash >= 5.2 expands "&" in a ${var/pat/rep} replacement to the matched text
# (patsub_replacement); macOS bash 3.2 does not. Fixtures replace text that
# contains "&" ("Gate & safety integrity"), so pin the 3.2 meaning everywhere.
shopt -u patsub_replacement 2>/dev/null || true

UB_PASS=0
UB_FAIL=0
UB_CURRENT=""

t() {
  UB_CURRENT="$1"
}

_ok() {
  UB_PASS=$((UB_PASS + 1))
  printf '  ok   %s\n' "$UB_CURRENT"
}

_no() {
  UB_FAIL=$((UB_FAIL + 1))
  printf '  FAIL %s\n' "$UB_CURRENT"
  printf '       %s\n' "$1"
}

assert_eq() {
  if [ "$1" = "$2" ]; then _ok; else _no "expected [$2] got [$1]"; fi
}

assert_ne() {
  if [ "$1" != "$2" ]; then _ok; else _no "expected value != [$2]"; fi
}

assert_contains() {
  case "$1" in
    *"$2"*) _ok ;;
    *) _no "expected to contain [$2] in: $(printf '%s' "$1" | head -c 300)" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) _no "expected NOT to contain [$2]" ;;
    *) _ok ;;
  esac
}

assert_rc() {
  # assert_rc <actual-rc> <expected-rc>
  if [ "$1" = "$2" ]; then _ok; else _no "expected exit $2 got $1"; fi
}

assert_json() {
  # assert_json <json> <jq-filter> <expected>
  local got
  got="$(printf '%s' "$1" | jq -r "$2" 2>/dev/null)"
  if [ "$got" = "$3" ]; then _ok; else _no "jq $2: expected [$3] got [$got]"; fi
}

finish() {
  printf '  --- %s: %d passed, %d failed\n' "${0##*/}" "$UB_PASS" "$UB_FAIL"
  exit "$UB_FAIL"
}

# Common paths for every test file.
UB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
UTILS="$UB_ROOT/hooks/ultrablitz-utils.sh"
GATE="$UB_ROOT/hooks/ultrablitz-gate.sh"
export UB_ROOT UTILS GATE

new_sandbox() {
  # An isolated state dir per test file, mode 700, auto-cleaned by the test file.
  local t="${TMPDIR:-/tmp}"
  t="${t%/}"
  local d
  d="$(mktemp -d "$t/ub-test-XXXXXXXX")"
  chmod 700 "$d"
  printf '%s\n' "$d"
}
