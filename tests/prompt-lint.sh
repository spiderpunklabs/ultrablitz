#!/usr/bin/env bash
# tests/prompt-lint.sh — static + rendered checks on the prompt templates.
#
# A typo'd placeholder must never ship: every {UPPER_SNAKE} token in
# references/prompts/*.md has to appear in KNOWN_SLOTS below. format-repair.md
# is additionally pinned to exactly its three slots (INV-FORMAT-1), its
# rendered form must be free of unsubstituted slots, debate-protocol tags and
# critique vocabulary, and every template must stay inside the size budget
# (INV-BUDGET-1).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# The one and only table of legal placeholder slots. Add here deliberately.
KNOWN_SLOTS="EXPECTED_HEADERS CATEGORY_LIST OFFENDING_OUTPUT PLAN_TEXT PLAN_SUMMARY FRAMEWORK_PROPOSAL FRAMEWORK_CONTRACT DEBATE_PROTOCOL ATTACK_SURFACE OUTPUT_CONTRACT CATEGORIES ROUND_CONTEXT INCLUDE_DIG_DEEPER INCLUDE_REBUTTAL_RULES"

# Slots are UPPER_SNAKE tokens in braces. Mixed-case braces ({Category}) are
# prose examples inside templates, not interpolation slots.
SLOT_RE='\{[A-Z][A-Z_]*\}'

PROMPTS_DIR="$UB_ROOT/references/prompts"
SANDBOX="$(new_sandbox)"
trap 'rm -rf "$SANDBOX"' EXIT

slot_known() {
  local s k
  s="$1"
  for k in $KNOWN_SLOTS; do
    [ "$s" = "$k" ] && return 0
  done
  return 1
}

# --- (a) no unknown slots anywhere --------------------------------------------
for f in "$PROMPTS_DIR"/*.md; do
  t "no unknown slots in ${f##*/}"
  unknown=""
  for s in $(grep -oE "$SLOT_RE" "$f" | tr -d '{}' | sort -u); do
    slot_known "$s" || unknown="$unknown $s"
  done
  if [ -z "$unknown" ]; then _ok; else _no "unknown slot(s):$unknown — add to KNOWN_SLOTS deliberately or fix the typo"; fi
done

# --- (b) format-repair.md carries exactly its three slots (INV-FORMAT-1) ------
REPAIR="$PROMPTS_DIR/format-repair.md"
t "format-repair.md exists"
[ -f "$REPAIR" ] && _ok || _no "missing $REPAIR"

t "format-repair.md has exactly EXPECTED_HEADERS, CATEGORY_LIST, OFFENDING_OUTPUT (INV-FORMAT-1)"
got="$(grep -oE "$SLOT_RE" "$REPAIR" | tr -d '{}' | sort -u | tr '\n' ' ')"
assert_eq "$got" "CATEGORY_LIST EXPECTED_HEADERS OFFENDING_OUTPUT "

# --- (c) rendered repair prompt is fully substituted and protocol-free --------
# The offending fixture deliberately contains NO critique vocabulary, so any
# such token in the rendered output must have come from the template itself.
OFFENDING="$SANDBOX/offending.md"
cat > "$OFFENDING" <<'EOF'
Here are my thoughts on the plan, in free prose instead of the required shape.

The plan is decent overall. Scoring: maybe 70 out of 96? The strongest part is
the gate design; the weakest is documentation drift. I did not use the section
headers you asked for, sorry about that.
EOF

t "render-repair renders against the fixture contract"
RENDERED="$(bash "$UTILS" render-repair \
  --template "$REPAIR" \
  --contract "$UB_ROOT/tests/fixtures/framework.json" \
  --offending "$OFFENDING" 2>&1)"
rc=$?
assert_rc "$rc" 0

t "rendered repair prompt has no unsubstituted {SLOT} tokens"
leftover="$(printf '%s\n' "$RENDERED" | grep -oE "$SLOT_RE" | sort -u | tr '\n' ' ')"
assert_eq "$leftover" ""

t "rendered repair prompt carries no debate-protocol XML tags (INV-FORMAT-1)"
tags="$(printf '%s\n' "$RENDERED" | grep -oE '</?[a-z_]+>' | sort -u | tr '\n' ' ')"
assert_eq "$tags" ""

t "rendered repair prompt quotes the offending output"
assert_contains "$RENDERED" "in free prose instead of the required shape"

t "rendered repair prompt lists the contract categories with bounds"
assert_contains "$RENDERED" "- Gate & safety integrity: {0-20}"

# --- (d) no critique vocabulary outside the quoted offending region -----------
# The offending fixture above contains none of these tokens, so after removing
# the template's own shape-specification lines (the literal "- Evidence: ..."
# sub-field spec, which names the fields without carrying critique content),
# none of them may appear anywhere in the rendered prompt.
STRIPPED="$(printf '%s\n' "$RENDERED" | grep -vE '^[[:space:]]*-[[:space:]]*(Category|Evidence|Impact|Suggestion):[[:space:]]*\.\.\.[[:space:]]*$')"
for tok in "Evidence:" "Impact:" "Suggestion:" "[CRITICAL]" "[MAJOR]" "[MINOR]"; do
  t "rendered repair prompt carries no critique vocabulary: $tok"
  assert_not_contains "$STRIPPED" "$tok"
done

# --- (e) Phase 1 contract is single-sourced (B2) --------------------------------
# The one Phase 1 template interpolates the one contract block defined in
# references/output-contract.md, so round 1 and rounds 2+ demand the same shape.
CONTRACT_DOC="$UB_ROOT/references/output-contract.md"
CONTRACT_MARKER='Phase 1 contract — interpolated as {FRAMEWORK_CONTRACT}'

t "framework-prompt.md carries the {FRAMEWORK_CONTRACT} slot"
if grep -q -F '{FRAMEWORK_CONTRACT}' "$PROMPTS_DIR/framework-prompt.md"; then
  _ok
else
  _no "missing {FRAMEWORK_CONTRACT} slot inside <structured_output_contract>"
fi

t "framework-prompt.md does not inline a second copy of the Phase 1 contract"
if grep -q -F '## FRAMEWORK VERDICT' "$PROMPTS_DIR/framework-prompt.md"; then
  _no "contract body duplicated in the template — it must come only from output-contract.md"
else
  _ok
fi

# Exactly the two Phase 2 prompt templates: one parametric scoring prompt and
# the format-repair template. Old per-round files must not come back.
for f in initial-scoring.md rebuttal-scoring.md framework-proposal.md framework-rebuttal.md; do
  t "superseded template $f is absent"
  [ -e "$PROMPTS_DIR/$f" ] && _no "superseded per-round template present" || _ok
done
t "scoring-prompt.md carries the OUTPUT_CONTRACT slot"
grep -q -F '{OUTPUT_CONTRACT}' "$PROMPTS_DIR/scoring-prompt.md" && _ok || _no "missing {OUTPUT_CONTRACT}"

# --- (e2) attack surface is domain-specific, not generic (INV-SURFACE-1) -------
t "scoring-prompt.md carries the ATTACK_SURFACE slot (INV-SURFACE-1)"
grep -q -F '{ATTACK_SURFACE}' "$PROMPTS_DIR/scoring-prompt.md" && _ok || _no "missing {ATTACK_SURFACE}"
t "debate-protocol.md no longer carries the generic <attack_surface> block"
grep -q -F '<attack_surface>' "$UB_ROOT/references/debate-protocol.md" && _no "generic block still present; the surface comes from framework.json" || _ok
t "the Phase 1 contract negotiates the attack surface"
grep -q -F '## ATTACK SURFACE:' "$CONTRACT_DOC" && _ok || _no "Phase 1 contract has no ATTACK SURFACE section"

# --- (e3) Phase 2 contract is rendered, not hand-typed (INV-A9) ---------------
for m in 'Phase 2 contract — base template' 'Phase 2 — round 1 fragment' 'Phase 2 — rounds 2+ fragment'; do
  t "output-contract.md carries the marker '$m' exactly once"
  n="$(grep -c -F "$m" "$CONTRACT_DOC")" || true
  assert_eq "$n" "1"
done
FIX="$UB_ROOT/tests/fixtures/framework.json"
for r in 1 2; do
  t "render-contract --round $r renders with no unsubstituted {SLOT} tokens"
  R="$(bash "$UTILS" render-contract --contract "$FIX" --round "$r" 2>&1)"; rc=$?
  left="$(printf '%s\n' "$R" | grep -oE "$SLOT_RE" | sort -u | tr '\n' ' ')"
  [ "$rc" = 0 ] && [ -z "$left" ] && _ok || _no "rc=$rc leftover=$left"
done
t "rendered round-1 contract carries the sweep and every class (INV-SWEEP-1)"
R1="$(bash "$UTILS" render-contract --contract "$FIX" --round 1)"
miss=""
for c in empty-or-none scale concurrency partial-failure-and-rollback permissions-and-identity time-and-ordering external-dependency-down human-misuse migration-and-compat; do
  printf '%s\n' "$R1" | grep -q -E "^- $c: COVERED" || miss="$miss $c"
done
printf '%s\n' "$R1" | grep -q -F '## EDGE CASE SWEEP' && [ -z "$miss" ] && _ok || _no "missing:$miss"
t "rendered round-1 contract carries no admissibility rules"
assert_not_contains "$R1" "Triggered-by"
t "rendered round-2 contract carries the admissibility rules and no sweep (INV-ADMIT-1)"
R2="$(bash "$UTILS" render-contract --contract "$FIX" --round 2)"
printf '%s\n' "$R2" | grep -q -F 'Triggered-by' && ! printf '%s\n' "$R2" | grep -q -F '## EDGE CASE SWEEP' && _ok || _no "round 2 contract wrong"
t "rendered contract lists the framework categories with bounds"
assert_contains "$R2" "- Gate & safety integrity: {0-20}"
t "rendered contract demands UB-n ids and a Category line (INV-ID-1)"
printf '%s\n' "$R2" | grep -q -F 'UB-{n} **[CRITICAL|MAJOR|MINOR]**' && printf '%s\n' "$R2" | grep -q -F -e '- Category:' && _ok || _no "id/category spec missing"
t "render-contract --part surface prints the locked attack surface (INV-SURFACE-1)"
S="$(bash "$UTILS" render-contract --contract "$FIX" --part surface)"
assert_eq "$(printf '%s\n' "$S" | grep -c '^- ')" "3"
t "render-contract --part surface falls back to the generic line without attackSurface"
jq 'del(.attackSurface)' "$FIX" > "$SANDBOX/generic.json"
S="$(bash "$UTILS" render-contract --contract "$SANDBOX/generic.json" --part surface)"
assert_contains "$S" "generic attack surface"
t "render-contract refuses a missing round"
bash "$UTILS" render-contract --contract "$FIX" >/dev/null 2>&1; rc=$?
assert_rc "$rc" 2

t "output-contract.md carries the Phase 1 contract marker exactly once"
marker_count="$(grep -c -F "$CONTRACT_MARKER" "$CONTRACT_DOC")" || true
assert_eq "$marker_count" "1"

t "the Phase 1 contract section holds exactly one fenced block"
# Count fence lines between the marker heading and the next '## ' heading:
# exactly one fenced block means exactly two fence lines.
fence_lines="$(awk -v marker="$CONTRACT_MARKER" '
  index($0, marker)            { insec = 1; next }
  insec && /^```/              { n++; infence = !infence; next }
  insec && !infence && /^## /  { insec = 0 }
  END { print n + 0 }
' "$CONTRACT_DOC")"
assert_eq "$fence_lines" "2"

# --- (f) size budget (INV-BUDGET-1) --------------------------------------------
for f in "$PROMPTS_DIR"/*.md; do
  t "${f##*/} is under 30000 bytes (INV-BUDGET-1)"
  bytes="$(wc -c < "$f" | tr -d '[:space:]')"
  if [ "$bytes" -lt 30000 ]; then _ok; else _no "$bytes bytes >= 30000"; fi
done

finish
