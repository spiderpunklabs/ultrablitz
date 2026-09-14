#!/usr/bin/env bash
# Gate hook tests (plan D1 + Workstream C). The hook is fed JSON on STDIN,
# which is the real Claude Code contract — the old env-var path is gone.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

SANDBOX="$(new_sandbox)"
export ULTRABLITZ_STATE_DIR="$SANDBOX/state"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -m 700 -p "$ULTRABLITZ_STATE_DIR"

HASH="$(bash "$UTILS" repo-hash)"
LOCK="$ULTRABLITZ_STATE_DIR/gate-$HASH.lock"
CONF="$ULTRABLITZ_STATE_DIR/gate-$HASH.confirmed"
REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"

call() {
  # call <tool_name> [tool_input-json] -> hook stdout
  local tn="$1" ti="${2:-{\}}"
  jq -n --arg t "$tn" --argjson i "$ti" '{tool_name:$t, tool_input:$i}' | bash "$GATE" 2>/dev/null
}
decision() {
  # The hook is silent on allow (exit 0, no stdout).
  [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ] && { echo allow; return; }
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow
}
reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }

mklock() {
  # mklock [createdAt] [runId] [code]
  jq -n --arg r "${2:-run-1}" --arg root "$REPO" --arg c "${1:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
    --arg code "${3:-11111111-1111-1111-1111-111111111111}" --arg pid "$$" \
    '{runId:$r, repoRoot:$root, createdAt:$c, unlockCode:$code, pid:($pid|tonumber)}' > "$LOCK"
}

t "no lock: allows everything"
rm -f "$LOCK" "$CONF"
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$(decision "$out")" "allow"

t "active lock: denies Bash"
mklock
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$(decision "$out")" "deny"
t "denial names the confirm command"
assert_contains "$(reason "$out")" "gate-confirm"
t "active lock: denies Write"
out="$(call Write '{"file_path":"/tmp/x","content":"y"}')"
assert_eq "$(decision "$out")" "deny"
t "active lock: denies Edit"
out="$(call Edit '{"file_path":"/tmp/x"}')"
assert_eq "$(decision "$out")" "deny"

t "confirmation file with matching tokens clears the gate"
jq -n '{runId:"run-1", unlockCode:"11111111-1111-1111-1111-111111111111"}' > "$CONF"
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$(decision "$out")" "allow"

t "confirmation with a wrong unlock code is denied"
jq -n '{runId:"run-1", unlockCode:"deadbeef-0000-0000-0000-000000000000"}' > "$CONF"
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$(decision "$out")" "deny"
t "mismatched confirmation says so"
assert_contains "$(reason "$out")" "does not match"

t "malformed confirmation JSON is denied"
printf 'not json\n' > "$CONF"
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$(decision "$out")" "deny"
rm -f "$CONF"

# --- the carve-out that used to be dead code (bug #2) -----------------------
t "carve-out: the confirmation Write itself is allowed (bug #2)"
mklock
content="$(jq -nc '{runId:"run-1", unlockCode:"11111111-1111-1111-1111-111111111111"}')"
out="$(call Write "$(jq -nc --arg p "$CONF" --arg c "$content" '{file_path:$p, content:$c}')")"
assert_eq "$(decision "$out")" "allow"

t "carve-out rejects a wrong token"
bad="$(jq -nc '{runId:"run-1", unlockCode:"nope"}')"
out="$(call Write "$(jq -nc --arg p "$CONF" --arg c "$bad" '{file_path:$p, content:$c}')")"
assert_eq "$(decision "$out")" "deny"

t "carve-out rejects malformed content"
out="$(call Write "$(jq -nc --arg p "$CONF" '{file_path:$p, content:"garbage"}')")"
assert_eq "$(decision "$out")" "deny"

t "carve-out does not extend to other paths"
out="$(call Write "$(jq -nc --arg c "$content" '{file_path:"/tmp/elsewhere", content:$c}')")"
assert_eq "$(decision "$out")" "deny"

# --- lock integrity ----------------------------------------------------------
t "lock for another repo is not enforced here"
jq -n --arg root "/somewhere/else" --arg c "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{runId:"x", repoRoot:$root, createdAt:$c, unlockCode:"abc"}' > "$LOCK"
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$(decision "$out")" "allow"

t "lock missing unlockCode is denied"
jq -n --arg root "$REPO" --arg c "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{runId:"x", repoRoot:$root, createdAt:$c}' > "$LOCK"
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$(decision "$out")" "deny"

t "invalid lock JSON is denied"
printf 'garbage\n' > "$LOCK"
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$(decision "$out")" "deny"

t "a lock created right now is NOT stale (regression: local-time parsing)"
mklock
out="$(call Bash '{"command":"echo hi"}')"
assert_not_contains "$(reason "$out")" "stale lock"

t "stale lock (>4h) is denied, never auto-allowed"
mklock "$(date -u -v-5H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$(decision "$out")" "deny"
t "stale denial says stale"
assert_contains "$(reason "$out")" "stale lock"

t "unparseable createdAt is denied, not treated as fresh (audit #10)"
mklock "not-a-timestamp"
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$(decision "$out")" "deny"
t "unparseable timestamp denial explains itself"
assert_contains "$(reason "$out")" "could not be parsed"

t "lock with no createdAt is denied"
jq -n --arg root "$REPO" '{runId:"x", repoRoot:$root, unlockCode:"abc"}' > "$LOCK"
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$(decision "$out")" "deny"

# --- path trust (audit #4) ---------------------------------------------------
t "symlinked lock file is refused (audit #4)"
rm -f "$LOCK"
ln -s /etc/hosts "$LOCK"
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$(decision "$out")" "deny"
t "symlink refusal is explained"
assert_contains "$(reason "$out")" "symlink"
rm -f "$LOCK"

t "state dir with loose permissions is refused"
mklock
chmod 755 "$ULTRABLITZ_STATE_DIR"
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$(decision "$out")" "deny"
t "permission refusal names the mode"
assert_contains "$(reason "$out")" "mode is 755"
chmod 700 "$ULTRABLITZ_STATE_DIR"

t "symlinked state directory is refused"
alt="$SANDBOX/alt"; mkdir -m 700 -p "$alt"
out="$(ULTRABLITZ_STATE_DIR="$SANDBOX/linkdir" bash -c 'ln -sfn "$1" "$2"; jq -n "{tool_name:\"Bash\",tool_input:{}}" | bash "$3"' _ "$alt" "$SANDBOX/linkdir" "$GATE" 2>/dev/null)"
# A symlinked state dir with no lock inside allows (nothing to enforce); the
# meaningful case is a symlinked dir that DOES hold a lock:
cp "$LOCK" "$alt/gate-$HASH.lock" 2>/dev/null || mklock && cp "$LOCK" "$alt/gate-$HASH.lock"
out="$(ULTRABLITZ_STATE_DIR="$SANDBOX/linkdir" bash "$GATE" <<<"$(jq -nc '{tool_name:"Bash",tool_input:{}}')" 2>/dev/null)"
assert_eq "$(decision "$out")" "deny"

# --- audit logging (audit #17) ----------------------------------------------
t "gate decisions are logged as JSON lines (audit #17)"
rm -f "$ULTRABLITZ_STATE_DIR/gate.log"
mklock
call Bash '{"command":"echo hi"}' >/dev/null
[ -s "$ULTRABLITZ_STATE_DIR/gate.log" ] && _ok || _no "gate.log not written"
t "each log line is valid JSON with an event"
line="$(tail -1 "$ULTRABLITZ_STATE_DIR/gate.log")"
assert_json "$line" '.event' 'deny'

t "hook emits no output on allow (exit 0, silent)"
rm -f "$LOCK" "$CONF"
out="$(call Bash '{"command":"echo hi"}')"
assert_eq "$out" ""

finish
