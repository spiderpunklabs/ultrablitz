#!/usr/bin/env bash
# Unit tests for install.sh (findings S6 and S7).
#
# ISOLATION CONTRACT: install.sh derives $SETTINGS and $SKILL_LINK from $HOME,
# so every invocation below runs with HOME pointed at a throwaway directory
# inside the sandbox. The real ~/.claude is never read, written, symlinked into
# or backed up by this file. Any new case here must keep that property — skip a
# case with a printed reason rather than reach for the real HOME.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

SANDBOX="$(new_sandbox)"
INSTALL="$UB_ROOT/install.sh"
# The installer's helpers (gate-clear) persist state; keep that in the sandbox.
export ULTRABLITZ_STATE_DIR="$SANDBOX/state"

cleanup() {
  # Drop any skill symlink first so nothing below can walk into the repo, and
  # restore modes that the permission cases deliberately removed.
  local h
  for h in "$SANDBOX"/home-*; do
    [ -L "$h/.claude/skills/ultrablitz" ] && rm -f "$h/.claude/skills/ultrablitz"
    [ -d "$h/.claude" ] && chmod u+rwx "$h/.claude" 2>/dev/null
    [ -f "$h/.claude/settings.json" ] && chmod u+rw "$h/.claude/settings.json" 2>/dev/null
  done
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

new_home() {
  # new_home <name> -> path to a fake HOME with an empty .claude dir
  local d="$SANDBOX/home-$1"
  mkdir -p "$d/.claude"
  printf '%s\n' "$d"
}

install_in() {
  # install_in <home> [args...] — sets OUT (stdout+stderr) and RC
  local h="$1"
  shift
  OUT="$(HOME="$h" bash "$INSTALL" "$@" 2>&1)"
  RC=$?
}

snippet_of() {
  # The printed snippet is the trailing block that starts at a bare "{".
  printf '%s\n' "$1" | sed -n '/^{$/,$p'
}

gate_count() {
  # gate_count <settings-file> -> how many PreToolUse commands mention the gate
  jq '[.hooks.PreToolUse[]?.hooks[]?.command? // empty
       | select(contains("ultrablitz-gate.sh"))] | length' "$1" 2>/dev/null
}

gate_entry() {
  # gate_entry <settings-file> -> the sorted, compact hook entry object
  jq -S -c '[.hooks.PreToolUse[]
             | select(((.hooks[]?.command?) // "") | contains("ultrablitz-gate.sh"))][0]' \
    "$1" 2>/dev/null
}

backup_count() {
  # backup_count <home> -> number of timestamped settings.json backups
  local n=0 b
  for b in "$1"/.claude/settings.json.bak-*; do
    [ -f "$b" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# --- prerequisite gate --------------------------------------------------------
# install.sh exits 3 before doing anything when a prerequisite is missing, so
# every case except the deliberate missing-jq one needs the real toolchain.
prereqs_ok() {
  command -v jq >/dev/null 2>&1 || return 1
  command -v node >/dev/null 2>&1 || return 1
  command -v git >/dev/null 2>&1 || return 1
  command -v codex >/dev/null 2>&1 || return 1
  local maj
  maj="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
  [ "${maj:-0}" -ge 20 ] 2>/dev/null || return 1
  return 0
}

# --- prerequisite failure (no jq on PATH) -------------------------------------
# PATH is overridden for this one call only, via env; the suite's own PATH is
# untouched. /bin/bash is spelled out because PATH cannot resolve it any more.
NOJQ_HOME="$(new_home noprereq)"
EMPTY_BIN="$SANDBOX/empty-bin"
mkdir -p "$EMPTY_BIN"
OUT="$(env HOME="$NOJQ_HOME" PATH="$EMPTY_BIN" /bin/bash "$INSTALL" 2>&1)"
RC=$?
t "missing jq exits 3"
assert_rc "$RC" 3
t "missing jq names the missing binary"
assert_contains "$OUT" "MISSING PREREQUISITE: jq"
t "missing jq suggests how to install it"
assert_contains "$OUT" "brew install jq"
t "a failed prerequisite check creates no skill symlink"
[ -e "$NOJQ_HOME/.claude/skills/ultrablitz" ] && _no "symlink created" || _ok
t "a failed prerequisite check creates no settings.json"
[ -e "$NOJQ_HOME/.claude/settings.json" ] && _no "settings.json created" || _ok

if ! prereqs_ok; then
  printf '  skip remaining install.sh cases (jq/node>=20/git/codex not all present)\n'
  finish
fi

# --- no-args mode: print only, change nothing ---------------------------------
PRINT_HOME="$(new_home print)"
install_in "$PRINT_HOME"
t "no-args mode exits 2"
assert_rc "$RC" 2
t "no-args mode says nothing was installed"
assert_contains "$OUT" "Nothing was installed"
t "no-args mode creates no skill symlink"
[ -e "$PRINT_HOME/.claude/skills/ultrablitz" ] && _no "symlink created" || _ok
t "no-args mode does not create settings.json"
[ -e "$PRINT_HOME/.claude/settings.json" ] && _no "settings.json created" || _ok

SNIP="$(snippet_of "$OUT")"
t "the printed snippet is valid JSON"
printf '%s\n' "$SNIP" | jq -e . >/dev/null 2>&1 && _ok || _no "not valid JSON: $SNIP"
t "the printed snippet carries the matcher"
assert_json "$SNIP" '.hooks.PreToolUse[0].matcher' 'Edit|Write|NotebookEdit|Bash'
t "the printed snippet carries the gate command"
assert_contains "$SNIP" 'ultrablitz-gate.sh'
t "the printed snippet's hook is a command hook"
assert_json "$SNIP" '.hooks.PreToolUse[0].hooks[0].type' 'command'
t "the printed snippet's PreToolUse is an array (mergeable shape)"
assert_json "$SNIP" '.hooks.PreToolUse | type' 'array'
SNIP_ENTRY="$(printf '%s\n' "$SNIP" | jq -S -c '.hooks.PreToolUse[0]')"

# --- register into a HOME whose settings.json has unrelated keys --------------
CYCLE_HOME="$(new_home cycle)"
CYCLE_SETTINGS="$CYCLE_HOME/.claude/settings.json"
printf '%s\n' '{"model":"opus","permissions":{"allow":["Bash(ls:*)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}' \
  >"$CYCLE_SETTINGS"
install_in "$CYCLE_HOME" --register
t "--register exits 0"
assert_rc "$RC" 0
t "--register reports the hook was registered"
assert_contains "$OUT" "hook: registered"
t "--register links the skill into the fake HOME"
[ -L "$CYCLE_HOME/.claude/skills/ultrablitz" ] && _ok || _no "no symlink at .claude/skills/ultrablitz"
t "--register points the symlink at the repo root"
assert_eq "$(readlink "$CYCLE_HOME/.claude/skills/ultrablitz")" "$UB_ROOT"
t "settings.json is still valid JSON after --register"
jq -e . "$CYCLE_SETTINGS" >/dev/null 2>&1 && _ok || _no "invalid JSON after register"
t "--register keeps the unrelated top-level key"
assert_json "$(cat "$CYCLE_SETTINGS")" '.model' 'opus'
t "--register keeps the unrelated permissions block"
assert_json "$(cat "$CYCLE_SETTINGS")" '.permissions.allow[0]' 'Bash(ls:*)'
t "--register keeps the unrelated Stop hook"
assert_json "$(cat "$CYCLE_SETTINGS")" '.hooks.Stop[0].hooks[0].command' 'true'
t "--register adds the gate hook exactly once"
assert_eq "$(gate_count "$CYCLE_SETTINGS")" "1"
t "--register writes a timestamped backup"
assert_eq "$(backup_count "$CYCLE_HOME")" "1"
t "--register leaves no .ultrablitz.tmp behind"
[ -e "$CYCLE_SETTINGS.ultrablitz.tmp" ] && _no "tmp file left behind" || _ok
# S7: the entry that was written must be byte-identical to the printed snippet's
# entry — they are built from one HOOK_ENTRY, so they cannot drift.
t "the registered entry matches the printed snippet's entry (S7)"
assert_eq "$(gate_entry "$CYCLE_SETTINGS")" "$SNIP_ENTRY"

# --- register twice: idempotent ------------------------------------------------
install_in "$CYCLE_HOME" --register
t "a second --register exits 0"
assert_rc "$RC" 0
t "a second --register reports it is already registered"
assert_contains "$OUT" "hook: already registered"
t "a second --register adds no duplicate entry"
assert_eq "$(gate_count "$CYCLE_SETTINGS")" "1"
t "a second --register writes no extra backup"
assert_eq "$(backup_count "$CYCLE_HOME")" "1"
t "settings.json is still valid JSON after the second --register"
jq -e . "$CYCLE_SETTINGS" >/dev/null 2>&1 && _ok || _no "invalid JSON after re-register"

# --- S6: a failed uninstall must not claim success ----------------------------
# Make the .claude dir read-only so the backup/temp write fails. Skipped for
# root, which ignores the mode bits.
if [ "$(id -u)" = "0" ]; then
  printf '  skip uninstall-failure case (running as root: mode bits are not enforced)\n'
else
  chmod 555 "$CYCLE_HOME/.claude"
  install_in "$CYCLE_HOME" --uninstall
  chmod 755 "$CYCLE_HOME/.claude"
  t "a failed --uninstall exits non-zero (S6)"
  assert_rc "$RC" 3
  t "a failed --uninstall never claims the hook was removed (S6)"
  assert_not_contains "$OUT" "hook: removed"
  t "a failed --uninstall says what went wrong"
  assert_contains "$OUT" "settings.json untouched"
  t "a failed --uninstall leaves the hook registered"
  assert_eq "$(gate_count "$CYCLE_SETTINGS")" "1"
  t "a failed --uninstall leaves settings.json valid"
  jq -e . "$CYCLE_SETTINGS" >/dev/null 2>&1 && _ok || _no "invalid JSON after failed uninstall"
  t "a failed --uninstall keeps the skill symlink (hook still points at it)"
  [ -L "$CYCLE_HOME/.claude/skills/ultrablitz" ] && _ok || _no "symlink removed while hook still registered"
  t "a failed --uninstall leaves no .ultrablitz.tmp behind"
  [ -e "$CYCLE_SETTINGS.ultrablitz.tmp" ] && _no "tmp file left behind" || _ok
fi

# --- uninstall: the happy path -------------------------------------------------
install_in "$CYCLE_HOME" --uninstall
t "--uninstall exits 0"
assert_rc "$RC" 0
t "--uninstall reports the removal"
assert_contains "$OUT" "hook: removed"
t "--uninstall removes the gate hook"
assert_eq "$(gate_count "$CYCLE_SETTINGS")" "0"
t "--uninstall keeps the unrelated top-level key"
assert_json "$(cat "$CYCLE_SETTINGS")" '.model' 'opus'
t "--uninstall keeps the unrelated permissions block"
assert_json "$(cat "$CYCLE_SETTINGS")" '.permissions.allow[0]' 'Bash(ls:*)'
t "--uninstall keeps the unrelated Stop hook"
assert_json "$(cat "$CYCLE_SETTINGS")" '.hooks.Stop[0].hooks[0].command' 'true'
t "settings.json is still valid JSON after --uninstall"
jq -e . "$CYCLE_SETTINGS" >/dev/null 2>&1 && _ok || _no "invalid JSON after uninstall"
t "--uninstall unlinks the skill"
[ -e "$CYCLE_HOME/.claude/skills/ultrablitz" ] && _no "symlink survived" || _ok
t "--uninstall leaves no .ultrablitz.tmp behind"
[ -e "$CYCLE_SETTINGS.ultrablitz.tmp" ] && _no "tmp file left behind" || _ok

# --- uninstall when nothing is registered --------------------------------------
BEFORE="$(cat "$CYCLE_SETTINGS")"
install_in "$CYCLE_HOME" --uninstall
t "--uninstall with nothing registered exits 0"
assert_rc "$RC" 0
t "--uninstall with nothing registered says so"
assert_contains "$OUT" "not registered"
t "--uninstall with nothing registered claims no removal"
assert_not_contains "$OUT" "hook: removed"
t "--uninstall with nothing registered leaves settings.json byte-identical"
assert_eq "$(cat "$CYCLE_SETTINGS")" "$BEFORE"
t "--uninstall with nothing registered leaves settings.json valid"
jq -e . "$CYCLE_SETTINGS" >/dev/null 2>&1 && _ok || _no "invalid JSON"

# --- uninstall with no settings.json at all ------------------------------------
EMPTY_HOME="$(new_home empty)"
install_in "$EMPTY_HOME" --uninstall
t "--uninstall with no settings.json exits 0"
assert_rc "$RC" 0
t "--uninstall with no settings.json says there is nothing to remove"
assert_contains "$OUT" "nothing to remove"
t "--uninstall with no settings.json does not create one"
[ -e "$EMPTY_HOME/.claude/settings.json" ] && _no "settings.json created" || _ok

# --- uninstall when settings.json is not readable/writable ---------------------
if [ "$(id -u)" = "0" ]; then
  printf '  skip unreadable-settings case (running as root: mode bits are not enforced)\n'
else
  RO_HOME="$(new_home rofile)"
  printf '%s\n' '{"model":"opus"}' >"$RO_HOME/.claude/settings.json"
  chmod 000 "$RO_HOME/.claude/settings.json"
  install_in "$RO_HOME" --uninstall
  chmod 644 "$RO_HOME/.claude/settings.json"
  t "--uninstall with an unreadable settings.json exits 0"
  assert_rc "$RC" 0
  t "--uninstall with an unreadable settings.json says to remove the entry by hand"
  assert_contains "$OUT" "by hand"
  t "--uninstall with an unreadable settings.json claims no removal"
  assert_not_contains "$OUT" "hook: removed"
  t "--uninstall with an unreadable settings.json leaves the file intact"
  assert_json "$(cat "$RO_HOME/.claude/settings.json")" '.model' 'opus'
fi

# --- uninstall with a corrupt settings.json ------------------------------------
BAD_HOME="$(new_home corrupt)"
printf '%s\n' 'not json at all' >"$BAD_HOME/.claude/settings.json"
install_in "$BAD_HOME" --uninstall
t "--uninstall on a corrupt settings.json exits 3"
assert_rc "$RC" 3
t "--uninstall on a corrupt settings.json says the file is not valid JSON"
assert_contains "$OUT" "not valid JSON"
t "--uninstall on a corrupt settings.json claims no removal"
assert_not_contains "$OUT" "hook: removed"
t "--uninstall on a corrupt settings.json rewrites nothing"
assert_eq "$(cat "$BAD_HOME/.claude/settings.json")" "not json at all"

finish
