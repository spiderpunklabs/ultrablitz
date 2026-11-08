#!/usr/bin/env bash
# install.sh — install the ultrablitz skill and (optionally) register its hook.
#
#   bash install.sh              check prerequisites, print the hook snippet, exit 2
#   bash install.sh --register   also symlink the skill and edit settings.json
#   bash install.sh --uninstall  remove the hook entry and the skill symlink
#
# Exit codes: 0 registered/uninstalled, 2 snippet printed but nothing installed,
# 3 a prerequisite is missing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_LINK="$HOME/.claude/skills/ultrablitz"
SETTINGS="$HOME/.claude/settings.json"
HOOK_CMD="bash \"\$HOME/.claude/skills/ultrablitz/hooks/ultrablitz-gate.sh\""
MODE="print"
case "${1:-}" in
  --register) MODE="register" ;;
  --uninstall) MODE="uninstall" ;;
  "") MODE="print" ;;
  *)
    echo "usage: install.sh [--register|--uninstall]" >&2
    exit 64
    ;;
esac

say() { printf '%s\n' "$*"; }

# --- prerequisites (exit 3 on the first missing one) -------------------------
need() {
  local bin="$1" hint="$2"
  command -v "$bin" >/dev/null 2>&1 && return 0
  say "MISSING PREREQUISITE: $bin"
  say "  install with: $hint"
  exit 3
}
need jq "brew install jq   (macOS)  |  apt-get install jq   (Linux)"
need node "brew install node  (needs >= 20)"
need git "xcode-select --install  (macOS)  |  apt-get install git"

NODE_MAJOR="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
if ! [ "${NODE_MAJOR:-0}" -ge 20 ] 2>/dev/null; then
  say "MISSING PREREQUISITE: node >= 20 (found $(node --version 2>/dev/null))"
  exit 3
fi
if ! command -v codex >/dev/null 2>&1; then
  say "MISSING PREREQUISITE: codex CLI"
  say "  install with: npm install -g @openai/codex   (from a shell whose \`arch\` matches your CPU)"
  exit 3
fi

# The hook entry is written down ONCE here and reused by both the printed
# snippet and the --register edit below, so the two can never drift apart.
HOOK_ENTRY="$(jq -n --arg cmd "$HOOK_CMD" \
  '{matcher:"Edit|Write|NotebookEdit|Bash",hooks:[{type:"command",command:$cmd}]}')" || {
  say "jq failed to build the hook entry"
  exit 3
}
# Pretty-printed, mergeable JSON a human can paste into settings.json.
SNIPPET="$(jq -n --argjson e "$HOOK_ENTRY" '{hooks:{PreToolUse:[$e]}}')" || {
  say "jq failed to build the settings snippet"
  exit 3
}

hook_registered() {
  [ -r "$SETTINGS" ] || return 2
  jq -e '[.hooks.PreToolUse[]?.hooks[]?.command? // empty] | map(select(contains("ultrablitz-gate.sh"))) | length > 0' \
    "$SETTINGS" >/dev/null 2>&1
}

case "$MODE" in
  print)
    say "Prerequisites OK."
    say ""
    say "Nothing was installed. To install, run:  bash install.sh --register"
    say ""
    say "To register the gate hook by hand instead, merge this into $SETTINGS:"
    say "$SNIPPET"
    exit 2
    ;;

  register)
    mkdir -p "$HOME/.claude/skills"
    if [ -L "$SKILL_LINK" ] || [ -e "$SKILL_LINK" ]; then
      say "skill: $SKILL_LINK already exists — leaving it alone"
    else
      ln -s "$ROOT" "$SKILL_LINK" && say "skill: linked $SKILL_LINK -> $ROOT"
    fi

    if [ ! -e "$SETTINGS" ]; then
      printf '{}\n' >"$SETTINGS"
    fi
    if [ ! -r "$SETTINGS" ] || [ ! -w "$SETTINGS" ]; then
      say "settings.json is not readable/writable by this process: $SETTINGS"
      say "Register the hook by hand — merge this in:"
      say "$SNIPPET"
      exit 3
    fi
    if hook_registered; then
      say "hook: already registered"
    else
      BACKUP="$SETTINGS.bak-$(date -u +%Y%m%dT%H%M%SZ)"
      cp "$SETTINGS" "$BACKUP" || {
        say "could not back up settings.json"
        exit 3
      }
      TMP="$SETTINGS.ultrablitz.tmp"
      jq --argjson e "$HOOK_ENTRY" '
        .hooks //= {} |
        .hooks.PreToolUse //= [] |
        .hooks.PreToolUse += [$e]' \
        "$SETTINGS" >"$TMP" || {
        say "jq failed; settings.json untouched (backup at $BACKUP)"
        rm -f "$TMP"
        exit 3
      }
      jq -e . "$TMP" >/dev/null 2>&1 || {
        say "produced invalid JSON; settings.json untouched (backup at $BACKUP)"
        rm -f "$TMP"
        exit 3
      }
      mv -f "$TMP" "$SETTINGS" || {
        say "could not write $SETTINGS; it is unchanged (backup at $BACKUP)"
        rm -f "$TMP"
        exit 3
      }
      say "hook: registered (backup at $BACKUP)"
    fi

    say ""
    bash "$ROOT/hooks/ultrablitz-utils.sh" doctor
    exit 0
    ;;

  uninstall)
    # Every step is checked. A failure here must never print "removed" and must
    # never exit 0 — the hook would still be live while the user believed it was
    # gone. Failures stop before the symlink is removed, because a registered
    # hook pointing at a missing skill dir is worse than no uninstall at all.
    UNINSTALL_RC=0
    TMP="$SETTINGS.ultrablitz.tmp"
    if [ ! -e "$SETTINGS" ]; then
      say "hook: nothing to remove — no settings.json at $SETTINGS"
    elif [ ! -r "$SETTINGS" ] || [ ! -w "$SETTINGS" ]; then
      say "settings.json is not readable/writable by this process: $SETTINGS"
      say "  remove the ultrablitz-gate.sh hook entry from it by hand"
    elif ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
      say "settings.json is not valid JSON: $SETTINGS"
      say "  nothing was changed — fix the file, then remove the ultrablitz-gate.sh entry"
      exit 3
    elif ! hook_registered; then
      say "hook: not registered in $SETTINGS — nothing to remove"
    else
      BACKUP="$SETTINGS.bak-$(date -u +%Y%m%dT%H%M%SZ)"
      cp "$SETTINGS" "$BACKUP" || {
        say "could not back up settings.json to $BACKUP; settings.json untouched"
        exit 3
      }
      jq '
        if .hooks.PreToolUse then
          .hooks.PreToolUse |= map(
            .hooks |= map(select((.command // "") | contains("ultrablitz-gate.sh") | not))
          ) | .hooks.PreToolUse |= map(select((.hooks | length) > 0))
        else . end' "$SETTINGS" >"$TMP" || {
        say "jq failed to remove the hook; settings.json untouched (backup at $BACKUP)"
        rm -f "$TMP"
        exit 3
      }
      jq -e . "$TMP" >/dev/null 2>&1 || {
        say "removal produced invalid JSON; settings.json untouched (backup at $BACKUP)"
        rm -f "$TMP"
        exit 3
      }
      mv -f "$TMP" "$SETTINGS" || {
        say "could not write $SETTINGS; it is unchanged (backup at $BACKUP)"
        rm -f "$TMP"
        exit 3
      }
      say "hook: removed (backup at $BACKUP)"
    fi

    if [ -L "$SKILL_LINK" ]; then
      if rm -f "$SKILL_LINK"; then
        say "skill: unlinked $SKILL_LINK"
      else
        say "skill: could not remove $SKILL_LINK — remove it by hand"
        UNINSTALL_RC=3
      fi
    fi
    bash "$ROOT/hooks/ultrablitz-utils.sh" gate-clear >/dev/null 2>&1 || true
    exit "$UNINSTALL_RC"
    ;;
esac
