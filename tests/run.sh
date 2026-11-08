#!/usr/bin/env bash
# tests/run.sh — suite runner (plan D). Plain bash; bats is not required.
#
# Discovers every tests/test-*.sh, then appends the named lint/contract files
# when present (doc-lint.sh may be authored later; missing files are skipped
# with a note, never an error). Each test file exits with its failure count
# (tests/lib.sh `finish`), so any non-zero exit marks the file failed.
#
# Usage:
#   bash tests/run.sh        # summary output (full output only for failures)
#   bash tests/run.sh -v     # verbose: stream every test file's full output
set -u

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

# Work from any cwd: everything is addressed from the repo root.
TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"

# Named extras, run after the unit/e2e files. Skipped gracefully when absent.
EXTRAS="prompt-lint.sh contract.bats.sh doc-lint.sh"

total_files=0
failed_files=0
summary=""

run_file() {
  # run_file <path>  — appends to summary, bumps counters.
  local f="$1" rc out name
  name="${f##*/}"
  total_files=$((total_files + 1))
  out="$(bash "$f" 2>&1)"
  rc=$?
  if [ "$VERBOSE" = "1" ]; then
    printf '=== %s\n%s\n' "$name" "$out"
  elif [ "$rc" -ne 0 ]; then
    # Show the whole file's output so the failure is diagnosable from CI logs.
    printf '=== %s\n%s\n' "$name" "$out"
  else
    # Quiet mode: just the per-file tally line that lib.sh's finish() prints.
    printf '=== %s\n%s\n' "$name" "$(printf '%s\n' "$out" | grep -- '---' | tail -1)"
  fi
  if [ "$rc" -eq 0 ]; then
    summary="$summary
  PASS $name"
  else
    failed_files=$((failed_files + 1))
    summary="$summary
  FAIL $name (exit $rc)"
  fi
}

# The glob is safe under `set -u` on bash 3.2: at least one test-*.sh exists,
# and the [ -f ] guard covers a literal-glob miss anyway.
for f in "$TESTS_DIR"/test-*.sh; do
  [ -f "$f" ] || continue
  run_file "$f"
done

for name in $EXTRAS; do
  f="$TESTS_DIR/$name"
  if [ -f "$f" ]; then
    run_file "$f"
  else
    printf '=== %s\n  skipped (not present)\n' "$name"
    summary="$summary
  SKIP $name (not present)"
  fi
done

printf '\n==== suite summary ====%s\n' "$summary"
printf '==== total: %d file(s), %d failed\n' "$total_files" "$failed_files"
[ "$failed_files" -eq 0 ] || exit 1
exit 0
