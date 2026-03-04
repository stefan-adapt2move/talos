#!/bin/bash
# Stop Hook: Session lifecycle management
set -euo pipefail

DB="$HOME/.index/atlas.db"

# --- 1. Release path locks held by this session's PID ---
if [ -f "$DB" ]; then
  RELEASED=$(sqlite3 "$DB" "DELETE FROM path_locks WHERE pid=$$; SELECT changes();" 2>/dev/null || echo "0")
  if [ "$RELEASED" -gt 0 ]; then
    echo "<system-notice>Released $RELEASED path lock(s) for PID $$.</system-notice>"
  fi
fi

# --- 2. Trigger sessions: remind to write a journal if today's entry doesn't exist ---
if [ -n "${ATLAS_TRIGGER:-}" ]; then
  TODAY=$(date +%Y-%m-%d)
  JOURNAL_DIR="$HOME/memory/journal"
  if [ -d "$JOURNAL_DIR" ] && ls "$JOURNAL_DIR/${TODAY}"*.md 1>/dev/null 2>&1; then
    : # Journal already exists for today
  else
    echo "<system-notice>"
    echo "JOURNAL REMINDER: You have not written a journal entry for today ($TODAY)."
    echo "Before ending this session, please write your daily journal to: memory/journal/${TODAY}.md"
    echo "Include: key activities, task results, decisions made, and anything to carry forward."
    echo "</system-notice>"
  fi
fi

exit 0
