#!/usr/bin/env bash
# Documentation drift linter (plan B4b). Plain bash 3.2, no bats.
#
# Checks:
#   1. every INV-* id cited in SKILL.md or the references is DEFINED in
#      references/protocol-invariants.md (a definition is a "### INV-..." line)
#   2. every defined invariant is cited at least once outside the invariants
#      file — WARNING only, not a failure (SKILL.md is rewritten concurrently)
#   3. no forbidden phrase (text from superseded rules) appears in the docs
#   4. all 16 required invariant ids are defined
#
# Exit status is the failure count (via finish).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

INV_FILE="$UB_ROOT/references/protocol-invariants.md"
SKILL_FILE="$UB_ROOT/SKILL.md"

# The token shape of an invariant id: INV-A9, INV-SCORE-1, INV-TERM-2, ...
ID_RE='INV-[A-Z0-9]+(-[0-9]+)?'

t "protocol-invariants.md exists"
if [ -f "$INV_FILE" ]; then
  _ok
else
  _no "missing: $INV_FILE"
  finish
fi

# --- gather the doc set (paths in this repo contain no whitespace) -----------
DOCS=""        # every scanned doc, invariants file included
OTHER_DOCS=""  # every scanned doc EXCEPT the invariants file
for f in "$SKILL_FILE" "$UB_ROOT"/references/*.md "$UB_ROOT"/references/prompts/*.md; do
  [ -f "$f" ] || continue
  DOCS="$DOCS $f"
  [ "$f" = "$INV_FILE" ] || OTHER_DOCS="$OTHER_DOCS $f"
done

# Defined ids: first INV token on each "### INV-..." heading line.
defined="$(sed -n 's/^### \(INV-[A-Z0-9-]*[A-Z0-9]\).*/\1/p' "$INV_FILE" | sort -u)"
defined_sp=" $(printf '%s' "$defined" | tr '\n' ' ') "

# Cited ids: every INV token anywhere in the doc set (empty when none cite yet).
cited="$(cat $DOCS 2>/dev/null | grep -E -o "$ID_RE" | sort -u)"
cited_other="$(cat $OTHER_DOCS 2>/dev/null | grep -E -o "$ID_RE" | sort -u)"
cited_other_sp=" $(printf '%s' "$cited_other" | tr '\n' ' ') "

# --- check 1: every citation resolves to a definition ------------------------
if [ -n "$cited" ]; then
  for id in $cited; do
    t "check 1: cited $id is defined in protocol-invariants.md"
    case "$defined_sp" in
      *" $id "*) _ok ;;
      *) _no "cited in the docs but has no '### $id' definition" ;;
    esac
  done
else
  t "check 1: no INV citations found in the docs (nothing to resolve)"
  _ok
fi

# --- check 2: dead invariants (warning only, never a failure) ----------------
t "check 2: dead-invariant scan (warnings only)"
warns=0
for id in $defined; do
  case "$cited_other_sp" in
    *" $id "*) : ;;
    *)
      printf '  warn %s is defined but never cited outside protocol-invariants.md\n' "$id"
      warns=$((warns + 1))
      ;;
  esac
done
_ok
[ "$warns" -gt 0 ] && printf '  note %d dead-invariant warning(s) — drift, but not failed (SKILL.md rewrite in flight)\n' "$warns"

# --- check 3: forbidden phrases from superseded rules -------------------------
for f in $DOCS; do
  t "check 3: no forbidden phrase in ${f#"$UB_ROOT"/}"
  hits=""
  grep -q -F 'CRITICAL/MAJOR' "$f" && hits="$hits CRITICAL/MAJOR"
  grep -q -F 'codex_companion_path' "$f" && hits="$hits codex_companion_path"
  if [ -z "$hits" ]; then
    _ok
  else
    _no "forbidden phrase(s):$hits"
  fi
done

# --- check 4: the full required invariant set is defined ----------------------
REQUIRED="INV-SCORE-1 INV-SCORE-2 INV-CAP-1 INV-CAP-2 INV-LEDGER-1 INV-LEDGER-2 \
INV-TERM-1 INV-TERM-2 INV-TERM-3 INV-CONT-1 INV-CONT-2 INV-FORMAT-1 INV-FAIL-1 \
INV-ROUND-1 INV-A9 INV-BUDGET-1"
for id in $REQUIRED; do
  t "check 4: required invariant $id is defined"
  case "$defined_sp" in
    *" $id "*) _ok ;;
    *) _no "protocol-invariants.md is missing a '### $id' heading" ;;
  esac
done

finish
