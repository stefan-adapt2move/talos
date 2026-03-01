#!/bin/bash
set -euo pipefail

DB=$HOME/.index/atlas.db

# Prune old data (30 days)
if [ -f "$DB" ]; then
  sqlite3 "$DB" <<'SQL'
    DELETE FROM tasks WHERE status IN ('done','cancelled') AND created_at < datetime('now', '-30 days');
    DELETE FROM messages WHERE created_at < datetime('now', '-30 days');
    DELETE FROM trigger_sessions WHERE updated_at < datetime('now', '-30 days');
    DELETE FROM task_awaits WHERE created_at < datetime('now', '-30 days');
    DELETE FROM path_locks WHERE task_id NOT IN (SELECT id FROM tasks WHERE status IN ('processing', 'reviewing'));
    DELETE FROM session_metrics WHERE started_at < datetime('now', '-90 days');
SQL
  echo "[$(date)] DB pruned (30-day retention, 90-day metrics)"
fi

echo "[$(date)] Daily cleanup done" >> /atlas/logs/cleanup.log
