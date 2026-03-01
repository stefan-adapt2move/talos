#!/bin/bash
set -euo pipefail

CLEANUP_DONE=$HOME/.cleanup-done
DB=$HOME/.index/atlas.db

# Prune old data (30 days)
if [ -f "$DB" ]; then
  sqlite3 "$DB" <<'SQL'
    DELETE FROM tasks WHERE status IN ('done','cancelled') AND created_at < datetime('now', '-30 days');
    DELETE FROM messages WHERE created_at < datetime('now', '-30 days');
    DELETE FROM trigger_sessions WHERE updated_at < datetime('now', '-30 days');
    DELETE FROM task_awaits WHERE created_at < datetime('now', '-30 days');
SQL
  echo "[$(date)] DB pruned (30-day retention)"
fi

# Check if there was activity in the last day
MSGS=0
if [ -f "$DB" ]; then
  MSGS=$(sqlite3 "$DB" \
    'SELECT count(*) FROM messages WHERE date(processed_at)>=date("now","-1 day")' 2>/dev/null || echo "0")
fi

echo "[$(date)] Daily cleanup starting. Recent messages: $MSGS"

if [ "$MSGS" -gt 0 ]; then
  rm -f "$CLEANUP_DONE"

  CLEANUP_PROMPT="$(cat /atlas/app/prompts/daily-cleanup-prompt.md)"
  CLEANUP_PROMPT="${CLEANUP_PROMPT//YYYY-MM-DD/$(date +%Y-%m-%d)}"

  export ATLAS_CRON=1
  ATLAS_CLEANUP=1 claude-atlas --mode trigger --max-turns 5 \
    -p "$CLEANUP_PROMPT" 2>&1 | tee -a /atlas/logs/cleanup.log || true

  # Wait for cleanup to complete (max 120s)
  TIMEOUT=120
  ELAPSED=0
  while [ ! -f "$CLEANUP_DONE" ] && [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))
  done

  if [ ! -f "$CLEANUP_DONE" ]; then
    echo "[$(date)] Cleanup timed out after ${TIMEOUT}s" >> /atlas/logs/cleanup.log
  fi
fi

echo "[$(date)] Cleanup done. Messages: $MSGS" >> /atlas/logs/cleanup.log
