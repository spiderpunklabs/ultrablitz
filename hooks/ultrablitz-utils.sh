#!/usr/bin/env bash
# ultrablitz-utils.sh — Helper utilities for ultrablitz skill
# Exact subcommands only: repo-hash, cleanup-completed, cleanup-interactive,
# resolve-companion, create-session, trash-session, validate-session,
# pre-codex-validate, create-gate-lock, legacy-scan
set -euo pipefail

SUBCOMMAND="${1:-}"

case "$SUBCOMMAND" in
  repo-hash)
    # Output 16-char SHA256 hash of repo root (or canonical CWD if non-git)
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
    echo -n "$REPO_ROOT" | shasum -a 256 | cut -c1-16
    ;;

  cleanup-completed)
    # Move /tmp/ultrablitz-* directories with a 'completed' marker to ~/.Trash/
    # via trash-session. Surfaces failures explicitly.
    TRASHED=0
    FAILED=0
    FAILED_DIRS=""
    for dir in /tmp/ultrablitz-*/; do
      [ ! -d "$dir" ] && continue
      [ ! -f "$dir/completed" ] && continue
      RUNID=$(basename "$dir" | sed 's/^ultrablitz-//')
      if "$0" trash-session "$RUNID"; then
        TRASHED=$((TRASHED + 1))
      else
        FAILED=$((FAILED + 1))
        FAILED_DIRS="$FAILED_DIRS $dir"
      fi
    done
    echo "Trashed $TRASHED, failed $FAILED"
    if [ "$FAILED" -gt 0 ]; then
      echo "Failed sessions remain in /tmp:$FAILED_DIRS" >&2
      echo "Inspect cleanup.error inside each for diagnostics" >&2
    fi
    ;;

  create-session)
    # Create /tmp/ultrablitz-<UUID>/ mode 700 and print the path on stdout.
    RUNID=$(uuidgen)
    DIR="/tmp/ultrablitz-${RUNID}"
    mkdir -m 700 "$DIR" || { echo "create-session: mkdir failed for $DIR" >&2; exit 1; }
    echo "$DIR"
    ;;

  trash-session)
    # Usage: trash-session <runId>
    # Collision-resistant destination: <ts>-<pid>, with -2,-3,... suffix retry.
    RUNID="${2:-}"
    [ -z "$RUNID" ] && { echo "trash-session: runId required" >&2; exit 1; }
    SRC="/tmp/ultrablitz-${RUNID}"
    [ ! -d "$SRC" ] && exit 0
    TS=$(date +%s); PID=$$
    BASE_DST="$HOME/.Trash/ultrablitz-${RUNID}-${TS}-${PID}"
    DST="$BASE_DST"
    N=2
    while [ -e "$DST" ] && [ "$N" -le 100 ]; do
      DST="${BASE_DST}-${N}"
      N=$((N + 1))
    done
    if mv "$SRC" "$DST" 2>/dev/null; then
      echo "Trashed: $SRC -> $DST"
    else
      echo "$(date -u +%FT%TZ) trash-session failed: src=$SRC dst=$DST" \
        >> "$SRC/cleanup.error" 2>/dev/null || true
      echo "trash-session: failed to move $SRC" >&2
      exit 2
    fi
    ;;

  validate-session)
    # Usage: validate-session <runId>
    # Allowed at session root: *.md, session.json, completed, cleanup.error.
    # Rejects non-regular entries (symlinks, subdirs) at session root.
    RUNID="${2:-}"
    [ -z "$RUNID" ] && { echo "validate-session: runId required" >&2; exit 1; }
    DIR="/tmp/ultrablitz-${RUNID}"
    [ ! -d "$DIR" ] && { echo "validate-session: $DIR missing" >&2; exit 1; }

    NON_FILES=$(find "$DIR" -mindepth 1 -maxdepth 1 ! -type f -print)
    if [ -n "$NON_FILES" ]; then
      echo "validate-session: non-regular entries in $DIR:" >&2
      echo "$NON_FILES" >&2
      exit 4
    fi

    VIOLATIONS=$(find "$DIR" -maxdepth 1 -type f \
      ! -name "*.md" ! -name "session.json" \
      ! -name "completed" ! -name "cleanup.error" -print)
    if [ -n "$VIOLATIONS" ]; then
      echo "validate-session: contract violation in $DIR:" >&2
      echo "$VIOLATIONS" >&2
      exit 3
    fi
    echo "ok"
    ;;

  pre-codex-validate)
    # Single integration point Claude calls before every Codex task/resume.
    exec "$0" validate-session "${2:-}"
    ;;

  create-gate-lock)
    # Usage: create-gate-lock <runId> <repoRoot> <unlockCode>
    # Atomic lock create via noclobber.
    RUNID="${2:-}" REPO="${3:-}" CODE="${4:-}"
    if [ -z "$RUNID" ] || [ -z "$REPO" ] || [ -z "$CODE" ]; then
      echo "create-gate-lock: runId, repoRoot, unlockCode required" >&2
      exit 1
    fi
    HASH=$(echo -n "$REPO" | shasum -a 256 | cut -c1-16)
    LOCK="/tmp/ultrablitz-gate-${HASH}.lock"
    CREATED=$(date -u +%FT%TZ)
    PID=$$
    set -C
    printf '%s\n' "{\"runId\":\"$RUNID\",\"repoRoot\":\"$REPO\",\"createdAt\":\"$CREATED\",\"unlockCode\":\"$CODE\",\"pid\":$PID}" > "$LOCK" 2>/dev/null \
      || { echo "create-gate-lock: lock exists at $LOCK" >&2; exit 4; }
    echo "$LOCK"
    ;;

  legacy-scan)
    # Classify each /tmp/ultrablitz-*/ as one of:
    #   conforming, completed, nonconforming-older-than-4h, nonconforming-recent
    # Output is consumed by Claude; helper does NOT auto-act.
    for dir in /tmp/ultrablitz-*/; do
      [ ! -d "$dir" ] && continue
      if [ -f "$dir/completed" ]; then
        echo "completed $dir"
        continue
      fi
      HAS_BAD=$(find "$dir" -maxdepth 1 -type f \
        ! -name "*.md" ! -name "session.json" \
        ! -name "completed" ! -name "cleanup.error" -print -quit)
      AGE_HRS=$(( ($(date +%s) - $(stat -f %B "$dir" 2>/dev/null || echo 0)) / 3600 ))
      if [ -n "$HAS_BAD" ]; then
        if [ "$AGE_HRS" -gt 4 ]; then
          echo "nonconforming-older-than-4h $dir"
        else
          echo "nonconforming-recent $dir"
        fi
      else
        echo "conforming $dir"
      fi
    done
    ;;

  cleanup-interactive)
    # List incomplete sessions, let user confirm deletion
    FOUND=0
    for dir in /tmp/ultrablitz-*/; do
      [ ! -d "$dir" ] && continue
      [ -f "$dir/completed" ] && continue  # skip completed
      FOUND=$((FOUND + 1))
      SESSION_FILE="$dir/session.json"
      if [ -f "$SESSION_FILE" ] && command -v jq &>/dev/null; then
        RUN_ID=$(jq -r '.runId // "unknown"' "$SESSION_FILE" 2>/dev/null)
        CREATED=$(jq -r '.createdAt // "unknown"' "$SESSION_FILE" 2>/dev/null)
        ROUND=$(jq -r '.round // "?"' "$SESSION_FILE" 2>/dev/null)
        echo "Session: $RUN_ID | Created: $CREATED | Round: $ROUND | Path: $dir"
      else
        echo "Session: $(basename "$dir") | Path: $dir"
      fi
    done
    if [ "$FOUND" -eq 0 ]; then
      echo "No incomplete sessions found"
    else
      echo ""
      echo "$FOUND incomplete session(s) listed above"
      echo "To delete a specific session: rm -r /tmp/ultrablitz-<UUID>/"
    fi
    ;;

  resolve-companion)
    # Find codex-companion.mjs — check cache (highest version) then marketplace
    COMPANION=""

    # Cache path (highest version)
    CACHE_HIT=$(ls ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)
    if [ -n "$CACHE_HIT" ] && [ -f "$CACHE_HIT" ] && [ -x "$CACHE_HIT" ]; then
      COMPANION="$CACHE_HIT"
    fi

    # Marketplace path
    if [ -z "$COMPANION" ]; then
      MKT="$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
      if [ -f "$MKT" ] && [ -x "$MKT" ]; then
        COMPANION="$MKT"
      fi
    fi

    if [ -n "$COMPANION" ]; then
      echo "$COMPANION"
    else
      echo "ERROR: codex-companion.mjs not found" >&2
      echo "Checked:" >&2
      echo "  ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs" >&2
      echo "  ~/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs" >&2
      exit 1
    fi
    ;;

  *)
    echo "ultrablitz-utils.sh: unknown subcommand '$SUBCOMMAND'" >&2
    echo "Usage: ultrablitz-utils.sh {repo-hash|cleanup-completed|cleanup-interactive|resolve-companion|create-session|trash-session|validate-session|pre-codex-validate|create-gate-lock|legacy-scan}" >&2
    exit 1
    ;;
esac
