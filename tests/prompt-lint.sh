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
KNOWN_SLOTS="EXPECTED_HEADERS CATEGORY_LIST OFFENDING_OUTPUT PLAN_TEXT PLAN_SUMMARY FRAMEWORK_PROPOSAL DEBATE_PROTOCOL OUTPUT_CONTRACT CATEGORIES"

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
STRIPPED="$(printf '%s\n' "$RENDERED" | grep -vE '^[[:space:]]*-[[:space:]]*(Evidence|Impact|Suggestion):[[:space:]]*\.\.\.[[:space:]]*$')"
for tok in "Evidence:" "Impact:" "Suggestion:" "[CRITICAL]" "[MAJOR]" "[MINOR]"; do
  t "rendered repair prompt carries no critique vocabulary: $tok"
  assert_not_contains "$STRIPPED" "$tok"
done

# --- (e) size budget (INV-BUDGET-1) --------------------------------------------
for f in "$PROMPTS_DIR"/*.md; do
  t "${f##*/} is under 30000 bytes (INV-BUDGET-1)"
  bytes="$(wc -c < "$f" | tr -d '[:space:]')"
  if [ "$bytes" -lt 30000 ]; then _ok; else _no "$bytes bytes >= 30000"; fi
done

finish
