#!/usr/bin/env bash
# ultrablitz-utils.sh — mechanical subcommands for the ultrablitz skill.
#
# Every step of the debate loop that is NOT a judgement call lives here, so it
# can be tested without an LLM (plan A9). SKILL.md invokes these by name and
# never re-describes their internals (INV-A9).
#
# Subcommands:
#   doctor                 prerequisites + companion + registration report
#   resolve-companion      print path to codex-companion.mjs
#   repo-hash              16-char hash of repo root (or CWD)
#   state-dir              print (and create) the per-user state directory
#   session-new            create a session dir, print its path
#   session-read           print session.json (adds .foreign if another Claude session)
#   session-write          atomically merge a JSON patch into session.json
#   codex-turn             one validated Codex turn (background + wait + result)
#   validate-output        check a Codex response against the locked framework
#   render-contract        render the Phase 2 output contract / attack surface
#   gate-arm               create the post-debate confirmation lock
#   gate-confirm           clear the gate with the unlock code
#   gate-status            report lock state for this repo
#   cleanup-completed      trash completed sessions (exact paths, never rm)
#   cleanup-list           list incomplete sessions with their trash commands
#   trash-session          move one session dir to the trash
set -uo pipefail

UB_VERSION="6.0.0"

# Where this script lives: references/ is resolved relative to it, so a
# checkout, ~/.claude/skills/ultrablitz and a test sandbox all work unchanged.
UB_SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)"

# The edge-case classes every round-1 review must sweep (INV-SWEEP-1). The
# single home of the list: render-contract prints it, validate-output requires it.
UB_SWEEP_CLASSES="empty-or-none scale concurrency partial-failure-and-rollback permissions-and-identity time-and-ordering external-dependency-down human-misuse migration-and-compat"

# Model preference, newest first. The single place this order is stated.
# Per INV-MODEL-1: a model the USER names is never auto-changed; only a model
# taken from this list is downgraded when the account refuses it.
UB_MODEL_PREFERENCE="gpt-6-astra gpt-5.3-codex-spark"

# --- paths -------------------------------------------------------------------

ub_state_dir() {
  # TMPDIR often ends in a slash (macOS); normalise before composing so this
  # path is byte-identical to the one the gate hook computes.
  local t="${TMPDIR:-/tmp}"
  t="${t%/}"
  local d="${ULTRABLITZ_STATE_DIR:-$t/ultrablitz-$(id -u)}"
  d="${d%/}"
  if [ ! -d "$d" ]; then
    mkdir -m 700 -p "$d" || return 1
  fi
  printf '%s\n' "$d"
}

ub_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd -P
}

ub_repo_hash() {
  printf '%s' "$(ub_repo_root)" | shasum -a 256 | cut -c1-16
}

ub_in_git() { git rev-parse --show-toplevel >/dev/null 2>&1; }

# Gate lock hash. Git context: hash(repoRoot) — one gate per repo. Non-git
# fallback: hash("pwd|runId") so parallel runs auditing sibling repos from a
# shared non-git parent directory do not collide on one lock (PR #5).
ub_gate_hash() {
  local run_id="${1:-}"
  if ub_in_git; then
    ub_repo_hash
  else
    printf '%s|%s' "$(ub_repo_root)" "$run_id" | shasum -a 256 | cut -c1-16
  fi
}

# Resolve the active gate lock for this CWD. Git: the single deterministic
# path (whether or not it exists). Non-git: walk gate-*.lock in the state dir
# and return the first whose recorded repoRoot is this CWD; empty if none.
ub_gate_lock_path() {
  local d; d="$(ub_state_dir)" || return 1
  if ub_in_git; then
    printf '%s/gate-%s.lock\n' "$d" "$(ub_repo_hash)"
    return 0
  fi
  local root cand
  root="$(ub_repo_root)"
  for cand in "$d"/gate-*.lock; do
    [ -f "$cand" ] || continue
    [ "$(jq -r '.repoRoot // empty' "$cand" 2>/dev/null)" = "$root" ] || continue
    printf '%s\n' "$cand"
    return 0
  done
  printf '\n'
}

# Move a path to the trash dir instead of deleting it (reversible by design).
# Destination is collision-resistant: <name>-<ts>-<pid>, then -2, -3, ...
ub_trash() {
  local src="$1"
  local trash="${ULTRABLITZ_TRASH_DIR:-$HOME/.Trash}"
  trash="${trash%/}"
  [ -d "$trash" ] || mkdir -p "$trash" || return 1
  local base dst n=2
  base="$trash/ultrablitz-$(basename "$src")-$(date +%s)-$$"
  dst="$base"
  while [ -e "$dst" ] && [ "$n" -le 100 ]; do
    dst="$base-$n"
    n=$((n + 1))
  done
  mv "$src" "$dst" 2>/dev/null || return 1
  printf '%s\n' "$dst"
}

# Fail-closed path trust: dir must exist, not be a symlink, be ours, mode 700.
ub_check_state_dir() {
  local d="$1"
  [ -d "$d" ] || {
    echo "state dir missing: $d" >&2
    return 1
  }
  [ -L "$d" ] && {
    echo "state dir is a symlink: $d" >&2
    return 1
  }
  local owner mode
  owner="$(stat -f '%u' "$d" 2>/dev/null || stat -c '%u' "$d" 2>/dev/null)"
  mode="$(stat -f '%Lp' "$d" 2>/dev/null || stat -c '%a' "$d" 2>/dev/null)"
  [ "$owner" = "$(id -u)" ] || {
    echo "state dir not owned by us: $d" >&2
    return 1
  }
  [ "$mode" = "700" ] || {
    echo "state dir mode $mode, expected 700: $d" >&2
    return 1
  }
  return 0
}

# Leaf file must be a regular file, not a symlink, owned by us.
ub_check_leaf() {
  local f="$1"
  [ -L "$f" ] && {
    echo "refusing symlink: $f" >&2
    return 1
  }
  [ -f "$f" ] || {
    echo "not a regular file: $f" >&2
    return 1
  }
  local owner
  owner="$(stat -f '%u' "$f" 2>/dev/null || stat -c '%u' "$f" 2>/dev/null)"
  [ "$owner" = "$(id -u)" ] || {
    echo "not owned by us: $f" >&2
    return 1
  }
  return 0
}

ub_pid_start() {
  # Process start time, used with the PID as an advisory liveness pair (C3).
  ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

ub_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- model resolution --------------------------------------------------------

# Read the "model" key from .ultrablitz.json (repo root, then CWD; first wins).
ub_config_model() {
  local f
  for f in "$(ub_repo_root)/.ultrablitz.json" "$PWD/.ultrablitz.json"; do
    [ -r "$f" ] || continue
    local m
    m="$(jq -r '.model // empty' "$f" 2>/dev/null)"
    if [ -n "$m" ]; then
      printf '%s\n' "$m"
      return 0
    fi
  done
  return 1
}

# Resolve the model for a run and say where it came from.
# Prints "<model>\t<origin>"; origin is explicit|config|preference|companion.
# Order: --model flag > ULTRABLITZ_MODEL > .ultrablitz.json > preference list.
ub_resolve_model() {
  local flag="${1:-}"
  if [ -n "$flag" ]; then
    printf '%s\texplicit\n' "$flag"
    return 0
  fi
  if [ -n "${ULTRABLITZ_MODEL:-}" ]; then
    printf '%s\texplicit\n' "$ULTRABLITZ_MODEL"
    return 0
  fi
  local cfg
  if cfg="$(ub_config_model)"; then
    printf '%s\tconfig\n' "$cfg"
    return 0
  fi
  local first
  first="$(printf '%s' "$UB_MODEL_PREFERENCE" | awk '{print $1}')"
  if [ -n "$first" ]; then
    printf '%s\tpreference\n' "$first"
    return 0
  fi
  printf '\tcompanion\n'
}

# Next candidate after $1 in the preference list; empty when exhausted.
ub_next_model() {
  printf '%s' "$UB_MODEL_PREFERENCE" | awk -v cur="$1" '
    { for (i = 1; i <= NF; i++) if ($i == cur && i < NF) { print $(i+1); exit } }'
}

# Does this failure mean "the account may not use that model"?
# Structured: HTTP 400 + invalid_request_error + the model named in the message.
# Anything else is an ordinary failure — we never change models on a guess.
# The error usually reaches us inside job.summary, where its quotes are
# JSON-escaped (`\"status\":400`), so the match must tolerate backslashes.
UB_STATUS_400_RE='status[\\"]*[[:space:]]*:[[:space:]]*400'

ub_is_model_refusal() {
  local blob="$1" model="$2"
  printf '%s' "$blob" | grep -qE "$UB_STATUS_400_RE" || return 1
  printf '%s' "$blob" | grep -q 'invalid_request_error' || return 1
  printf '%s' "$blob" | grep -qF "$model" || return 1
  return 0
}

# A 400 we do not recognise, on a model nobody asked for: worth one probe.
ub_is_unknown_400() {
  printf '%s' "$1" | grep -qE "$UB_STATUS_400_RE"
}

# --- prerequisites -----------------------------------------------------------

ub_have() { command -v "$1" >/dev/null 2>&1; }

ub_resolve_companion() {
  # Test override (D7 stub). Honoured only in test mode.
  if [ "${ULTRABLITZ_TEST:-0}" = "1" ] && [ -n "${ULTRABLITZ_COMPANION_OVERRIDE:-}" ]; then
    printf '%s\n' "$ULTRABLITZ_COMPANION_OVERRIDE"
    return 0
  fi
  local c=""
  # Cache path, highest version. Readable regular file is enough: it is run via
  # `node`, so the exec bit is irrelevant (plan A1 / bug #1).
  local hit
  hit="$(ls "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)"
  if [ -n "$hit" ] && [ -f "$hit" ] && [ -r "$hit" ]; then c="$hit"; fi
  if [ -z "$c" ]; then
    local mkt="$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
    if [ -f "$mkt" ] && [ -r "$mkt" ]; then c="$mkt"; fi
  fi
  if [ -z "$c" ]; then
    echo "ERROR: codex-companion.mjs not found" >&2
    echo "Checked:" >&2
    echo "  ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs" >&2
    echo "  ~/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs" >&2
    echo "Install the plugin: /plugin install openai-codex, then /codex:setup" >&2
    return 1
  fi
  printf '%s\n' "$c"
}

ub_companion_version() {
  local c="$1" manifest
  manifest="$(dirname "$(dirname "$c")")/.claude-plugin/plugin.json"
  if [ -r "$manifest" ] && ub_have jq; then
    jq -r '.version // "unknown"' "$manifest" 2>/dev/null || echo unknown
  else
    echo unknown
  fi
}

# --- doctor ------------------------------------------------------------------

cmd_doctor() {
  local json=0
  [ "${1:-}" = "--json" ] && json=1
  local -a checks=()

  add() { checks+=("$(jq -n --arg n "$1" --arg s "$2" --arg d "$3" '{name:$n,status:$s,detail:$d}')"); return 0; }

  if ! ub_have jq; then
    echo "FAIL jq: not installed. Install with: brew install jq (macOS) or apt-get install jq" >&2
    echo "jq is required by ultrablitz and by the gate hook, which stays fail-closed without it." >&2
    return 3
  fi

  # node
  if ub_have node; then
    local nv; nv="$(node --version 2>/dev/null)"
    local nmaj; nmaj="$(printf '%s' "$nv" | sed 's/^v//' | cut -d. -f1)"
    if [ "${nmaj:-0}" -ge 20 ] 2>/dev/null; then add node ok "$nv"; else add node fail "$nv (need >= 20)"; fi
  else
    add node fail "not installed"
  fi

  add jq ok "$(jq --version 2>/dev/null)"

  if ub_have git; then add git ok "$(git --version 2>/dev/null)"; else add git fail "not installed"; fi

  # codex CLI + arch mismatch diagnosis (A7)
  if ub_have codex; then
    local cv rc
    cv="$(codex --version 2>&1)"; rc=$?
    if [ $rc -eq 0 ]; then
      add codex ok "$cv"
    else
      local arch; arch="$(uname -m)"
      local hint=""
      case "$cv" in
        *codex-darwin-x64*) [ "$arch" = "arm64" ] && hint="wrong-arch install (x64 package on arm64 host). Fix from a native shell (arch must print arm64): npm uninstall -g @openai/codex && npm install -g @openai/codex" ;;
        *codex-darwin-arm64*) [ "$arch" = "x86_64" ] && hint="wrong-arch install (arm64 package on x64 host). Fix: npm uninstall -g @openai/codex && npm install -g @openai/codex" ;;
      esac
      [ -z "$hint" ] && hint="$(printf '%s' "$cv" | head -1)"
      add codex fail "$hint"
    fi
  else
    add codex fail "not installed. Install with: npm install -g @openai/codex"
  fi

  # companion
  local comp
  if comp="$(ub_resolve_companion 2>/dev/null)"; then
    add companion ok "$comp (plugin $(ub_companion_version "$comp"))"
  else
    add companion fail "codex-companion.mjs not found — install the openai-codex plugin"
  fi

  # gate hook registration. settings.json may be unreadable by policy; report
  # unknown rather than failing, and never claim gate enforcement when unsure.
  local settings="$HOME/.claude/settings.json" reg="unknown" regdetail="settings.json not readable — cannot confirm; gate enforcement unverified"
  if [ -r "$settings" ]; then
    if jq -e --arg h "ultrablitz-gate.sh" '[.hooks.PreToolUse[]?.hooks[]?.command? // empty] | map(select(contains($h))) | length > 0' "$settings" >/dev/null 2>&1; then
      reg="ok"; regdetail="PreToolUse hook registered"
    else
      reg="fail"; regdetail="PreToolUse hook NOT registered — run: bash install.sh --register"
    fi
  fi
  add registration "$reg" "$regdetail"

  # test override must be loud (D7)
  if [ -n "${ULTRABLITZ_COMPANION_OVERRIDE:-}" ]; then
    add companion-override warn "TEST OVERRIDE ACTIVE: $ULTRABLITZ_COMPANION_OVERRIDE (ULTRABLITZ_TEST=${ULTRABLITZ_TEST:-0})"
  fi

  # .ok is derived once, in the jq below, and the exit code reads it back —
  # one source of truth instead of a parallel shell flag (defect S12). The
  # array guard covers bash 3.2's empty-"${a[@]}" abort; checks is never empty
  # in practice (jq's presence alone adds an entry), but the guard is free.
  local out
  if [ ${#checks[@]} -eq 0 ]; then
    out="$(jq -n --arg v "$UB_VERSION" '{version:$v, ok:false, checks:[]}')"
  else
    out="$(printf '%s\n' "${checks[@]}" | jq -s --arg v "$UB_VERSION" '{version:$v, ok: (map(select(.status=="fail")) | length == 0), checks: .}')"
  fi
  if [ "$json" = "1" ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out" | jq -r '(.checks[] | "\(.status | ascii_upcase | .[0:4]) \(.name): \(.detail)"), (if .ok then "doctor: PASS" else "doctor: FAIL" end)'
  fi
  printf '%s' "$out" | jq -e '.ok' >/dev/null
}

# --- sessions ----------------------------------------------------------------

cmd_session_new() {
  local sd d
  d="$(ub_state_dir)" || return 1
  ub_check_state_dir "$d" || return 1
  sd="$(mktemp -d "$d/session-XXXXXXXX")" || return 1
  chmod 700 "$sd"
  local run_id
  run_id="$(uuidgen)"
  jq -n \
    --arg sv "1" --arg rid "$run_id" --arg now "$(ub_now)" \
    --arg cs "${CLAUDE_SESSION_ID:-unknown}" --arg pid "$$" --arg ps "$(ub_pid_start $$)" \
    '{schemaVersion:($sv|tonumber), runId:$rid, createdAt:$now, lastActiveAt:$now,
      claudeSessionId:$cs, codexSessionId:null, ownerPid:($pid|tonumber), ownerPidStart:$ps,
      phase:1, round:0, attemptCount:0, threadId:null, jobIds:[], framework:null,
      ledger:[], lastCritiqueId:0, ledgerUnchangedRounds:0, scores:[], planPath:null,
      degraded:{reason:null}, authoritative:true, completed:false}' > "$sd/session.json.tmp" || return 1
  mv -f "$sd/session.json.tmp" "$sd/session.json" || return 1
  printf '%s\n' "$sd"
}

cmd_session_read() {
  local sd="${1:?session dir required}"
  ub_check_leaf "$sd/session.json" || return 1
  local cs
  cs="$(jq -r '.claudeSessionId // "unknown"' "$sd/session.json")"
  local mine="${CLAUDE_SESSION_ID:-unknown}"
  if [ "$cs" != "$mine" ]; then
    # $cs, not the raw field: a null claudeSessionId would make jq abort on
    # null + string (defect S10), and session-write accepts arbitrary patches.
    jq --arg m "$mine" --arg owner "$cs" '. + {foreign:true, foreignDetail:("owned by Claude session " + $owner + ", current is " + $m)}' "$sd/session.json"
  else
    jq '. + {foreign:false}' "$sd/session.json"
  fi
}

# session-write <dir> <json-patch>   (shallow merge, atomic, single-writer)
cmd_session_write() {
  local sd="${1:?session dir required}" patch="${2:?json patch required}"
  ub_check_leaf "$sd/session.json" || return 1
  printf '%s' "$patch" | jq -e . >/dev/null 2>&1 || {
    echo "session-write: patch is not valid JSON" >&2
    return 1
  }

  # Single-writer enforcement lives HERE, in the only code path that writes —
  # not in caller discipline. There is deliberately no override flag: a run is
  # not resumable from another Claude session, and the recovery for an
  # abandoned run is `run-lock --force-new` plus a fresh session.
  # Environment contract, one row per case:
  #   stored "unknown", env present  -> adopt (claim the session, record when)
  #   stored concrete,  env missing  -> refuse (absent can never mean "matches")
  #   stored concrete,  env differs  -> refuse
  #   both unknown/empty             -> allow (single-writer is vacuous)
  local stored_cs env_cs="" adopt=""
  stored_cs="$(jq -r '.claudeSessionId // "unknown"' "$sd/session.json")"
  env_cs="${CLAUDE_SESSION_ID:-}"
  if [ "$stored_cs" = "unknown" ] && [ -n "$env_cs" ]; then
    adopt="$env_cs"
  elif [ "$stored_cs" != "unknown" ] && [ -z "$env_cs" ]; then
    echo "session-write: refused — session belongs to Claude session '$stored_cs' and CLAUDE_SESSION_ID is not set." >&2
    echo "session-write: recovery: run-lock --force-new and a fresh session-new; foreign sessions are never written." >&2
    return 1
  elif [ "$stored_cs" != "unknown" ] && [ "$env_cs" != "$stored_cs" ]; then
    echo "session-write: refused — session belongs to Claude session '$stored_cs', current is '$env_cs'." >&2
    echo "session-write: recovery: run-lock --force-new and a fresh session-new; foreign sessions are never written." >&2
    return 1
  fi

  local tmp="$sd/session.json.tmp"
  if [ -n "$adopt" ]; then
    jq --argjson p "$patch" --arg now "$(ub_now)" --arg cs "$adopt" \
      '. * $p * {lastActiveAt:$now, claudeSessionId:$cs, claudeSessionIdAdoptedAt:$now}' \
      "$sd/session.json" > "$tmp" || return 1
  else
    jq --argjson p "$patch" --arg now "$(ub_now)" '. * $p * {lastActiveAt:$now}' "$sd/session.json" > "$tmp" || return 1
  fi
  # Only publish a complete file: jq wrote to tmp, rename is atomic.
  mv -f "$tmp" "$sd/session.json" || return 1
  printf 'ok\n'
}

# resolve-model --session <dir> [--model <flag>]
# Resolves the run's model once (plan E1) and records it atomically.
cmd_resolve_model() {
  local sd="" flag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) sd="$2"; shift 2 ;;
      --model) flag="$2"; shift 2 ;;
      *) echo "resolve-model: unknown arg $1" >&2; return 2 ;;
    esac
  done
  [ -d "${sd:-}" ] || { echo "resolve-model: --session <dir> required" >&2; return 2; }
  local line m origin
  line="$(ub_resolve_model "$flag")"
  m="$(printf '%s' "$line" | cut -f1)"
  origin="$(printf '%s' "$line" | cut -f2)"
  if [ -n "$m" ]; then
    cmd_session_write "$sd" "$(jq -n -c --arg m "$m" --arg o "$origin" '{model:$m, modelOrigin:$o}')" >/dev/null || {
      echo "resolve-model: could not record the model in session.json" >&2
      return 1
    }
  fi
  jq -n --arg m "$m" --arg o "$origin" \
    '{model:(if $m=="" then null else $m end), origin:$o, preference:"'"$UB_MODEL_PREFERENCE"'"}'
}

# --- output validation -------------------------------------------------------
# validate-output --contract <framework.json> --input <file> [--baseline <file>]
#                 [--round N] [--last-id N] [--confirm-only]
# framework.json: {"categories":[{"name":..,"weight":N}..],"max":N,
#                  "attackSurface":[..]?}
# --round 1 requires the EDGE CASE SWEEP section (INV-SWEEP-1); --round >= 2
# classifies NEW findings (id > --last-id) as admitted or noted (INV-ADMIT-1)
# without failing the turn; --confirm-only admits only CRITICAL new findings.
cmd_validate_output() {
  local contract="" input="" baseline="" round=0 last_id=0 confirm_only=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --contract) contract="$2"; shift 2 ;;
      --input) input="$2"; shift 2 ;;
      --baseline) baseline="$2"; shift 2 ;;
      --round) round="$2"; shift 2 ;;
      --last-id) last_id="$2"; shift 2 ;;
      --confirm-only) confirm_only=true; shift ;;
      *) echo "validate-output: unknown arg $1" >&2; return 2 ;;
    esac
  done
  case "$round$last_id" in *[!0-9]*) echo "validate-output: --round and --last-id take integers" >&2; return 2 ;; esac
  [ -r "$contract" ] || { echo "validate-output: contract unreadable" >&2; return 2; }
  [ -r "$input" ] || { echo "validate-output: input unreadable" >&2; return 2; }
  # A broken contract fails loudly instead of validating vacuously (ok:true
  # with zero checks performed).
  jq -e '(.categories | type == "array") and (.categories | length > 0) and (.max | type == "number")' \
    "$contract" >/dev/null 2>&1 || {
    echo "validate-output: contract is not valid framework JSON ({categories:[{name,weight}...], max:N}): $contract" >&2
    return 2
  }

  # One awk pass per file (ub_scan_output), one jq filter for every check and
  # the final object: no shell arrays (bash-3.2 empty-"${a[@]}" trap), no
  # string-pasted JSON (S2), no duplicated baseline parser (S5).
  local out stream bstream=""
  stream="$(ub_scan_output "$input")"
  [ -n "$baseline" ] && [ -r "$baseline" ] && bstream="$(ub_scan_output "$baseline")"
  out="$(printf '%s\n' "$stream" | jq -Rs --arg b "$bstream" --slurpfile c "$contract" \
    --argjson round "$round" --argjson lastId "$last_id" --argjson confirmOnly "$confirm_only" \
    --arg sweep "$UB_SWEEP_CLASSES" '
    def rows: split("\n") | map(select(length > 0) | split("\t"));
    def norm: ascii_downcase | gsub("^\\s+|\\s+$"; "");
    def cats($r): [$r[] | select(.[0] == "S") | {name: .[1], score: (.[2] | tonumber)}];
    def crit($r): ([$r[] | select(.[0] == "C")][0]);
    def xs($r): [$r[] | select(.[0] == "X")
                 | {id: .[1], sev: .[2], cat: .[3], ev: (.[4]|tonumber), im: (.[5]|tonumber),
                    su: (.[6]|tonumber), trig: (.[7] == "1"), miss: (.[8] == "1")}];
    def es($r): [$r[] | select(.[0] == "E") | {cls: .[1], status: .[2], ref: (.[3] == "1")}];
    rows as $r | ($b | rows) as $br
    | cats($r) as $cats | crit($r) as $cc | ($cc[1] | tonumber) as $ncrit
    | xs($r) as $xs | es($r) as $es
    | ([$r[] | select(.[0] == "H")][0]) as $hh
    | ($c[0].categories | map(.name)) as $want | ($cats | map(.name)) as $got
    | ($c[0].categories | map({key: (.name|norm), value: .weight}) | from_entries) as $w
    | ($sweep | split(" ") | map(select(length > 0))) as $classes
    | ([$xs[] | select(.id != "-")] | map(.id |= tonumber)) as $ided
    | ([$ided[] | select(.id > $lastId)] | sort_by(.id)) as $newx
    | ($newx | map(.id)) as $new
    | (if $b == "" then null
       else {scores: (cats($br) | map(.score)), ncrit: (crit($br)[1] | tonumber)} end) as $base
    | ( (if ([$r[] | select(.[0] == "M")][0][1]) == "1" then [] else ["output is empty"] end)
      + ([["## CATEGORY SCORES", $hh[1]], ["## CRITIQUES", $hh[2]],
          ["## STRENGTHS", $hh[3]], ["## VERDICT", $hh[4]]]
         | map(select(.[1] != "1") | "missing section header: " + .[0]))
      + (if $round == 1 and $hh[5] != "1" then ["missing section header: ## EDGE CASE SWEEP (required on round 1)"] else [] end)
      + (($want | map(select(. as $x | ($got | map(norm) | index($x|norm)) == null)))
         | if length > 0 then ["missing categories: " + join(", ")] else [] end)
      + (($got | map(select(. as $g | ($want | map(norm) | index($g|norm)) == null)))
         | if length > 0 then ["unexpected categories: " + join(", ")] else [] end)
      + (($got | map(norm) | group_by(.) | map(select(length > 1) | .[0]))
         | if length > 0 then ["duplicate categories: " + join(", ")] else [] end)
      + (($cats | map(select((.score < 0) or ($w[(.name|norm)] != null and .score > $w[(.name|norm)])))
               | map("\(.name)=\(.score)"))
         | if length > 0 then ["category score out of bounds: " + join(", ")] else [] end)
      + (if $ncrit > 0 then
           ([["Evidence", ($cc[2] | tonumber)], ["Impact", ($cc[3] | tonumber)],
             ["Suggestion", ($cc[4] | tonumber)]]
            | map(select(.[1] < $ncrit) | "\($ncrit) critiques but \(.[1]) \(.[0]) fields"))
         else [] end)
      + (($cc[5] | tonumber) as $leg
         | if $leg > 0 then ["\($leg) critique(s) without a UB-n id (INV-ID-1)"] else [] end)
      + (($ided | group_by(.id) | map(select(length > 1) | "UB-\(.[0].id)"))
         | if length > 0 then ["duplicate critique ids: " + join(", ")] else [] end)
      + (if ($new | length) > 0 and $new != [range($lastId + 1; $lastId + 1 + ($new | length))]
         then ["new critique ids must continue from UB-\($lastId + 1) and increase by one (INV-ID-1): got "
               + ($new | map("UB-\(.)") | join(", "))] else [] end)
      + (([$ided[] | select(.cat == "")] | length) as $nocat
         | if $nocat > 0 then ["\($nocat) critique(s) without a Category line (INV-ID-1)"] else [] end)
      + (([$ided[] | . as $e | select($e.cat != "" and (($want | map(norm) | index($e.cat|norm)) == null))
                   | "UB-\($e.id)=\($e.cat)"])
         | if length > 0 then ["critique Category not in the locked framework: " + join(", ")] else [] end)
      + (if $round == 1 then
           ((($classes - ($es | map(.cls))) | if length > 0 then ["edge case sweep missing classes: " + join(", ")] else [] end)
            + ((($es | map(.cls)) - $classes) | if length > 0 then ["edge case sweep has unknown classes: " + join(", ")] else [] end)
            + (($es | group_by(.cls) | map(select(length > 1) | .[0].cls)) | if length > 0 then ["edge case sweep repeats classes: " + join(", ")] else [] end)
            + (([$es[] | select(.status == "UNCOVERED" and (.ref | not)) | .cls])
               | if length > 0 then ["UNCOVERED sweep rows must name their critique (UB-n): " + join(", ")] else [] end))
         else [] end)
      + (if $base != null and ($base.scores | length > 0) and $base.scores != ($cats | map(.score))
         then ["repair changed scores: was [" + ($base.scores | join(",")) + "] now ["
               + ($cats | map(.score) | join(",")) + "]"] else [] end)
      + (if $base != null and $base.ncrit > 0 and $base.ncrit != $ncrit
         then ["repair changed critique count: was \($base.ncrit) now \($ncrit)"] else [] end)
      ) as $errs
    # Admissibility (INV-ADMIT-1) is a classification, never an error: a noted
    # finding stays in the output for the user to see but does not enter the ledger.
    | (if $round >= 2 then
         ($newx | map(
           if $confirmOnly then
             (if .sev == "CRITICAL" and (.trig or .miss) then {id, admitted: true}
              else {id, admitted: false, reason: "confirm-only round: only a CRITICAL finding with Triggered-by or Missed-because is admitted"} end)
           else
             (if .trig then {id, admitted: true}
              elif .miss and .sev != "MINOR" then {id, admitted: true}
              elif .miss then {id, admitted: false, reason: "MINOR finding on round \($round) with no Triggered-by"}
              else {id, admitted: false, reason: "new finding on round \($round) with neither Triggered-by nor Missed-because"} end)
           end))
       else ($newx | map({id, admitted: true})) end) as $adm
    | {ok: (($errs | length) == 0), errors: $errs, categories: $cats,
       critiqueCount: $ncrit, total: ($cats | map(.score) | add // 0),
       critiques: ($ided | map({id: "UB-\(.id)", severity: .sev, category: .cat})),
       lastId: (([$ided[].id] + [$lastId]) | max),
       newIds: ($new | map("UB-\(.)")),
       admissibility: {admitted: ([$adm[] | select(.admitted) | "UB-\(.id)"]),
                       noted: ([$adm[] | select(.admitted | not) | {id: "UB-\(.id)", reason}])},
       sweep: (if $round == 1 then
                 {covered: [$es[] | select(.status == "COVERED") | .cls],
                  uncovered: [$es[] | select(.status == "UNCOVERED") | .cls],
                  notApplicable: [$es[] | select(.status == "N-A") | .cls]}
               else null end)}')" || {
    echo "validate-output: internal jq failure" >&2
    return 2
  }
  printf '%s\n' "$out"
  printf '%s' "$out" | jq -e '.ok' >/dev/null
}

# --- contract rendering -------------------------------------------------------
# render-contract --contract <framework.json> --round N [--part contract|surface]
#                 [--doc <output-contract.md>]
# The Phase 2 contract text is rendered from references/output-contract.md
# (the one documented template) plus the locked framework — never hand-typed.
#   contract  (default) the {OUTPUT_CONTRACT} block for this round
#   surface   the {ATTACK_SURFACE} bullet list locked in Phase 1 (INV-SURFACE-1)

# Print the lines inside the first fenced block that follows a line containing
# the marker text.
ub_doc_block() {
  awk -v marker="$2" '
    index($0, marker) { insec = 1; next }
    insec && /^```/ { if (infence) exit; infence = 1; next }
    insec && infence { print }
  ' "$1"
}

# Expand one {SLOT} in a template read on stdin with a (possibly multi-line,
# possibly empty) value. Pure bash: see ub_render_repair for why not awk/sed.
ub_expand() {
  local slot="$1" value="$2" line pre post
  while IFS= read -r line; do
    case "$line" in
      *"{$slot}"*)
        pre="${line%%"{$slot}"*}"
        post="${line#*"{$slot}"}"
        [ -n "$pre" ] && printf '%s\n' "$pre"
        [ -n "$value" ] && printf '%s\n' "$value"
        [ -n "$post" ] && printf '%s\n' "$post"
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
  return 0
}

cmd_render_contract() {
  local contract="" round="" part="contract" doc="$UB_SELF_ROOT/references/output-contract.md"
  while [ $# -gt 0 ]; do
    case "$1" in
      --contract) contract="$2"; shift 2 ;;
      --round) round="$2"; shift 2 ;;
      --part) part="$2"; shift 2 ;;
      --doc) doc="$2"; shift 2 ;;
      *) echo "render-contract: unknown arg $1" >&2; return 2 ;;
    esac
  done
  [ -r "$contract" ] || { echo "render-contract: --contract <framework.json> required" >&2; return 2; }
  jq -e '(.categories | type == "array") and (.categories | length > 0)' "$contract" >/dev/null 2>&1 || {
    echo "render-contract: contract is not valid framework JSON" >&2; return 2; }

  if [ "$part" = "surface" ]; then
    jq -r '.attackSurface // [] | if length == 0
             then "- (none locked in Phase 1 — apply the generic attack surface)"
             else .[] | "- " + . end' "$contract"
    return 0
  fi
  [ "$part" = "contract" ] || { echo "render-contract: --part must be contract or surface" >&2; return 2; }
  case "$round" in ''|*[!0-9]*) echo "render-contract: --round N (>= 1) required" >&2; return 2 ;; esac
  [ -r "$doc" ] || { echo "render-contract: template doc unreadable: $doc" >&2; return 2; }

  local base pre_frag="" post_frag="" cats classes
  base="$(ub_doc_block "$doc" 'Phase 2 contract — base template')"
  [ -n "$base" ] || { echo "render-contract: base template block not found in $doc" >&2; return 2; }
  cats="$(jq -r '.categories[] | "- \(.name): {0-\(.weight)}"' "$contract")"
  classes="$(printf '%s\n' "$UB_SWEEP_CLASSES" | tr ' ' '\n' \
    | sed 's/.*/- &: COVERED | UNCOVERED | N-A — {one line: the plan text that covers it, the UB-n you raised, or why it cannot apply}/')"
  if [ "$round" = "1" ]; then
    pre_frag="$(ub_doc_block "$doc" 'Phase 2 — round 1 fragment')"
  else
    post_frag="$(ub_doc_block "$doc" 'Phase 2 — rounds 2+ fragment')"
  fi
  printf '%s\n' "$base" \
    | ub_expand ROUND_PRE "$pre_frag" \
    | ub_expand ROUND_POST "$post_frag" \
    | ub_expand EDGE_CASE_CLASSES "$classes" \
    | ub_expand CATEGORIES "$cats"
}

# One pass over a response file, emitting a tagged TSV stream for jq:
#   S <name> <score>   per parsed category-score line
#   M <0|1>            file has any non-whitespace content
#   H <h1> <h2> <h3> <h4>  presence of the four required section headers
#   C <n> <ev> <im> <su>   critique count and Evidence/Impact/Suggestion counts
# The single home of the response grammar — the baseline (pre-repair) file is
# scanned by this same function, so the two parses can never drift apart.
#   X <id> <sev> <cat> <ev> <im> <su> <trig> <miss>
#                      one row per critique entry: UB id ("-" for a legacy
#                      numbered entry), severity, Category line, sub-field
#                      counts, Triggered-by / Missed-because presence
#   E <class> <status> <ref>  one row per EDGE CASE SWEEP line (ref=1 when the
#                      line names a UB-n critique)
ub_scan_output() {
  awk '
    function flush() {
      if (cur != "")
        printf "X\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\n", cid, csev, ccat, cev, cim, csu, ctrig, cmiss
      cur = ""; cid = ""; csev = ""; ccat = ""; cev = 0; cim = 0; csu = 0; ctrig = 0; cmiss = 0
    }
    /[^[:space:]]/ { ne = 1 }
    index($0, "## CATEGORY SCORES") { h1 = 1 }
    index($0, "## CRITIQUES") { h2 = 1 }
    index($0, "## STRENGTHS") { h3 = 1 }
    index($0, "## VERDICT") { h4 = 1 }
    index($0, "## EDGE CASE SWEEP") { h5 = 1 }
    index($0, "## NOTES") { h6 = 1 }
    /^## / { if (inc) flush(); inblk = 0; inc = 0; insw = 0 }
    /^## CATEGORY SCORES/ { inblk = 1; next }
    /^## CRITIQUES/ { inc = 1; next }
    /^## EDGE CASE SWEEP/ { insw = 1; next }
    inblk && /^[[:space:]]*-[[:space:]]*.+:[[:space:]]*-?[0-9]+[[:space:]]*$/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      idx = match(line, /:[[:space:]]*-?[0-9]+[[:space:]]*$/)
      name = substr(line, 1, idx - 1)
      score = substr(line, idx + 1)
      gsub(/[^0-9-]/, "", score)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      printf "S\t%s\t%s\n", name, score
    }
    insw && /^[[:space:]]*-[[:space:]]*[a-z][a-z-]*:[[:space:]]*(COVERED|UNCOVERED|N-A)/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      idx = index(line, ":")
      cls = substr(line, 1, idx - 1)
      rest = substr(line, idx + 1)
      match(rest, /(COVERED|UNCOVERED|N-A)/)
      st = substr(rest, RSTART, RLENGTH)
      printf "E\t%s\t%s\t%d\n", cls, st, (rest ~ /UB-[0-9]+/) ? 1 : 0
    }
    # Critique entry header: "UB-7 **[MAJOR]** summary" (a leading "3. " or
    # bold around the id is tolerated; the id and the bracketed severity are not).
    inc && /^[[:space:]]*([0-9]+\.[[:space:]]+)?(\*\*)?UB-[0-9]+(\*\*)?[[:space:]]+\*\*\[(CRITICAL|MAJOR|MINOR)\]\*\*/ {
      flush(); n++; cur = "x"
      match($0, /UB-[0-9]+/); cid = substr($0, RSTART + 3, RLENGTH - 3)
      match($0, /\[(CRITICAL|MAJOR|MINOR)\]/); csev = substr($0, RSTART + 1, RLENGTH - 2)
      next
    }
    # Legacy numbered entry without a UB id: counted, reported as an error by jq.
    inc && /^[[:space:]]*[0-9]+\.[[:space:]]/ { flush(); n++; legacy++; cur = "x"; cid = "-"; csev = "-"; next }
    cur != "" && /^[[:space:]]*-[[:space:]]*Category:/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*Category:[[:space:]]*/, "", line)
      gsub(/\*\*/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      ccat = line
    }
    cur != "" && /^[[:space:]]*-[[:space:]]*Evidence:/ { cev++; ev++ }
    cur != "" && /^[[:space:]]*-[[:space:]]*Impact:/ { cim++; im++ }
    cur != "" && /^[[:space:]]*-[[:space:]]*Suggestion:/ { csu++; su++ }
    cur != "" && /^[[:space:]]*-[[:space:]]*Triggered-by:/ { ctrig = 1 }
    cur != "" && /^[[:space:]]*-[[:space:]]*Missed-because:/ { cmiss = 1 }
    END {
      if (inc) flush()
      printf "M\t%d\n", ne + 0
      printf "H\t%d\t%d\t%d\t%d\t%d\t%d\n", h1 + 0, h2 + 0, h3 + 0, h4 + 0, h5 + 0, h6 + 0
      printf "C\t%d\t%d\t%d\t%d\t%d\n", n + 0, ev + 0, im + 0, su + 0, legacy + 0
    }' "$1"
}

# --- codex turn --------------------------------------------------------------
# codex-turn --session <dir> --prompt-file <f> [--resume] [--timeout-ms N]
#            [--contract <framework.json>] [--repair-template <f>] [--label L]
# Prints ONE json object: {ok, failureClass, jobId, threadId, codexSessionId,
#                          outputFile, attempts, formatRepair, message}
cmd_codex_turn() {
  local sd="" pf="" resume=0 timeout_ms=300000 contract="" repair_tpl="" label="turn"
  local model="${ULTRABLITZ_MODEL:-}" effort="${ULTRABLITZ_EFFORT:-}"
  local v_round=0 v_last_id=0 v_confirm=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) sd="$2"; shift 2 ;;
      --prompt-file) pf="$2"; shift 2 ;;
      --resume) resume=1; shift ;;
      --timeout-ms) timeout_ms="$2"; shift 2 ;;
      --contract) contract="$2"; shift 2 ;;
      --repair-template) repair_tpl="$2"; shift 2 ;;
      --label) label="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;;
      --round) v_round="$2"; shift 2 ;;
      --last-id) v_last_id="$2"; shift 2 ;;
      --confirm-only) v_confirm=1; shift ;;
      *) echo "codex-turn: unknown arg $1" >&2; return 2 ;;
    esac
  done
  # Validation options forwarded to validate-output (INV-SWEEP-1, INV-ADMIT-1).
  ub_validate() {
    if [ "$v_confirm" = 1 ]; then
      cmd_validate_output --round "$v_round" --last-id "$v_last_id" --confirm-only "$@"
    else
      cmd_validate_output --round "$v_round" --last-id "$v_last_id" "$@"
    fi
  }
  [ -d "$sd" ] || { echo "codex-turn: session dir required" >&2; return 2; }
  [ -r "$pf" ] || { echo "codex-turn: prompt file unreadable" >&2; return 2; }

  local comp repo
  comp="$(ub_resolve_companion)" || { ub_turn_fail FATAL "companion not found"; return 1; }
  repo="$(ub_repo_root)"

  local prev_thread prev_cs
  prev_thread="$(jq -r '.threadId // empty' "$sd/session.json")"
  prev_cs="$(jq -r '.codexSessionId // empty' "$sd/session.json")"

  # Model + origin. A model the user named (flag or env) is "explicit" and is
  # never auto-changed. Otherwise use what resolve-model recorded in the session.
  local model_origin="companion"
  if [ -n "$model" ]; then
    model_origin="explicit"
  else
    local sm so
    sm="$(jq -r '.model // empty' "$sd/session.json" 2>/dev/null)"
    so="$(jq -r '.modelOrigin // empty' "$sd/session.json" 2>/dev/null)"
    if [ -n "$sm" ]; then
      model="$sm"
      model_origin="${so:-preference}"
    fi
  fi

  # Resume predicate — mechanical, fail-closed (plan A3). --resume is honoured
  # only when a validated DEBATE turn exists to resume: session.json must carry
  # a threadId and a lastTurnLabel that is not the smoke turn. Otherwise the
  # resume silently grafts the debate onto the smoke thread (defect C3).
  local resume_refused=""
  if [ "$resume" = 1 ]; then
    local last_label
    last_label="$(jq -r '.lastTurnLabel // empty' "$sd/session.json" 2>/dev/null)"
    if [ -z "$prev_thread" ] || [ -z "$last_label" ]; then
      resume=0
      resume_refused="no validated debate turn recorded (threadId/lastTurnLabel missing)"
    else
      case "$last_label" in
        smoke*)
          resume=0
          resume_refused="last validated turn was the smoke turn"
          ;;
      esac
    fi
  fi

  local attempts=0 format_repair=false model_downgrade="null" probe_used=0

  ub_launch() {
    # Launch in background, return jobId on stdout.
    # No empty-array expansion: bash 3.2 (macOS /bin/bash) treats "${a[@]}" on an
    # empty array as an unbound variable under `set -u` and aborts the launch.
    # --model/--effort are only passed when set, so the companion keeps its own
    # defaults otherwise. `spark` is the companion's alias for a codex model.
    local m_flag="" m_val="" e_flag="" e_val=""
    if [ -n "$model" ]; then m_flag="--model"; m_val="$model"; fi
    if [ -n "$effort" ]; then e_flag="--effort"; e_val="$effort"; fi
    if [ "$1" = "resume" ]; then
      node "$comp" task --json --background --cwd "$repo" --resume-last \
        ${m_flag:+"$m_flag" "$m_val"} ${e_flag:+"$e_flag" "$e_val"} \
        --prompt-file "$2" 2>"$sd/$label.launch.err"
    else
      node "$comp" task --json --background --cwd "$repo" \
        ${m_flag:+"$m_flag" "$m_val"} ${e_flag:+"$e_flag" "$e_val"} \
        --prompt-file "$2" 2>"$sd/$label.launch.err"
    fi
  }

  ub_collect() {
    # wait then fetch; echoes the result JSON of storedJob.result plus sessionId
    node "$comp" status "$1" --wait --timeout-ms "$timeout_ms" --json --cwd "$repo" >"$sd/$label.status.json" 2>/dev/null
    node "$comp" result "$1" --json --cwd "$repo" 2>/dev/null
  }

  # Launch → collect → extract, with a bounded model-fallback loop (plan E2/E5):
  # at most one model switch per turn, and only for a model nobody explicitly
  # asked for. Every switch is recorded in session.json in the same step, and a
  # failed record aborts the turn — session.json never names a model other than
  # the one in use.
  local launch_mode=fresh
  [ "$resume" = 1 ] && launch_mode=resume

  local launch_json jobid res_json status raw thread csid
  while :; do
    launch_json="$(ub_launch "$launch_mode" "$pf")"
    if ! printf '%s' "$launch_json" | jq -e .jobId >/dev/null 2>&1; then
      local err; err="$(cat "$sd/$label.launch.err" 2>/dev/null)"
      # "task still running" — this session's own job (E13: foreign jobs are
      # invisible to us, so there is no foreign branch).
      if printf '%s%s' "$launch_json" "$err" | grep -qi 'still running'; then
        local running
        running="$(node "$comp" status --json --cwd "$repo" 2>/dev/null | jq -r '.running[0].id // empty')"
        if [ -n "$running" ]; then
          node "$comp" status "$running" --wait --timeout-ms "$timeout_ms" --json --cwd "$repo" >/dev/null 2>&1
          launch_json="$(ub_launch "$launch_mode" "$pf")"
        fi
        if ! printf '%s' "$launch_json" | jq -e .jobId >/dev/null 2>&1; then
          ub_turn_fail RETRYABLE "a Codex task is still running${running:+ (job $running)}; no state was changed"
          return 1
        fi
      else
        ub_turn_fail RETRYABLE "launch failed: $(printf '%s' "$err" | head -3 | tr '\n' ' ')"
        return 1
      fi
    fi
    jobid="$(printf '%s' "$launch_json" | jq -r .jobId)"

    res_json="$(ub_collect "$jobid")"
    attempts=$((attempts + 1))

    if ! printf '%s' "$res_json" | jq -e '.storedJob.result' >/dev/null 2>&1; then
      ub_turn_fail RETRYABLE "no result payload for job $jobid (timeout ${timeout_ms}ms?)" "$jobid"
      return 1
    fi

    status="$(printf '%s' "$res_json" | jq -r '.storedJob.result.status // 1')"
    raw="$(printf '%s' "$res_json" | jq -r '.storedJob.result.rawOutput // ""')"
    thread="$(printf '%s' "$res_json" | jq -r '.storedJob.result.threadId // .job.threadId // ""')"
    csid="$(printf '%s' "$res_json" | jq -r '.job.sessionId // .storedJob.sessionId // ""')"

    # E12: a threadId on a failed turn is not a usable thread — discard it.
    if [ "$status" != "0" ] || [ -z "$(printf '%s' "$raw" | tr -d '[:space:]')" ]; then
      local summary; summary="$(printf '%s' "$res_json" | jq -r '.job.summary // "no output"' | head -c 300)"

      # Account refused this model (recognised shape: 400 + invalid_request_error
      # + the model named). Explicit choices stop the run; preference-list
      # choices fall forward once.
      if [ -n "$model" ] && ub_is_model_refusal "$res_json" "$model"; then
        if [ "$model_origin" = "explicit" ]; then
          ub_turn_fail FATAL "model '$model' was refused by this account: $summary — alternatives: $UB_MODEL_PREFERENCE" "$jobid"
          return 1
        fi
        local next
        next="$(ub_next_model "$model")"
        if [ -z "$next" ] || [ "$probe_used" = 1 ]; then
          ub_turn_fail FATAL "every candidate model was refused (tried up to '$model'): $summary" "$jobid"
          return 1
        fi
        if ! cmd_session_write "$sd" "$(jq -n -c --arg f "$model" --arg t "$next" --arg r "$summary" \
          '{model:$t, modelDowngraded:{from:$f, to:$t, reason:$r}}')" >/dev/null; then
          ub_turn_fail FATAL "model downgrade to '$next' could not be recorded in session.json; aborting rather than running on an unrecorded model" "$jobid"
          return 1
        fi
        model_downgrade="$(jq -n -c --arg f "$model" --arg t "$next" '{from:$f, to:$t}')"
        model="$next"
        probe_used=1
        continue
      fi

      # A 400 we do not recognise, on a preference-list model: one bounded probe
      # of the next candidate (plan E5), recorded, never a loop.
      if [ -n "$model" ] && [ "$model_origin" != "explicit" ] && [ "$probe_used" = 0 ] &&
        ub_is_unknown_400 "$res_json"; then
        local next2
        next2="$(ub_next_model "$model")"
        if [ -n "$next2" ]; then
          if ! cmd_session_write "$sd" "$(jq -n -c --arg f "$model" --arg t "$next2" --arg r "$summary" \
            '{model:$t, modelSelectionUnknown:{from:$f, to:$t, rawError:$r}}')" >/dev/null; then
            ub_turn_fail FATAL "model probe to '$next2' could not be recorded in session.json" "$jobid"
            return 1
          fi
          model_downgrade="$(jq -n -c --arg f "$model" --arg t "$next2" '{from:$f, to:$t, unknownShape:true}')"
          model="$next2"
          probe_used=1
          continue
        fi
      fi

      ub_turn_fail RETRYABLE "codex returned status=$status with empty output: $summary" "$jobid"
      return 1
    fi

    # Continuity: thread and Codex session must match once known (INV-CONT-1).
    if [ -n "$prev_thread" ] && [ -n "$thread" ] && [ "$prev_thread" != "$thread" ]; then
      ub_turn_fail CONTINUITY "threadId changed: expected $prev_thread got $thread" "$jobid"
      return 1
    fi
    if [ -n "$prev_cs" ] && [ -n "$csid" ] && [ "$prev_cs" != "$csid" ]; then
      ub_turn_fail CONTINUITY "codex sessionId changed: expected $prev_cs got $csid" "$jobid"
      return 1
    fi
    break
  done

  local outfile="$sd/$label.output.md"
  printf '%s\n' "$raw" > "$outfile"

  # The validation artifact is a HARD GATE (plan A9): after every validation
  # attempt the artifact must exist and parse as JSON with a boolean .ok, or the
  # turn fails — a broken validator can never read as success (defect S2).
  ub_validation_usable() {
    jq -e '.ok | type == "boolean"' "$1" >/dev/null 2>&1
  }
  ub_validation_gate() {
    # $1 = validation file, $2 = stderr file
    ub_validation_usable "$1" && return 0
    ub_turn_fail FORMAT "validation artifact missing or unreadable — validator error: $(head -c 300 "$2" 2>/dev/null)" "$jobid" "$attempts" "$format_repair" '{"validationUnreadable":true}'
    return 1
  }

  # FORMAT policy: one bounded repair turn on the same thread (INV-FORMAT-1).
  if [ -n "$contract" ]; then
    local vfile="$sd/$label.validation.json" verr="$sd/$label.validation.err"
    if ! ub_validate --contract "$contract" --input "$outfile" > "$vfile" 2>"$verr"; then
      ub_validation_gate "$vfile" "$verr" || return 1
      if [ -n "$repair_tpl" ] && [ -r "$repair_tpl" ]; then
        local pre="$sd/$label.pre-repair.md"
        mv -f "$outfile" "$pre"
        local repair_prompt="$sd/$label.repair-prompt.md"
        ub_render_repair "$repair_tpl" "$contract" "$pre" "$v_round" > "$repair_prompt"
        local rj rjob rres rraw rstatus rthread rcs
        rj="$(ub_launch resume "$repair_prompt")"
        if printf '%s' "$rj" | jq -e .jobId >/dev/null 2>&1; then
          rjob="$(printf '%s' "$rj" | jq -r .jobId)"
          rres="$(ub_collect "$rjob")"
          attempts=$((attempts + 1))
          format_repair=true
          # The repair turn gets the same guards as the main turn (plan A10 /
          # defect S3): payload present, output non-empty, continuity intact.
          if ! printf '%s' "$rres" | jq -e '.storedJob.result' >/dev/null 2>&1; then
            ub_turn_fail RETRYABLE "repair turn produced no result payload (timeout ${timeout_ms}ms?)" "$rjob" "$attempts" true
            return 1
          fi
          rstatus="$(printf '%s' "$rres" | jq -r '.storedJob.result.status // 1')"
          rraw="$(printf '%s' "$rres" | jq -r '.storedJob.result.rawOutput // ""')"
          rthread="$(printf '%s' "$rres" | jq -r '.storedJob.result.threadId // .job.threadId // ""')"
          rcs="$(printf '%s' "$rres" | jq -r '.job.sessionId // .storedJob.sessionId // ""')"
          if [ "$rstatus" != "0" ] || [ -z "$(printf '%s' "$rraw" | tr -d '[:space:]')" ]; then
            ub_turn_fail RETRYABLE "repair turn failed with status=$rstatus and empty output" "$rjob" "$attempts" true
            return 1
          fi
          if [ -n "$thread" ] && [ -n "$rthread" ] && [ "$thread" != "$rthread" ]; then
            ub_turn_fail CONTINUITY "repair turn landed on a different thread: expected $thread got $rthread" "$rjob" "$attempts" true
            return 1
          fi
          if [ -n "$csid" ] && [ -n "$rcs" ] && [ "$csid" != "$rcs" ]; then
            ub_turn_fail CONTINUITY "repair turn ran in a different codex session: expected $csid got $rcs" "$rjob" "$attempts" true
            return 1
          fi
          printf '%s\n' "$rraw" > "$outfile"
          if ! ub_validate --contract "$contract" --input "$outfile" --baseline "$pre" > "$vfile" 2>"$verr"; then
            ub_validation_gate "$vfile" "$verr" || return 1
            ub_turn_fail FORMAT "output still invalid after one repair turn: $(jq -r '.errors | join("; ")' "$vfile" 2>/dev/null)" "$jobid" "$attempts" true
            return 1
          fi
        else
          ub_turn_fail FORMAT "malformed output and repair turn could not be launched" "$jobid" "$attempts"
          return 1
        fi
      else
        ub_turn_fail FORMAT "output failed validation: $(jq -r '.errors | join("; ")' "$vfile" 2>/dev/null)" "$jobid" "$attempts"
        return 1
      fi
    else
      ub_validation_gate "$vfile" "$verr" || return 1
    fi
  fi

  # Record the validated turn mechanically (plan A3): the resume predicate for
  # the NEXT turn reads these fields, so they must be written by the code that
  # validated the turn, not left to the caller's discipline. Best-effort: a
  # recording failure surfaces in the result rather than failing a valid turn.
  local recorded=true
  cmd_session_write "$sd" "$(jq -n -c --arg l "$label" --arg t "$thread" --arg cs "$csid" \
    '{lastTurnLabel:$l, threadId:$t, codexSessionId:$cs}')" >/dev/null 2>&1 || recorded=false

  jq -n --arg jid "$jobid" --arg t "$thread" --arg cs "$csid" --arg of "$outfile" \
    --arg m "${model:-}" --arg rr "${resume_refused:-}" \
    --argjson at "$attempts" --argjson fr "$format_repair" \
    --argjson md "$model_downgrade" --argjson rec "$recorded" \
    '{ok:true, failureClass:null, jobId:$jid, threadId:$t, codexSessionId:$cs,
      outputFile:$of, attempts:$at, formatRepair:$fr,
      model:(if $m=="" then null else $m end),
      modelDowngraded:$md,
      resumeRefused:(if $rr=="" then null else $rr end),
      sessionRecorded:$rec, message:null}'
  return 0
}

ub_turn_fail() {
  local class="$1" msg="$2" jobid="${3:-}" attempts="${4:-1}" repaired="${5:-false}" extra="${6:-}"
  [ -n "$extra" ] || extra='{}'
  # $model / $model_downgrade / $resume_refused come from the calling turn's
  # scope (bash dynamic scoping); default them so direct calls stay valid.
  jq -n --arg c "$class" --arg m "$msg" --arg j "$jobid" \
    --arg mo "${model:-}" --arg rr "${resume_refused:-}" \
    --argjson a "$attempts" --argjson r "$repaired" \
    --argjson md "${model_downgrade:-null}" --argjson x "$extra" \
    '{ok:false, failureClass:$c, jobId:(if $j=="" then null else $j end), threadId:null,
      codexSessionId:null, outputFile:null, attempts:$a, formatRepair:$r,
      model:(if $mo=="" then null else $mo end),
      modelDowngraded:$md,
      resumeRefused:(if $rr=="" then null else $rr end),
      message:$m} + $x'
}

# Render the fixed repair template with exactly three slots (INV-FORMAT-1).
# Only the body between the last pair of ``` fences is sent — the template's
# own explanatory prose never reaches the model.
ub_render_repair() {
  local tpl="$1" contract="$2" offending="$3" round="${4:-0}"
  local headers cats lines body
  # The header list follows the round (INV-SWEEP-1 / INV-ADMIT-1); the template
  # itself stays fixed with its three slots (INV-FORMAT-1).
  case "$round" in
    1) headers='## CATEGORY SCORES, ## EDGE CASE SWEEP, ## CRITIQUES, ## STRENGTHS, ## VERDICT' ;;
    0|'') headers='## CATEGORY SCORES, ## CRITIQUES, ## STRENGTHS, ## VERDICT' ;;
    *) headers='## CATEGORY SCORES, ## CRITIQUES, ## NOTES, ## STRENGTHS, ## VERDICT' ;;
  esac
  cats="$(jq -r '.categories[] | "- \(.name): {0-\(.weight)}"' "$contract")"
  lines="$(head -c 4000 "$offending")"
  body="$(awk '/^```$/{n++; next} n==1{print}' "$tpl")"

  # Substitution is done in pure bash, not awk/sed, for two reasons:
  #   - macOS awk rejects multi-line values passed with -v ("newline in string")
  #     and both CATEGORY_LIST and OFFENDING_OUTPUT are multi-line;
  #   - sed/awk replacement text treats & and \1 specially, and category names
  #     contain & ("Gate & safety integrity").
  # The heredoc always ends with a newline, so plain `read` sees every line;
  # multi-line slot values get the same [ -n ] guards in every branch.
  local line pre post
  while IFS= read -r line; do
    case "$line" in
      *'{EXPECTED_HEADERS}'*)
        pre="${line%%\{EXPECTED_HEADERS\}*}"
        post="${line#*\{EXPECTED_HEADERS\}}"
        printf '%s%s%s\n' "$pre" "$headers" "$post"
        ;;
      *'{CATEGORY_LIST}'*)
        pre="${line%%\{CATEGORY_LIST\}*}"
        post="${line#*\{CATEGORY_LIST\}}"
        [ -n "$pre" ] && printf '%s\n' "$pre"
        printf '%s\n' "$cats"
        [ -n "$post" ] && printf '%s\n' "$post"
        ;;
      *'{OFFENDING_OUTPUT}'*)
        pre="${line%%\{OFFENDING_OUTPUT\}*}"
        post="${line#*\{OFFENDING_OUTPUT\}}"
        [ -n "$pre" ] && printf '%s\n' "$pre"
        printf '%s\n' "$lines"
        [ -n "$post" ] && printf '%s\n' "$post"
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <<EOF
$body
EOF
  # The trailing conditionals above can leave $? = 1 on an empty segment; the
  # render itself succeeded.
  return 0
}

cmd_render_repair() {
  local tpl="" contract="" offending=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --template) tpl="$2"; shift 2 ;;
      --contract) contract="$2"; shift 2 ;;
      --offending) offending="$2"; shift 2 ;;
      *) echo "render-repair: unknown arg $1" >&2; return 2 ;;
    esac
  done
  [ -r "$tpl" ] && [ -r "$contract" ] && [ -r "$offending" ] || {
    echo "render-repair: --template, --contract and --offending must all be readable" >&2
    return 2
  }
  ub_render_repair "$tpl" "$contract" "$offending"
}

# --- gate --------------------------------------------------------------------

cmd_gate_arm() {
  local run_id="${1:?runId required}"
  local d; d="$(ub_state_dir)" || return 1
  ub_check_state_dir "$d" || return 1
  local h; h="$(ub_gate_hash "$run_id")"
  local lock="$d/gate-$h.lock" conf="$d/gate-$h.confirmed"
  local code; code="$(uuidgen)"
  local payload
  payload="$(jq -n --arg r "$run_id" --arg root "$(ub_repo_root)" --arg now "$(ub_now)" \
    --arg code "$code" --arg pid "$$" --arg ps "$(ub_pid_start $$)" \
    '{runId:$r, repoRoot:$root, createdAt:$now, unlockCode:$code, pid:($pid|tonumber), pidStart:$ps}')"
  if ! (set -C; printf '%s\n' "$payload" > "$lock") 2>/dev/null; then
    echo "gate-arm: an active gate already exists for this repo: $lock" >&2
    echo "Resolve or clear it first: rm $lock $conf" >&2
    return 1
  fi
  # Remove any stale confirmation only AFTER the lock write succeeded (defect
  # S1): deleting it first meant a failed re-arm destroyed the previous run's
  # confirmation while its lock stayed live — an instant lockout.
  [ -e "$conf" ] && rm -f "$conf"
  ub_gate_log arm "$run_id" "lock created"
  jq -n --arg l "$lock" --arg c "$code" --arg r "$run_id" '{lock:$l, unlockCode:$c, runId:$r}'
}

cmd_gate_confirm() {
  local d; d="$(ub_state_dir)" || return 1
  local lock; lock="$(ub_gate_lock_path)"
  [ -n "$lock" ] || { echo "gate-confirm: no valid lock for this repo" >&2; return 1; }
  local conf="${lock%.lock}.confirmed"
  ub_check_state_dir "$d" || return 1
  ub_check_leaf "$lock" || { echo "gate-confirm: no valid lock for this repo" >&2; return 1; }
  local rid code
  rid="$(jq -re '.runId' "$lock" 2>/dev/null)" || { echo "gate-confirm: lock unreadable" >&2; return 1; }
  code="$(jq -re '.unlockCode' "$lock" 2>/dev/null)" || { echo "gate-confirm: lock unreadable" >&2; return 1; }
  [ -e "$conf" ] && { echo "gate-confirm: confirmation already exists" >&2; return 1; }
  local payload
  payload="$(jq -n --arg r "$rid" --arg c "$code" '{runId:$r, unlockCode:$c}')"
  (set -C; printf '%s\n' "$payload" > "$conf") 2>/dev/null || {
    echo "gate-confirm: could not create confirmation file" >&2
    return 1
  }
  ub_gate_log confirm "$rid" "gate cleared"
  printf 'gate cleared for run %s\n' "$rid"
}

cmd_gate_status() {
  ub_state_dir >/dev/null || return 1
  local lock; lock="$(ub_gate_lock_path)"
  local conf="${lock%.lock}.confirmed"
  if [ -z "$lock" ] || [ ! -e "$lock" ]; then
    jq -n '{active:false}'
    return 0
  fi
  local rid created pid pidstart alive="unknown"
  rid="$(jq -r '.runId // ""' "$lock" 2>/dev/null)"
  created="$(jq -r '.createdAt // ""' "$lock" 2>/dev/null)"
  pid="$(jq -r '.pid // empty' "$lock" 2>/dev/null)"
  pidstart="$(jq -r '.pidStart // ""' "$lock" 2>/dev/null)"
  # Advisory only (C3): never an authorization input.
  if [ -n "$pid" ]; then
    if kill -0 "$pid" 2>/dev/null && [ "$(ub_pid_start "$pid")" = "$pidstart" ]; then alive="yes"; else alive="no"; fi
  fi
  jq -n --arg r "$rid" --arg c "$created" --arg a "$alive" --arg l "$lock" \
    --argjson confirmed "$([ -e "$conf" ] && echo true || echo false)" \
    '{active:true, runId:$r, createdAt:$c, ownerAliveAdvisory:$a, confirmed:$confirmed, lock:$l}'
}

cmd_gate_clear() {
  ub_state_dir >/dev/null || return 1
  # Non-git CWDs can hold several per-run locks; clear every lock scoped to
  # this CWD, not just the first match.
  local lock cleared=0
  while :; do
    lock="$(ub_gate_lock_path)"
    [ -n "$lock" ] && [ -e "$lock" ] || break
    rm -f "$lock" "${lock%.lock}.confirmed"
    cleared=$((cleared + 1))
  done
  ub_gate_log clear "-" "operator cleared ($cleared lock(s))"
  printf 'gate cleared\n'
}

ub_gate_log() {
  local d; d="$(ub_state_dir 2>/dev/null)" || return 0
  # One JSON object per line, SAME five keys as the gate hook's writer (defect
  # S4: two writers, one file, one schema). `tool` is null here — utils calls
  # are not tool interceptions.
  jq -n -c --arg ts "$(ub_now)" --arg ev "$1" --arg run "$2" --arg detail "$3" --arg repo "$(ub_repo_root)" \
    '{ts:$ts, event:$ev, runId:(if $run == "" or $run == "-" then null else $run end), repo:$repo, tool:null, detail:$detail}' >> "$d/gate.log" 2>/dev/null || true
}

# --- cleanup -----------------------------------------------------------------

ub_session_dirs() {
  local d; d="$(ub_state_dir)" || return 1
  # Exact paths only, never a glob passed to rm (C5).
  find "$d" -maxdepth 1 -type d -name 'session-*' 2>/dev/null
}

ub_is_completed() {
  local dir="$1"
  [ -f "$dir/completed" ] && return 0
  # /tmp reapers can delete the marker; session.json is authoritative (bug #9).
  [ -f "$dir/session.json" ] && [ "$(jq -r '.completed // false' "$dir/session.json" 2>/dev/null)" = "true" ] && return 0
  return 1
}

cmd_cleanup_completed() {
  # Sessions are moved to the trash (ULTRABLITZ_TRASH_DIR, default ~/.Trash),
  # never rm'd: a completed debate log is cheap to keep and impossible to
  # regenerate.
  local n=0 failed=0 dir
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    if ub_is_completed "$dir"; then
      if ub_trash "$dir" >/dev/null; then
        n=$((n + 1))
      else
        # Never report success over a failed move (defect S9).
        echo "cleanup-completed: could not trash $dir" >&2
        printf '%s trash failed\n' "$(ub_now)" >> "$dir/cleanup.error" 2>/dev/null || true
        failed=$((failed + 1))
      fi
    fi
  done < <(ub_session_dirs)
  printf 'Trashed %d completed session(s)\n' "$n"
  [ "$failed" -gt 0 ] && { printf '%d session(s) could not be trashed (see stderr)\n' "$failed"; return 1; }
  return 0
}

cmd_trash_session() {
  # trash-session <session-dir>: move ONE exact session directory to the trash.
  # Refuses anything that is not a session dir inside our state dir.
  local dir="${1:?session dir required}"
  local d; d="$(ub_state_dir)" || return 1
  dir="${dir%/}"
  case "$dir" in
    "$d"/session-*) : ;;
    *) echo "trash-session: refusing path outside the state dir: $dir" >&2; return 2 ;;
  esac
  [ -d "$dir" ] || { echo "trash-session: no such session: $dir" >&2; return 1; }
  [ -L "$dir" ] && { echo "trash-session: refusing symlink: $dir" >&2; return 2; }
  local dst
  dst="$(ub_trash "$dir")" || { echo "trash-session: could not move $dir" >&2; return 1; }
  printf 'Trashed: %s -> %s\n' "$dir" "$dst"
}

cmd_cleanup_list() {
  local n=0 dir
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    ub_is_completed "$dir" && continue
    n=$((n + 1))
    if [ -f "$dir/session.json" ]; then
      jq -r --arg d "$dir" '"Session: \(.runId // "?") | Created: \(.createdAt // "?") | Phase: \(.phase // "?") Round: \(.round // "?") | Path: \($d)"' "$dir/session.json" 2>/dev/null \
        || printf 'Session: %s | Path: %s\n' "$(basename "$dir")" "$dir"
    else
      printf 'Session: %s | Path: %s\n' "$(basename "$dir")" "$dir"
    fi
    printf '  trash with: bash %s trash-session %s\n' "$0" "$dir"
  done < <(ub_session_dirs)
  [ "$n" -eq 0 ] && printf 'No incomplete sessions found\n'
  return 0
}

# --- active-run lock ---------------------------------------------------------

cmd_run_lock() {
  local run_id="${1:?runId required}" force="${2:-}"
  local d; d="$(ub_state_dir)" || return 1
  local h; h="$(ub_repo_hash)"
  local lock="$d/active-$h.lock"
  if [ -e "$lock" ]; then
    local pid ps
    pid="$(jq -r '.ownerPid // empty' "$lock" 2>/dev/null)"
    ps="$(jq -r '.ownerPidStart // ""' "$lock" 2>/dev/null)"
    local dead=1
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$(ub_pid_start "$pid")" = "$ps" ]; then dead=0; fi
    if [ "$dead" = "0" ] && [ "$force" != "--force-new" ]; then
      echo "run-lock: another ultrablitz run is active in this repo (pid $pid). Use --force-new to override." >&2
      return 1
    fi
    rm -f "$lock"
  fi
  jq -n --arg r "$run_id" --arg pid "$$" --arg ps "$(ub_pid_start $$)" \
    '{runId:$r, ownerPid:($pid|tonumber), ownerPidStart:$ps}' > "$lock"
  printf '%s\n' "$lock"
}

cmd_run_unlock() {
  local d; d="$(ub_state_dir)" || return 1
  rm -f "$d/active-$(ub_repo_hash).lock"
  printf 'run lock released\n'
}

# --- dispatch ----------------------------------------------------------------

SUB="${1:-}"
[ $# -gt 0 ] && shift
case "$SUB" in
  doctor) cmd_doctor "$@" ;;
  resolve-companion) ub_resolve_companion ;;
  resolve-model) cmd_resolve_model "$@" ;;
  repo-hash) ub_repo_hash ;;
  state-dir) ub_state_dir ;;
  session-new) cmd_session_new "$@" ;;
  session-read) cmd_session_read "$@" ;;
  session-write) cmd_session_write "$@" ;;
  validate-output) cmd_validate_output "$@" ;;
  render-contract) cmd_render_contract "$@" ;;
  render-repair) cmd_render_repair "$@" ;;
  codex-turn) cmd_codex_turn "$@" ;;
  gate-arm) cmd_gate_arm "$@" ;;
  gate-confirm) cmd_gate_confirm "$@" ;;
  gate-status) cmd_gate_status "$@" ;;
  gate-clear) cmd_gate_clear "$@" ;;
  run-lock) cmd_run_lock "$@" ;;
  run-unlock) cmd_run_unlock "$@" ;;
  cleanup-completed) cmd_cleanup_completed "$@" ;;
  cleanup-list) cmd_cleanup_list "$@" ;;
  trash-session) cmd_trash_session "$@" ;;
  *)
    cat >&2 <<'EOF'
ultrablitz-utils.sh: unknown subcommand
Usage: ultrablitz-utils.sh <subcommand> [args]
  doctor [--json] | resolve-companion | resolve-model | repo-hash | state-dir
  session-new | session-read <dir> | session-write <dir> <json-patch>
  validate-output --contract <f> --input <f> [--baseline <f>] [--round N] [--last-id N] [--confirm-only]
  render-contract --contract <f> --round N [--part contract|surface]
  codex-turn --session <dir> --prompt-file <f> [--resume] [--timeout-ms N]
             [--contract <f>] [--repair-template <f>] [--label L]
             [--round N] [--last-id N] [--confirm-only]
  gate-arm <runId> | gate-confirm | gate-status | gate-clear
  run-lock <runId> [--force-new] | run-unlock
  cleanup-completed | cleanup-list | trash-session <session-dir>
EOF
    exit 1
    ;;
esac
