#!/usr/bin/env bash
# check-staged.sh — canonical pre-commit check runner.
# Copied from spiderpunklabs/workstation/ci-templates/check-staged.sh at SHA 36d1f6146c3c82651f6dc2663837aaf75816f902.
# Ultrablitz CHECKS array: secret-scan + shellcheck (repo has 2 .sh files).

set -uo pipefail

STAGED=$(git diff --cached --name-only --diff-filter=ACMR -z)
if [ -z "$STAGED" ]; then
  exit 0
fi

filter_ext() {
  local list=$1; shift
  local exts=("$@")
  local pattern
  pattern=$(printf '|%s$' "${exts[@]}")
  pattern=${pattern:1}
  printf '%s' "$list" | tr '\0' '\n' | grep -Ei "$pattern" || true
}

check_secrets() {
  local FORBIDDEN_PATTERNS=(
    '\.env$' '\.env\.' '\.pem$' '\.key$' '\.p12$' '\.pfx$'
    'id_rsa' 'id_ed25519' 'credentials' 'secrets' '\.tfvars$'
  )
  local fail=0 file
  while IFS= read -r -d '' file; do
    for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
      if printf '%s' "$file" | grep -qE "$pattern"; then
        printf 'pre-commit: BLOCKED filename matches forbidden pattern %s: %s\n' "$pattern" "$file" >&2
        fail=1
      fi
    done
  done <<<"$STAGED"
  local pk="PRIV""ATE KEY"
  local gpa="github""_pat_"
  local secret_regex="(${pk}|sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|${gpa})"
  if git diff --cached -U0 | grep -qEi "$secret_regex"; then
    printf 'pre-commit: BLOCKED staged diff contains what looks like a secret/token\n' >&2
    fail=1
  fi
  return $fail
}

check_shellcheck() {
  local files; files=$(filter_ext "$STAGED" "sh")
  [ -z "$files" ] && return 0
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'pre-commit: shellcheck not installed (brew install shellcheck) — skipping staged shell scan\n' >&2
    return 0
  fi
  local fail=0 f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! shellcheck --severity=error "$f"; then fail=1; fi
  done <<<"$files"
  return $fail
}

CHECKS=(
  check_secrets
  check_shellcheck
)

overall=0
for c in "${CHECKS[@]}"; do
  if ! "$c"; then overall=1; fi
done
exit $overall
