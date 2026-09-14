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

SNIPPET="$(
  cat <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|NotebookEdit|Bash",
        "hooks": [{ "type": "command", "command": $(printf '%s' "$HOOK_CMD" | jq -Rs .) }]
      }
    ]
  }
}
EOF
)"

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
      jq --arg cmd "$HOOK_CMD" '
        .hooks //= {} |
        .hooks.PreToolUse //= [] |
        .hooks.PreToolUse += [{matcher:"Edit|Write|NotebookEdit|Bash",
                               hooks:[{type:"command", command:$cmd}]}]' \
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
      mv -f "$TMP" "$SETTINGS" && say "hook: registered (backup at $BACKUP)"
    fi

    say ""
    bash "$ROOT/hooks/ultrablitz-utils.sh" doctor
    exit 0
    ;;

  uninstall)
    if [ -r "$SETTINGS" ] && [ -w "$SETTINGS" ]; then
      BACKUP="$SETTINGS.bak-$(date -u +%Y%m%dT%H%M%SZ)"
      cp "$SETTINGS" "$BACKUP"
      TMP="$SETTINGS.ultrablitz.tmp"
      jq '
        if .hooks.PreToolUse then
          .hooks.PreToolUse |= map(
            .hooks |= map(select((.command // "") | contains("ultrablitz-gate.sh") | not))
          ) | .hooks.PreToolUse |= map(select((.hooks | length) > 0))
        else . end' "$SETTINGS" >"$TMP" && jq -e . "$TMP" >/dev/null 2>&1 &&
        mv -f "$TMP" "$SETTINGS" && say "hook: removed (backup at $BACKUP)"
      rm -f "$TMP"
    else
      say "settings.json not writable — remove the ultrablitz-gate.sh hook entry by hand"
    fi
    if [ -L "$SKILL_LINK" ]; then
      rm -f "$SKILL_LINK" && say "skill: unlinked $SKILL_LINK"
    fi
    bash "$ROOT/hooks/ultrablitz-utils.sh" gate-clear >/dev/null 2>&1 || true
    exit 0
    ;;
esac
