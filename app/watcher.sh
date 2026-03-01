#!/bin/bash
set -euo pipefail

export PATH=/atlas/app/bin:/usr/local/bin:/usr/bin:/bin:$PATH

WORKSPACE="$HOME"
DB="$WORKSPACE/.index/atlas.db"
WATCH_DIR=$WORKSPACE/.index
CLAUDE_JSON="$HOME/.claude.json"
APP_DIR="/atlas/app"

source /atlas/app/hooks/failure-handler.sh

save_session_metrics() {
  local JSON_FILE="$1" SESSION_TYPE="$2" TRIGGER_NAME="$3"
  local STARTED_AT="$4" ENDED_AT="$5" EXIT_CODE="${6:-0}"
  [ -f "$JSON_FILE" ] || return 0
  python3 - "$JSON_FILE" "$SESSION_TYPE" "$TRIGGER_NAME" \
            "$STARTED_AT" "$ENDED_AT" "$EXIT_CODE" << 'PYEOF'
import json, sys, sqlite3
f, stype, tname, started, ended, exit_code = sys.argv[1:]
try:
    d = json.load(open(f))
except:
    d = {}
usage = d.get('usage') or {}
db_path = (
    __import__('os').environ.get('HOME', '') + '/.index/atlas.db'
)
conn = sqlite3.connect(db_path)
conn.execute('''INSERT INTO session_metrics
  (session_type, session_id, trigger_name, started_at, ended_at,
   duration_ms, input_tokens, output_tokens, cache_read_tokens,
   cache_creation_tokens, cost_usd, num_turns, is_error)
  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)''', (
    stype,
    d.get('session_id', '') or '',
    tname or '',
    started, ended,
    int(d.get('duration_ms') or 0),
    int(usage.get('input_tokens') or 0),
    int(usage.get('output_tokens') or 0),
    int(usage.get('cache_read_input_tokens') or 0),
    int(usage.get('cache_creation_input_tokens') or 0),
    float(d.get('total_cost_usd') or d.get('cost_usd') or 0),
    int(d.get('num_turns') or 0),
    1 if str(exit_code) != '0' else 0,
))
conn.commit()
conn.close()
PYEOF
}

# Disable remote MCP connectors that hang on startup.
disable_remote_mcp() {
  [ -f "$CLAUDE_JSON" ] || return 0
  jq '.cachedGrowthBookFeatures.tengu_claudeai_mcp_connectors = false' \
    "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && mv "${CLAUDE_JSON}.tmp" "$CLAUDE_JSON"
}

# Read max_parallel from config
read_max_parallel() {
  local CONFIG=""
  if [ -f "$HOME/config.yml" ]; then
    CONFIG="$HOME/config.yml"
  elif [ -f "$APP_DIR/defaults/config.yml" ]; then
    CONFIG="$APP_DIR/defaults/config.yml"
  fi
  MAX_PARALLEL=3  # default
  if [ -n "$CONFIG" ]; then
    local PARSED
    PARSED=$(python3 -c "import yaml; c=yaml.safe_load(open('$CONFIG')); print(c.get('workers',{}).get('max_parallel', 3))" 2>/dev/null) || true
    if [ -n "$PARSED" ]; then
      MAX_PARALLEL="$PARSED"
    fi
  fi
}

# Count active task-runners (tasks in processing/reviewing state)
count_active_workers() {
  [ -f "$DB" ] || { echo "0"; return; }
  sqlite3 "$DB" "SELECT COUNT(*) FROM tasks WHERE status IN ('processing', 'reviewing');" 2>/dev/null || echo "0"
}

# Dispatch pending tasks that can be run
dispatch_pending_tasks() {
  [ -f "$DB" ] || return 0

  read_max_parallel
  local ACTIVE
  ACTIVE=$(count_active_workers)

  if [ "$ACTIVE" -ge "$MAX_PARALLEL" ]; then
    echo "[$(date)] Max parallel workers reached ($ACTIVE/$MAX_PARALLEL), skipping dispatch"
    return 0
  fi

  # Get pending tasks ordered by creation time
  local PENDING_TASKS
  PENDING_TASKS=$(sqlite3 -json "$DB" \
    "SELECT id, path FROM tasks WHERE status='pending' ORDER BY created_at ASC;" \
    2>/dev/null || echo "[]")

  [ "$PENDING_TASKS" = "[]" ] && return 0

  echo "$PENDING_TASKS" | jq -c '.[]' 2>/dev/null | while IFS= read -r row; do
    # Re-check slots (might have filled during iteration)
    ACTIVE=$(count_active_workers)
    if [ "$ACTIVE" -ge "$MAX_PARALLEL" ]; then
      echo "[$(date)] Max parallel workers reached during dispatch ($ACTIVE/$MAX_PARALLEL)"
      break
    fi

    local TASK_ID TASK_PATH
    TASK_ID=$(printf '%s' "$row" | jq -r '.id')
    TASK_PATH=$(printf '%s' "$row" | jq -r '.path // empty')

    # Check path lock conflict (only for tasks with a path)
    if [ -n "$TASK_PATH" ]; then
      local NORM_PATH CONFLICTS
      NORM_PATH=$(python3 -c "import os; p=os.path.realpath('$TASK_PATH'); print(p+'/' if not p.endswith('/') else p)" 2>/dev/null || echo "$TASK_PATH/")
      CONFLICTS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM path_locks WHERE '$NORM_PATH' LIKE locked_path || '%' OR locked_path LIKE '$NORM_PATH' || '%';" 2>/dev/null || echo "0")
      if [ "$CONFLICTS" -gt 0 ]; then
        echo "[$(date)] Task $TASK_ID: path conflict for $TASK_PATH, skipping"
        continue
      fi
    fi

    echo "[$(date)] Dispatching task $TASK_ID (path=${TASK_PATH:-<none>})"

    # Spawn task-runner in background
    (
      exec </dev/null >>/atlas/logs/watcher.log 2>&1
      "$APP_DIR/task-runner.sh" "$TASK_ID" 2>&1 | tee -a "/atlas/logs/task-runner-${TASK_ID}.log" || true
    ) &

  done
}

handle_trigger_wake() {
  local WAKE_FILE="$1"
  [ -f "$WAKE_FILE" ] || return 0
  local FILENAME
  FILENAME=$(basename "$WAKE_FILE")
  local _WAKE_BODY="${FILENAME#.wake-}"
  local TRIGGER_NAME="${_WAKE_BODY%-*}"

  echo "[$(date)] Trigger wake event: $TRIGGER_NAME (file=$FILENAME)"

  (
    exec </dev/null >>/atlas/logs/watcher.log 2>&1
    flock -n 200 || { echo "[$(date)] Trigger $TRIGGER_NAME already running, skipping"; exit 0; }

    TEMP_WAKE=$(mktemp /tmp/wake-XXXXXX.json)
    mv "$WAKE_FILE" "$TEMP_WAKE" 2>/dev/null || { rm -f "$TEMP_WAKE"; exit 0; }

    eval "$(jq -r '{
      task_id: (.task_id // ""),
      session_id: (.session_id // ""),
      session_key: (.session_key // ""),
      channel: (.channel // "internal"),
      summary: (.response_summary // "")
    } | to_entries | map("WAKE_\(.key | ascii_upcase)=\(.value | @sh)") | .[]' "$TEMP_WAKE" 2>/dev/null)" || true
    TASK_ID="${WAKE_TASK_ID:-}"
    SESSION_ID="${WAKE_SESSION_ID:-}"
    SESSION_KEY="${WAKE_SESSION_KEY:-}"
    CHANNEL="${WAKE_CHANNEL:-internal}"
    SUMMARY="${WAKE_SUMMARY:-}"
    rm -f "$TEMP_WAKE"

    RESUME_MSG="Task #${TASK_ID} completed. Here is the worker's result:

${SUMMARY}

Relay this result to the original sender now."

    LOG="/atlas/logs/trigger-${TRIGGER_NAME}.log"

    disable_remote_mcp

    if [ -n "$SESSION_ID" ]; then
      echo "[$(date)] Resuming trigger $TRIGGER_NAME (session=$SESSION_ID)" | tee -a "$LOG"
      RELAY_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      RELAY_OUT=$(mktemp /tmp/relay-out-XXXXXX.json)
      ATLAS_TRIGGER="$TRIGGER_NAME" ATLAS_TRIGGER_CHANNEL="$CHANNEL" ATLAS_TRIGGER_SESSION_KEY="$SESSION_KEY" \
        claude-atlas --mode trigger --output-format json --resume "$SESSION_ID" \
        --dangerously-skip-permissions -p "$RESUME_MSG" > "$RELAY_OUT" 2>>"$LOG" || true
      RELAY_EXIT=$?
      RELAY_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      python3 -c "
import json,sys
try: print(json.load(open(sys.argv[1])).get('result',''))
except: pass
" "$RELAY_OUT" >> "$LOG"
      save_session_metrics "$RELAY_OUT" "trigger-relay" "$TRIGGER_NAME" "$RELAY_START" "$RELAY_END" "$RELAY_EXIT"
      rm -f "$RELAY_OUT"
    elif [ -n "$TRIGGER_NAME" ]; then
      echo "[$(date)] No session ID for $TRIGGER_NAME — re-spawning via trigger.sh" | tee -a "$LOG"
      /atlas/app/triggers/trigger.sh "$TRIGGER_NAME" "$RESUME_MSG" "$SESSION_KEY" 2>&1 | tee -a "$LOG" || true
    fi

    echo "[$(date)] Trigger $TRIGGER_NAME re-awakening done" | tee -a "$LOG"
  ) 200>"$WORKSPACE/.trigger-${TRIGGER_NAME}.flock" &
}

startup_recovery() {
  # Pass 1: Clean up stale path locks (PID not running)
  if [ -f "$DB" ]; then
    local STALE_LOCKS
    STALE_LOCKS=$(sqlite3 -json "$DB" "SELECT task_id, pid FROM path_locks WHERE pid IS NOT NULL;" 2>/dev/null || echo "[]")
    if [ "$STALE_LOCKS" != "[]" ]; then
      echo "$STALE_LOCKS" | jq -c '.[]' 2>/dev/null | while IFS= read -r row; do
        local LOCK_TASK_ID LOCK_PID
        LOCK_TASK_ID=$(printf '%s' "$row" | jq -r '.task_id')
        LOCK_PID=$(printf '%s' "$row" | jq -r '.pid')
        if ! kill -0 "$LOCK_PID" 2>/dev/null; then
          echo "[$(date)] Startup: cleaning stale lock for task $LOCK_TASK_ID (pid $LOCK_PID dead)"
          sqlite3 "$DB" "DELETE FROM path_locks WHERE task_id=$LOCK_TASK_ID;" 2>/dev/null || true
          sqlite3 "$DB" "UPDATE tasks SET status='pending', processed_at=NULL WHERE id=$LOCK_TASK_ID AND status IN ('processing','reviewing');" 2>/dev/null || true
        fi
      done
    fi

    # Reset any stuck processing/reviewing tasks without a lock entry
    sqlite3 "$DB" "UPDATE tasks SET status='pending', processed_at=NULL WHERE status IN ('processing','reviewing') AND id NOT IN (SELECT task_id FROM path_locks);" 2>/dev/null || true
  fi

  # Pass 2: Remove stale .wake-task-* files (tasks are still pending in DB)
  for f in "$WATCH_DIR"/.wake-task-*; do
    [ -f "$f" ] || continue
    echo "[$(date)] Startup recovery: removing stale task wake file $(basename "$f")"
    rm -f "$f"
  done

  # Pass 3: Process stale .wake-<trigger>-* files (trigger re-awakening)
  for f in "$WATCH_DIR"/.wake-*; do
    [ -f "$f" ] || continue
    [[ "$(basename "$f")" == .wake-task-* ]] && continue  # Already handled above
    echo "[$(date)] Startup recovery: stale trigger wake file $(basename "$f")"
    handle_trigger_wake "$f"
  done

  # Pass 4: Re-create wake files for done tasks whose wake file was never written
  [ -f "$DB" ] || return 0
  sqlite3 -json "$DB" \
    "SELECT ta.task_id, ta.trigger_name, ta.session_key,
            COALESCE(ts.session_id,'') AS session_id,
            COALESCE(t.channel,'internal') AS channel,
            COALESCE(tk.response_summary,'') AS response_summary
     FROM task_awaits ta
     JOIN tasks tk ON tk.id = ta.task_id AND tk.status = 'done'
     LEFT JOIN trigger_sessions ts ON ts.trigger_name = ta.trigger_name
                                   AND ts.session_key = ta.session_key
     LEFT JOIN triggers t ON t.name = ta.trigger_name" 2>/dev/null \
  | jq -c '.[]' 2>/dev/null \
  | while IFS= read -r row; do
      local task_id trigger_name
      task_id=$(printf '%s' "$row" | jq -r '.task_id')
      trigger_name=$(printf '%s' "$row" | jq -r '.trigger_name')
      local WAKE_FILE="$WATCH_DIR/.wake-${trigger_name}-${task_id}"
      [ -f "$WAKE_FILE" ] && continue  # already handled
      echo "[$(date)] Startup recovery: recreating wake for task $task_id ($trigger_name)"
      printf '%s' "$row" > "$WAKE_FILE"
      sqlite3 "$DB" "DELETE FROM task_awaits WHERE task_id = $task_id" 2>/dev/null || true
      handle_trigger_wake "$WAKE_FILE"
    done

  # Dispatch any pending tasks left over
  dispatch_pending_tasks
}

# Ensure watch directory exists
mkdir -p "$WATCH_DIR"
touch "$WATCH_DIR/.wake"

echo "[$(date)] Watcher started. Monitoring $WATCH_DIR"

startup_recovery

inotifywait -m "$WATCH_DIR" -e create,modify,attrib --exclude '\.(db|wal|shm)$' --format '%f' | while read FILENAME; do

  # --- Task dispatch signal (.wake or .wake-task-<id> files) ---
  if [ "$FILENAME" = ".wake" ]; then
    echo "[$(date)] Dispatch signal received (.wake)"
    dispatch_pending_tasks

  elif [[ "$FILENAME" == .wake-task-* ]]; then
    TASK_ID="${FILENAME#.wake-task-}"
    echo "[$(date)] New task wake: task $TASK_ID"
    # Remove wake file (task stays pending in DB, dispatch_pending_tasks handles it)
    rm -f "$WATCH_DIR/$FILENAME"
    dispatch_pending_tasks

  # --- Trigger session re-awakening (.wake-<trigger>-<task_id> file) ---
  elif [[ "$FILENAME" == .wake-* ]]; then
    handle_trigger_wake "$WATCH_DIR/$FILENAME"
  fi

done
