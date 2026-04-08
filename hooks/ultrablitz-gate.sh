#!/usr/bin/env bash
# ultrablitz-gate.sh — PreToolUse hook for post-debate confirmation gate
# Blocks Edit/Write/Bash/NotebookEdit after ultrablitz completes until user confirms.
# Part of the ultrablitz skill: https://github.com/spiderpunklabs/ultrablitz
set -euo pipefail

LOCK_DIR="/tmp"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
REPO_HASH=$(echo -n "$REPO_ROOT" | shasum -a 256 | cut -c1-16)
LOCK_FILE="$LOCK_DIR/ultrablitz-gate-${REPO_HASH}.lock"
CONF_FILE="$LOCK_DIR/ultrablitz-gate-${REPO_HASH}.confirmed"

# No lock → allow
[ ! -f "$LOCK_FILE" ] && exit 0

# Require jq
if ! command -v jq &>/dev/null; then
  cat << 'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Ultrablitz gate requires jq. Install: brew install jq (macOS) or apt-get install jq (Linux). Gate is fail-closed until jq is available."}}
EOF
  exit 0
fi

# Parse lock file
LOCK_JSON=$(cat "$LOCK_FILE" 2>/dev/null) || {
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Ultrablitz gate: lock file unreadable. Clear with: ! rm '"$LOCK_FILE"' '"$CONF_FILE"' 2>/dev/null"}}'
  exit 0
}

LOCK_RUN_ID=$(echo "$LOCK_JSON" | jq -r '.runId // empty' 2>/dev/null)
LOCK_CODE=$(echo "$LOCK_JSON" | jq -r '.unlockCode // empty' 2>/dev/null)
LOCK_CREATED=$(echo "$LOCK_JSON" | jq -r '.createdAt // empty' 2>/dev/null)
LOCK_REPO=$(echo "$LOCK_JSON" | jq -r '.repoRoot // empty' 2>/dev/null)

# Invalid lock JSON → deny with recovery
if [ -z "$LOCK_RUN_ID" ] || [ -z "$LOCK_CODE" ]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Ultrablitz gate: invalid lock file. Clear with: ! rm '"$LOCK_FILE"' '"$CONF_FILE"' 2>/dev/null"}}'
  exit 0
fi

# Lock for different repo → allow (not our lock)
[ "$LOCK_REPO" != "$REPO_ROOT" ] && exit 0

# Check if confirmation file exists with matching tokens → gate cleared
if [ -f "$CONF_FILE" ]; then
  CONF_JSON=$(cat "$CONF_FILE" 2>/dev/null || echo '{}')
  CONF_RUN_ID=$(echo "$CONF_JSON" | jq -r '.runId // empty' 2>/dev/null)
  CONF_CODE=$(echo "$CONF_JSON" | jq -r '.unlockCode // empty' 2>/dev/null)
  if [ "$CONF_RUN_ID" = "$LOCK_RUN_ID" ] && [ "$CONF_CODE" = "$LOCK_CODE" ]; then
    exit 0  # Gate cleared — confirmed
  fi
fi

# Stale lock check (>4h) → deny with explicit clear instructions (never auto-allow)
if [ -n "$LOCK_CREATED" ]; then
  # Try BSD date, then GNU date, then Python3 fallback
  created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LOCK_CREATED" +%s 2>/dev/null \
    || date -d "$LOCK_CREATED" +%s 2>/dev/null \
    || python3 -c "import datetime; print(int(datetime.datetime.fromisoformat('$LOCK_CREATED'.replace('Z','+00:00')).timestamp()))" 2>/dev/null \
    || echo 0)
  now_epoch=$(date +%s)
  age=$(( now_epoch - created_epoch ))
  if [ "$age" -gt 14400 ]; then
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Ultrablitz gate: stale lock ('"$(( age / 3600 ))"'h old). Clear with: ! rm '"$LOCK_FILE"' '"$CONF_FILE"' 2>/dev/null"}}'
    exit 0
  fi
fi

# Carve-out: single-use confirmation write (pre-execution validation)
TOOL_NAME="${CLAUDE_TOOL_NAME:-}"
TOOL_INPUT="${CLAUDE_TOOL_INPUT:-}"
if [ "$TOOL_NAME" = "Write" ] && [ -n "$TOOL_INPUT" ]; then
  WRITE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty' 2>/dev/null)
  if [ "$WRITE_PATH" = "$CONF_FILE" ] && [ ! -f "$CONF_FILE" ]; then
    WRITE_CONTENT=$(echo "$TOOL_INPUT" | jq -r '.content // empty' 2>/dev/null)
    WRITE_RUN_ID=$(echo "$WRITE_CONTENT" | jq -r '.runId // empty' 2>/dev/null)
    WRITE_CODE=$(echo "$WRITE_CONTENT" | jq -r '.unlockCode // empty' 2>/dev/null)
    if [ "$WRITE_RUN_ID" = "$LOCK_RUN_ID" ] && [ "$WRITE_CODE" = "$LOCK_CODE" ]; then
      exit 0  # Allow this one confirmation write
    fi
  fi
fi

# Default: deny — gate active
cat << EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Ultrablitz confirmation gate active. Review the refined plan and confirm before implementation. To force clear: ! rm $LOCK_FILE $CONF_FILE 2>/dev/null"}}
EOF
