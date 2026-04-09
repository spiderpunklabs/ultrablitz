#!/usr/bin/env bash
# ultrablitz-utils.sh — Helper utilities for ultrablitz skill
# Exact subcommands only: repo-hash, cleanup-completed, cleanup-interactive, resolve-companion
set -euo pipefail

SUBCOMMAND="${1:-}"

case "$SUBCOMMAND" in
  repo-hash)
    # Output 16-char SHA256 hash of repo root (or canonical CWD if non-git)
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
    echo -n "$REPO_ROOT" | shasum -a 256 | cut -c1-16
    ;;

  cleanup-completed)
    # Delete /tmp/ultrablitz-* directories that have a 'completed' marker
    DELETED=0
    for dir in /tmp/ultrablitz-*/; do
      [ ! -d "$dir" ] && continue
      if [ -f "$dir/completed" ]; then
        rm -r "$dir" 2>/dev/null && DELETED=$((DELETED + 1))
      fi
    done
    echo "Cleaned $DELETED completed session(s)"
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
    echo "Usage: ultrablitz-utils.sh {repo-hash|cleanup-completed|cleanup-interactive|resolve-companion}" >&2
    exit 1
    ;;
esac
