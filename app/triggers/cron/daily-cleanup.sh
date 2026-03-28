#!/bin/bash
set -euo pipefail

DB=$HOME/.index/talos.db

# Prune old data (30 days)
if [ -f "$DB" ]; then
  sqlite3 "$DB" <<'SQL'
    DELETE FROM messages WHERE created_at < datetime('now', '-30 days');
    DELETE FROM trigger_sessions WHERE updated_at < datetime('now', '-30 days');
    DELETE FROM session_metrics WHERE started_at < datetime('now', '-90 days');
    DELETE FROM reminders WHERE status IN ('fired','cancelled') AND fire_at < datetime('now', '-30 days');
SQL
  echo "[$(date)] DB pruned (30-day retention, 90-day metrics)"
fi

echo "[$(date)] Daily cleanup done" >> /talos/logs/cleanup.log
