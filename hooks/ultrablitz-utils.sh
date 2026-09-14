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
#   gate-arm               create the post-debate confirmation lock
#   gate-confirm           clear the gate with the unlock code
#   gate-status            report lock state for this repo
#   cleanup-completed      remove completed sessions (exact paths, no glob rm)
#   cleanup-list           list incomplete sessions with their rm commands
set -uo pipefail

UB_VERSION="6.0.0"

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
  local json=0 fail=0
  [ "${1:-}" = "--json" ] && json=1
  local -a checks=()

  add() { checks+=("$(jq -n --arg n "$1" --arg s "$2" --arg d "$3" '{name:$n,status:$s,detail:$d}')"); [ "$2" = "fail" ] && fail=1; return 0; }

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

  local out
  out="$(printf '%s\n' "${checks[@]}" | jq -s --arg v "$UB_VERSION" '{version:$v, ok: (map(select(.status=="fail")) | length == 0), checks: .}')"
  if [ "$json" = "1" ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out" | jq -r '.checks[] | "\(.status | ascii_upcase | .[0:4]) \(.name): \(.detail)"'
    printf '%s\n' "$out" | jq -r 'if .ok then "doctor: PASS" else "doctor: FAIL" end'
  fi
  [ "$fail" = "1" ] && return 1
  return 0
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
      ledger:[], scores:[], planPath:null, degraded:{reason:null}, authoritative:true,
      completed:false}' > "$sd/session.json.tmp" || return 1
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
    jq --arg m "$mine" '. + {foreign:true, foreignDetail:("owned by Claude session " + .claudeSessionId + ", current is " + $m)}' "$sd/session.json"
  else
    jq '. + {foreign:false}' "$sd/session.json"
  fi
}

# session-write <dir> <json-patch>   (shallow merge, atomic)
cmd_session_write() {
  local sd="${1:?session dir required}" patch="${2:?json patch required}"
  ub_check_leaf "$sd/session.json" || return 1
  printf '%s' "$patch" | jq -e . >/dev/null 2>&1 || {
    echo "session-write: patch is not valid JSON" >&2
    return 1
  }
  local tmp="$sd/session.json.tmp"
  jq --argjson p "$patch" --arg now "$(ub_now)" '. * $p * {lastActiveAt:$now}' "$sd/session.json" > "$tmp" || return 1
  # Only publish a complete file: jq wrote to tmp, rename is atomic.
  mv -f "$tmp" "$sd/session.json" || return 1
  printf 'ok\n'
}

# --- output validation -------------------------------------------------------
# validate-output --contract <framework.json> --input <file> [--baseline <file>]
# framework.json: {"categories":[{"name":..,"weight":N}..],"max":N}
cmd_validate_output() {
  local contract="" input="" baseline=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --contract) contract="$2"; shift 2 ;;
      --input) input="$2"; shift 2 ;;
      --baseline) baseline="$2"; shift 2 ;;
      *) echo "validate-output: unknown arg $1" >&2; return 2 ;;
    esac
  done
  [ -r "$contract" ] || { echo "validate-output: contract unreadable" >&2; return 2; }
  [ -r "$input" ] || { echo "validate-output: input unreadable" >&2; return 2; }

  local errors=() body
  body="$(cat "$input")"

  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || errors+=("output is empty")

  local h
  for h in "## CATEGORY SCORES" "## CRITIQUES" "## STRENGTHS" "## VERDICT"; do
    printf '%s' "$body" | grep -qF "$h" || errors+=("missing section header: $h")
  done

  # Parse "- Name: 12" lines from the CATEGORY SCORES block.
  local parsed
  parsed="$(printf '%s\n' "$body" | awk '
    /^## CATEGORY SCORES/ {inblk=1; next}
    /^## / {inblk=0}
    inblk && /^[[:space:]]*-[[:space:]]*.+:[[:space:]]*-?[0-9]+[[:space:]]*$/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      idx=match(line, /:[[:space:]]*-?[0-9]+[[:space:]]*$/)
      name=substr(line, 1, idx-1)
      score=substr(line, idx+1)
      gsub(/[^0-9-]/, "", score)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      printf "%s\t%s\n", name, score
    }')"

  local names_json scores_json
  names_json="$(printf '%s\n' "$parsed" | awk -F'\t' 'NF==2{print $1}' | jq -R . | jq -s .)"
  scores_json="$(printf '%s\n' "$parsed" | awk -F'\t' 'NF==2{printf "{\"name\":\"%s\",\"score\":%s}\n", $1, $2}' | jq -s .)"
  [ -z "$parsed" ] && { names_json='[]'; scores_json='[]'; }

  # Exact category-key match against the locked framework (case-insensitive).
  local want_json
  want_json="$(jq -c '[.categories[].name]' "$contract")"
  local cmp
  cmp="$(jq -n --argjson got "$names_json" --argjson want "$want_json" '
    def norm: ascii_downcase | gsub("^\\s+|\\s+$";"");
    {missing: ($want | map(select(. as $w | ($got | map(norm) | index($w|norm)) == null))),
     extra:   ($got  | map(select(. as $g | ($want | map(norm) | index($g|norm)) == null))),
     dupes:   ($got  | map(norm) | group_by(.) | map(select(length>1) | .[0]))}')"
  local missing extra dupes
  missing="$(printf '%s' "$cmp" | jq -r '.missing | join(", ")')"
  extra="$(printf '%s' "$cmp" | jq -r '.extra | join(", ")')"
  dupes="$(printf '%s' "$cmp" | jq -r '.dupes | join(", ")')"
  [ -n "$missing" ] && errors+=("missing categories: $missing")
  [ -n "$extra" ] && errors+=("unexpected categories: $extra")
  [ -n "$dupes" ] && errors+=("duplicate categories: $dupes")

  # Bounds: 0 <= score <= that category's weight.
  local oob
  oob="$(jq -rn --argjson got "$scores_json" --slurpfile c "$contract" '
    def norm: ascii_downcase | gsub("^\\s+|\\s+$";"");
    ($c[0].categories | map({key:(.name|norm), value:.weight}) | from_entries) as $w
    | $got | map(select((.score < 0) or ($w[(.name|norm)] != null and .score > $w[(.name|norm)])))
    | map("\(.name)=\(.score)") | join(", ")')"
  [ -n "$oob" ] && errors+=("category score out of bounds: $oob")

  # Each critique needs Evidence / Impact / Suggestion.
  local ncrit nev nim nsug
  ncrit="$(printf '%s\n' "$body" | awk '/^## CRITIQUES/{i=1;next} /^## /{i=0} i && /^[[:space:]]*[0-9]+\./{n++} END{print n+0}')"
  nev="$(printf '%s\n' "$body" | grep -c '^[[:space:]]*-[[:space:]]*Evidence:' || true)"
  nim="$(printf '%s\n' "$body" | grep -c '^[[:space:]]*-[[:space:]]*Impact:' || true)"
  nsug="$(printf '%s\n' "$body" | grep -c '^[[:space:]]*-[[:space:]]*Suggestion:' || true)"
  if [ "$ncrit" -gt 0 ]; then
    [ "$nev" -ge "$ncrit" ] || errors+=("$ncrit critiques but $nev Evidence fields")
    [ "$nim" -ge "$ncrit" ] || errors+=("$ncrit critiques but $nim Impact fields")
    [ "$nsug" -ge "$ncrit" ] || errors+=("$ncrit critiques but $nsug Suggestion fields")
  fi

  # Repair substance check (INV-FORMAT-1): scores and critique count must match
  # whatever was parseable pre-repair.
  if [ -n "$baseline" ] && [ -r "$baseline" ]; then
    local b_scores b_ncrit
    b_scores="$(printf '%s\n' "$(cat "$baseline")" | awk '
      /^## CATEGORY SCORES/ {inblk=1; next} /^## / {inblk=0}
      inblk && /^[[:space:]]*-[[:space:]]*.+:[[:space:]]*-?[0-9]+[[:space:]]*$/ {
        line=$0; sub(/^[[:space:]]*-[[:space:]]*/, "", line)
        idx=match(line, /:[[:space:]]*-?[0-9]+[[:space:]]*$/)
        score=substr(line, idx+1); gsub(/[^0-9-]/, "", score); printf "%s\n", score
      }' | tr '\n' ',')"
    local n_scores
    n_scores="$(printf '%s' "$scores_json" | jq -r '[.[].score] | join(",")'),"
    if [ -n "$(printf '%s' "$b_scores" | tr -d ,)" ] && [ "$b_scores" != "$n_scores" ]; then
      errors+=("repair changed scores: was [${b_scores%,}] now [${n_scores%,}]")
    fi
    b_ncrit="$(printf '%s\n' "$(cat "$baseline")" | awk '/^## CRITIQUES/{i=1;next} /^## /{i=0} i && /^[[:space:]]*[0-9]+\./{n++} END{print n+0}')"
    if [ "$b_ncrit" -gt 0 ] && [ "$b_ncrit" != "$ncrit" ]; then
      errors+=("repair changed critique count: was $b_ncrit now $ncrit")
    fi
  fi

  local errs_json
  if [ ${#errors[@]} -eq 0 ]; then errs_json='[]'; else
    errs_json="$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)"
  fi
  jq -n --argjson errs "$errs_json" --argjson cats "$scores_json" --argjson n "$ncrit" \
    '{ok: (($errs | length) == 0), errors:$errs, categories:$cats, critiqueCount:$n,
      total: ($cats | map(.score) | add // 0)}'
  [ ${#errors[@]} -eq 0 ] || return 1
  return 0
}

# --- codex turn --------------------------------------------------------------
# codex-turn --session <dir> --prompt-file <f> [--resume] [--timeout-ms N]
#            [--contract <framework.json>] [--repair-template <f>] [--label L]
# Prints ONE json object: {ok, failureClass, jobId, threadId, codexSessionId,
#                          outputFile, attempts, formatRepair, message}
cmd_codex_turn() {
  local sd="" pf="" resume=0 timeout_ms=300000 contract="" repair_tpl="" label="turn"
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) sd="$2"; shift 2 ;;
      --prompt-file) pf="$2"; shift 2 ;;
      --resume) resume=1; shift ;;
      --timeout-ms) timeout_ms="$2"; shift 2 ;;
      --contract) contract="$2"; shift 2 ;;
      --repair-template) repair_tpl="$2"; shift 2 ;;
      --label) label="$2"; shift 2 ;;
      *) echo "codex-turn: unknown arg $1" >&2; return 2 ;;
    esac
  done
  [ -d "$sd" ] || { echo "codex-turn: session dir required" >&2; return 2; }
  [ -r "$pf" ] || { echo "codex-turn: prompt file unreadable" >&2; return 2; }

  local comp repo
  comp="$(ub_resolve_companion)" || { ub_turn_fail FATAL "companion not found"; return 1; }
  repo="$(ub_repo_root)"

  local prev_thread prev_cs
  prev_thread="$(jq -r '.threadId // empty' "$sd/session.json")"
  prev_cs="$(jq -r '.codexSessionId // empty' "$sd/session.json")"

  local attempts=0 format_repair=false

  ub_launch() {
    # Launch in background, return jobId on stdout.
    # No empty-array expansion: bash 3.2 (macOS /bin/bash) treats "${a[@]}" on an
    # empty array as an unbound variable under `set -u` and aborts the launch.
    if [ "$1" = "resume" ]; then
      node "$comp" task --json --background --cwd "$repo" --resume-last --prompt-file "$2" 2>"$sd/$label.launch.err"
    else
      node "$comp" task --json --background --cwd "$repo" --prompt-file "$2" 2>"$sd/$label.launch.err"
    fi
  }

  local launch_json jobid
  launch_json="$(ub_launch "$([ $resume = 1 ] && echo resume || echo fresh)" "$pf")"
  if ! printf '%s' "$launch_json" | jq -e .jobId >/dev/null 2>&1; then
    local err; err="$(cat "$sd/$label.launch.err" 2>/dev/null)"
    # "task still running" — this session's own job (E13: foreign jobs are
    # invisible to us, so there is no foreign branch).
    if printf '%s%s' "$launch_json" "$err" | grep -qi 'still running'; then
      local running
      running="$(node "$comp" status --json --cwd "$repo" 2>/dev/null | jq -r '.running[0].id // empty')"
      if [ -n "$running" ]; then
        node "$comp" status "$running" --wait --timeout-ms "$timeout_ms" --json --cwd "$repo" >/dev/null 2>&1
        launch_json="$(ub_launch "$([ $resume = 1 ] && echo resume || echo fresh)" "$pf")"
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

  ub_collect() {
    # wait then fetch; echoes the result JSON of storedJob.result plus sessionId
    node "$comp" status "$1" --wait --timeout-ms "$timeout_ms" --json --cwd "$repo" >"$sd/$label.status.json" 2>/dev/null
    node "$comp" result "$1" --json --cwd "$repo" 2>/dev/null
  }

  local res_json
  res_json="$(ub_collect "$jobid")"
  attempts=$((attempts + 1))

  if ! printf '%s' "$res_json" | jq -e '.storedJob.result' >/dev/null 2>&1; then
    ub_turn_fail RETRYABLE "no result payload for job $jobid (timeout ${timeout_ms}ms?)" "$jobid"
    return 1
  fi

  local status raw thread csid
  status="$(printf '%s' "$res_json" | jq -r '.storedJob.result.status // 1')"
  raw="$(printf '%s' "$res_json" | jq -r '.storedJob.result.rawOutput // ""')"
  thread="$(printf '%s' "$res_json" | jq -r '.storedJob.result.threadId // .job.threadId // ""')"
  csid="$(printf '%s' "$res_json" | jq -r '.job.sessionId // .storedJob.sessionId // ""')"

  # E12: a threadId on a failed turn is not a usable thread — discard it.
  if [ "$status" != "0" ] || [ -z "$(printf '%s' "$raw" | tr -d '[:space:]')" ]; then
    local summary; summary="$(printf '%s' "$res_json" | jq -r '.job.summary // "no output"' | head -c 300)"
    ub_turn_fail RETRYABLE "codex returned status=$status with empty output: $summary" "$jobid"
    return 1
  fi

  # Continuity: thread and Codex session must match once known.
  if [ -n "$prev_thread" ] && [ -n "$thread" ] && [ "$prev_thread" != "$thread" ]; then
    ub_turn_fail CONTINUITY "threadId changed: expected $prev_thread got $thread" "$jobid"
    return 1
  fi
  if [ -n "$prev_cs" ] && [ -n "$csid" ] && [ "$prev_cs" != "$csid" ]; then
    ub_turn_fail CONTINUITY "codex sessionId changed: expected $prev_cs got $csid" "$jobid"
    return 1
  fi

  local outfile="$sd/$label.output.md"
  printf '%s\n' "$raw" > "$outfile"

  # FORMAT policy: one bounded repair turn on the same thread (INV-FORMAT-1).
  if [ -n "$contract" ]; then
    if ! cmd_validate_output --contract "$contract" --input "$outfile" > "$sd/$label.validation.json" 2>/dev/null; then
      if [ -n "$repair_tpl" ] && [ -r "$repair_tpl" ]; then
        local pre="$sd/$label.pre-repair.md"
        mv -f "$outfile" "$pre"
        local repair_prompt="$sd/$label.repair-prompt.md"
        ub_render_repair "$repair_tpl" "$contract" "$pre" > "$repair_prompt"
        local rl rj rjob rres rraw
        rj="$(ub_launch resume "$repair_prompt")"
        if printf '%s' "$rj" | jq -e .jobId >/dev/null 2>&1; then
          rjob="$(printf '%s' "$rj" | jq -r .jobId)"
          rres="$(ub_collect "$rjob")"
          attempts=$((attempts + 1))
          format_repair=true
          rraw="$(printf '%s' "$rres" | jq -r '.storedJob.result.rawOutput // ""')"
          printf '%s\n' "$rraw" > "$outfile"
          if ! cmd_validate_output --contract "$contract" --input "$outfile" --baseline "$pre" > "$sd/$label.validation.json" 2>/dev/null; then
            ub_turn_fail FORMAT "output still invalid after one repair turn: $(jq -r '.errors | join("; ")' "$sd/$label.validation.json" 2>/dev/null)" "$jobid" "$attempts" true
            return 1
          fi
        else
          ub_turn_fail FORMAT "malformed output and repair turn could not be launched" "$jobid" "$attempts"
          return 1
        fi
      else
        ub_turn_fail FORMAT "output failed validation: $(jq -r '.errors | join("; ")' "$sd/$label.validation.json" 2>/dev/null)" "$jobid" "$attempts"
        return 1
      fi
    fi
  fi

  jq -n --arg jid "$jobid" --arg t "$thread" --arg cs "$csid" --arg of "$outfile" \
    --argjson at "$attempts" --argjson fr "$format_repair" \
    '{ok:true, failureClass:null, jobId:$jid, threadId:$t, codexSessionId:$cs,
      outputFile:$of, attempts:$at, formatRepair:$fr, message:null}'
  return 0
}

ub_turn_fail() {
  local class="$1" msg="$2" jobid="${3:-}" attempts="${4:-1}" repaired="${5:-false}"
  jq -n --arg c "$class" --arg m "$msg" --arg j "$jobid" --argjson a "$attempts" --argjson r "$repaired" \
    '{ok:false, failureClass:$c, jobId:(if $j=="" then null else $j end), threadId:null,
      codexSessionId:null, outputFile:null, attempts:$a, formatRepair:$r, message:$m}'
}

# Render the fixed repair template with exactly three slots (INV-FORMAT-1).
# Only the body between the last pair of ``` fences is sent — the template's
# own explanatory prose never reaches the model.
ub_render_repair() {
  local tpl="$1" contract="$2" offending="$3"
  local headers cats lines body
  headers='## CATEGORY SCORES, ## CRITIQUES, ## STRENGTHS, ## VERDICT'
  cats="$(jq -r '.categories[] | "- \(.name): {0-\(.weight)}"' "$contract")"
  lines="$(head -c 4000 "$offending")"
  body="$(awk '/^```$/{n++; next} n==1{print}' "$tpl")"

  # Substitution is done in pure bash, not awk/sed, for two reasons:
  #   - macOS awk rejects multi-line values passed with -v ("newline in string")
  #     and both CATEGORY_LIST and OFFENDING_OUTPUT are multi-line;
  #   - sed/awk replacement text treats & and \1 specially, and category names
  #     contain & ("Gate & safety integrity").
  local line pre post
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *'{EXPECTED_HEADERS}'*)
        pre="${line%%\{EXPECTED_HEADERS\}*}"
        post="${line#*\{EXPECTED_HEADERS\}}"
        printf '%s%s%s\n' "$pre" "$headers" "$post"
        ;;
      *'{CATEGORY_LIST}'*)
        pre="${line%%\{CATEGORY_LIST\}*}"
        post="${line#*\{CATEGORY_LIST\}}"
        printf '%s\n%s\n%s\n' "${pre%$'\n'}" "$cats" "$post" | sed '/^$/d'
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
  local h; h="$(ub_repo_hash)"
  local lock="$d/gate-$h.lock" conf="$d/gate-$h.confirmed"
  [ -e "$conf" ] && rm -f "$conf"
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
  ub_gate_log arm "$run_id" "lock created"
  jq -n --arg l "$lock" --arg c "$code" --arg r "$run_id" '{lock:$l, unlockCode:$c, runId:$r}'
}

cmd_gate_confirm() {
  local d; d="$(ub_state_dir)" || return 1
  local h; h="$(ub_repo_hash)"
  local lock="$d/gate-$h.lock" conf="$d/gate-$h.confirmed"
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
  local d; d="$(ub_state_dir)" || return 1
  local h; h="$(ub_repo_hash)"
  local lock="$d/gate-$h.lock" conf="$d/gate-$h.confirmed"
  if [ ! -e "$lock" ]; then
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
  local d; d="$(ub_state_dir)" || return 1
  local h; h="$(ub_repo_hash)"
  rm -f "$d/gate-$h.lock" "$d/gate-$h.confirmed"
  ub_gate_log clear "-" "operator cleared"
  printf 'gate cleared\n'
}

ub_gate_log() {
  local d; d="$(ub_state_dir 2>/dev/null)" || return 0
  # -c: one JSON object per line (JSON Lines, matching the gate hook's writer).
  jq -n -c --arg ts "$(ub_now)" --arg ev "$1" --arg run "$2" --arg detail "$3" --arg repo "$(ub_repo_root)" \
    '{ts:$ts, event:$ev, runId:$run, repo:$repo, detail:$detail}' >> "$d/gate.log" 2>/dev/null || true
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
  local n=0 dir
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    if ub_is_completed "$dir"; then
      rm -r "$dir" 2>/dev/null && n=$((n + 1))
    fi
  done < <(ub_session_dirs)
  printf 'Cleaned %d completed session(s)\n' "$n"
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
    printf '  delete with: rm -r %s\n' "$dir"
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
  version) printf '%s\n' "$UB_VERSION" ;;
  doctor) cmd_doctor "$@" ;;
  resolve-companion) ub_resolve_companion ;;
  repo-hash) ub_repo_hash ;;
  state-dir) ub_state_dir ;;
  session-new) cmd_session_new "$@" ;;
  session-read) cmd_session_read "$@" ;;
  session-write) cmd_session_write "$@" ;;
  validate-output) cmd_validate_output "$@" ;;
  render-repair) cmd_render_repair "$@" ;;
  codex-turn) cmd_codex_turn "$@" ;;
  gate-arm) cmd_gate_arm "$@" ;;
  gate-confirm) cmd_gate_confirm "$@" ;;
  gate-status) cmd_gate_status "$@" ;;
  gate-clear) cmd_gate_clear "$@" ;;
  run-lock) cmd_run_lock "$@" ;;
  run-unlock) cmd_run_unlock "$@" ;;
  cleanup-completed) cmd_cleanup_completed "$@" ;;
  cleanup-list | cleanup-interactive) cmd_cleanup_list "$@" ;;
  *)
    cat >&2 <<'EOF'
ultrablitz-utils.sh: unknown subcommand
Usage: ultrablitz-utils.sh <subcommand> [args]
  version | doctor [--json] | resolve-companion | repo-hash | state-dir
  session-new | session-read <dir> | session-write <dir> <json-patch>
  validate-output --contract <f> --input <f> [--baseline <f>]
  codex-turn --session <dir> --prompt-file <f> [--resume] [--timeout-ms N]
             [--contract <f>] [--repair-template <f>] [--label L]
  gate-arm <runId> | gate-confirm | gate-status | gate-clear
  run-lock <runId> [--force-new] | run-unlock
  cleanup-completed | cleanup-list
EOF
    exit 1
    ;;
esac
