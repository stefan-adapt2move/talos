#!/bin/bash
# Task Runner: Orchestrates the lifecycle of a single task.
# Spawns an ephemeral worker, optionally runs a review loop, then completes the task.
# Usage: task-runner.sh <task_id>
set -euo pipefail

export PATH=/atlas/app/bin:/usr/local/bin:/usr/bin:/bin:$PATH

TASK_ID="${1:?Usage: task-runner.sh <task_id>}"
WORKSPACE="$HOME"
DB="$WORKSPACE/.index/atlas.db"
APP_DIR="/atlas/app"
LOG="/atlas/logs/task-runner-${TASK_ID}.log"
PID_FILE="/tmp/task-runner-${TASK_ID}.pid"
CLAUDE_JSON="$HOME/.claude.json"

# Write PID file for crash recovery
echo $$ > "$PID_FILE"

log() { echo "[$(date)] [task:$TASK_ID] $*" | tee -a "$LOG"; }

cleanup() {
  # Release path lock
  bun run "$APP_DIR/inbox-mcp/release-lock.ts" "$TASK_ID" 2>/dev/null || true
  rm -f "$PID_FILE"
  # Signal watcher to dispatch next pending tasks
  touch "$WORKSPACE/.index/.wake"
}
trap cleanup EXIT

# Disable remote MCP connectors that hang on startup
disable_remote_mcp() {
  [ -f "$CLAUDE_JSON" ] || return 0
  jq '.cachedGrowthBookFeatures.tengu_claudeai_mcp_connectors = false' \
    "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && mv "${CLAUDE_JSON}.tmp" "$CLAUDE_JSON"
}

# Read max_review_iterations from config
read_config() {
  local CONFIG=""
  if [ -f "$HOME/config.yml" ]; then
    CONFIG="$HOME/config.yml"
  elif [ -f "$APP_DIR/defaults/config.yml" ]; then
    CONFIG="$APP_DIR/defaults/config.yml"
  fi
  MAX_REVIEW_ITERATIONS=5
  if [ -n "$CONFIG" ]; then
    local PARSED
    PARSED=$(python3 -c "import yaml; c=yaml.safe_load(open('$CONFIG')); print(c.get('workers',{}).get('max_review_iterations', 5))" 2>/dev/null) || true
    if [ -n "$PARSED" ]; then
      MAX_REVIEW_ITERATIONS="$PARSED"
    fi
  fi
}

# Save session metrics to DB
save_session_metrics() {
  local JSON_FILE="$1" SESSION_TYPE="$2" TRIGGER_NAME="$3"
  local STARTED_AT="$4" ENDED_AT="$5" EXIT_CODE="${6:-0}"
  [ -f "$JSON_FILE" ] || return 0
  python3 - "$JSON_FILE" "$SESSION_TYPE" "$TRIGGER_NAME" \
            "$STARTED_AT" "$ENDED_AT" "$EXIT_CODE" << 'PYEOF'
import json, sys, sqlite3, os
f, stype, tname, started, ended, exit_code = sys.argv[1:]
try:
    d = json.load(open(f))
except:
    d = {}
usage = d.get('usage') or {}
db_path = os.environ.get('HOME', '') + '/.index/atlas.db'
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

# Mark task as failed with error message
mark_failed() {
  local ERROR_MSG="$1"
  sqlite3 "$DB" "UPDATE tasks SET status='failed', response_summary=$(printf "'%s'" "$ERROR_MSG"), processed_at=datetime('now') WHERE id=$TASK_ID;" 2>/dev/null || true
  # Wake trigger with error
  bun run "$APP_DIR/inbox-mcp/wake-trigger.ts" "$TASK_ID" "Task failed: $ERROR_MSG" 2>/dev/null || true
}

# Extract the result text from Claude's JSON output
extract_result() {
  local JSON_FILE="$1"
  python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('result', ''))
except:
    print('')
" "$JSON_FILE" 2>/dev/null || echo ""
}

# Extract session_id from Claude's JSON output
extract_session_id() {
  local JSON_FILE="$1"
  python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('session_id', ''))
except:
    print('')
" "$JSON_FILE" 2>/dev/null || echo ""
}

# === MAIN ===

log "Starting task runner"
read_config

# 1. Read task from DB
TASK_JSON=$(sqlite3 -json "$DB" "SELECT * FROM tasks WHERE id=$TASK_ID AND status='pending' LIMIT 1;" 2>/dev/null || echo "[]")
if [ "$TASK_JSON" = "[]" ] || [ -z "$TASK_JSON" ]; then
  log "Task $TASK_ID not found or not pending, exiting"
  exit 0
fi

TASK_CONTENT=$(printf '%s' "$TASK_JSON" | jq -r '.[0].content')
TASK_PATH=$(printf '%s' "$TASK_JSON" | jq -r '.[0].path // empty')
TASK_TYPE=$(printf '%s' "$TASK_JSON" | jq -r '.[0].type // "code"')
TASK_REVIEW=$(printf '%s' "$TASK_JSON" | jq -r '.[0].review // 1')
TRIGGER_NAME=$(printf '%s' "$TASK_JSON" | jq -r '.[0].trigger_name // ""')

log "Task loaded: type=$TASK_TYPE path=${TASK_PATH:-<none>} review=$TASK_REVIEW"

# 2. Acquire path lock (if path is set)
if [ -n "$TASK_PATH" ]; then
  LOCK_RESULT=$(bun run "$APP_DIR/inbox-mcp/acquire-lock.ts" "$TASK_ID" "$TASK_PATH" "$$" 2>/dev/null)
  if [ "$LOCK_RESULT" != "acquired" ]; then
    log "Path lock conflict ($LOCK_RESULT), leaving task pending"
    # Don't mark failed — just exit and let watcher retry later
    rm -f "$PID_FILE"
    trap - EXIT  # Don't run cleanup (which would release lock and touch .wake)
    exit 0
  fi
  log "Path lock acquired: $TASK_PATH"
fi

# 3. Set task to processing
sqlite3 "$DB" "UPDATE tasks SET status='processing', processed_at=datetime('now') WHERE id=$TASK_ID;" 2>/dev/null

# 4. Determine working directory
WORK_DIR="$WORKSPACE"
if [ -n "$TASK_PATH" ] && [ -d "$TASK_PATH" ]; then
  WORK_DIR="$TASK_PATH"
fi

disable_remote_mcp

# 5. Spawn ephemeral worker session
log "Spawning worker session (cwd=$WORK_DIR)"
WORKER_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
WORKER_OUT=$(mktemp /tmp/worker-out-XXXXXX.json)
WORKER_SESSION_ID=""

set +e
(cd "$WORK_DIR" && claude-atlas --mode worker-ephemeral --output-format json \
  --dangerously-skip-permissions \
  -p "$TASK_CONTENT" > "$WORKER_OUT" 2>>"$LOG")
WORKER_EXIT=$?
set -e

WORKER_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
WORKER_SESSION_ID=$(extract_session_id "$WORKER_OUT")
WORKER_RESULT=$(extract_result "$WORKER_OUT")

save_session_metrics "$WORKER_OUT" "worker" "$TRIGGER_NAME" "$WORKER_START" "$WORKER_END" "$WORKER_EXIT"

if [ "$WORKER_EXIT" -ne 0 ] && [ -z "$WORKER_RESULT" ]; then
  log "Worker session failed with exit $WORKER_EXIT"
  mark_failed "Worker session crashed (exit code $WORKER_EXIT)"
  rm -f "$WORKER_OUT"
  exit 1
fi

log "Worker session completed (exit=$WORKER_EXIT)"

# Store worker result in DB
sqlite3 "$DB" "UPDATE tasks SET worker_result=$(printf "'%s'" "$(echo "$WORKER_RESULT" | sed "s/'/''/g")") WHERE id=$TASK_ID;" 2>/dev/null || true

# 6. Review loop (if review is enabled)
if [ "$TASK_REVIEW" = "1" ]; then
  REVIEW_ITERATION=0
  REVIEWER_SESSION_ID=""

  while [ "$REVIEW_ITERATION" -lt "$MAX_REVIEW_ITERATIONS" ]; do
    REVIEW_ITERATION=$((REVIEW_ITERATION + 1))
    log "Review iteration $REVIEW_ITERATION/$MAX_REVIEW_ITERATIONS"

    # Update task status
    sqlite3 "$DB" "UPDATE tasks SET status='reviewing', review_iteration=$REVIEW_ITERATION WHERE id=$TASK_ID;" 2>/dev/null

    # Build reviewer prompt
    REVIEWER_PROMPT="## Task Under Review

### Original Task Description
$TASK_CONTENT

### Worker Result (Iteration $REVIEW_ITERATION)
$WORKER_RESULT"

    if [ "$TASK_TYPE" = "code" ] && [ -n "$TASK_PATH" ]; then
      REVIEWER_PROMPT="$REVIEWER_PROMPT

### Working Directory
$TASK_PATH

Note: This is a code task. In addition to checking completeness against the acceptance criteria, also review changed files for code quality, security, and performance using the established review standards."
    fi

    # Spawn reviewer session
    REVIEW_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    REVIEW_OUT=$(mktemp /tmp/review-out-XXXXXX.json)

    set +e
    if [ -n "$REVIEWER_SESSION_ID" ]; then
      (cd "$WORK_DIR" && claude-atlas --mode reviewer --output-format json \
        --dangerously-skip-permissions \
        --resume "$REVIEWER_SESSION_ID" \
        -p "$REVIEWER_PROMPT" > "$REVIEW_OUT" 2>>"$LOG")
    else
      (cd "$WORK_DIR" && claude-atlas --mode reviewer --output-format json \
        --dangerously-skip-permissions \
        -p "$REVIEWER_PROMPT" > "$REVIEW_OUT" 2>>"$LOG")
    fi
    REVIEW_EXIT=$?
    set -e

    REVIEW_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    REVIEWER_SESSION_ID=$(extract_session_id "$REVIEW_OUT")
    REVIEW_RESULT=$(extract_result "$REVIEW_OUT")

    save_session_metrics "$REVIEW_OUT" "reviewer" "$TRIGGER_NAME" "$REVIEW_START" "$REVIEW_END" "$REVIEW_EXIT"
    rm -f "$REVIEW_OUT"

    if [ "$REVIEW_EXIT" -ne 0 ] && [ -z "$REVIEW_RESULT" ]; then
      log "Reviewer crashed (exit=$REVIEW_EXIT), accepting worker result as-is"
      break
    fi

    # Parse verdict from reviewer result
    VERDICT=$(python3 -c "
import json, sys, re
text = sys.argv[1]
# Try to find JSON block in the output
m = re.search(r'\{[^{}]*\"verdict\"[^{}]*\}', text, re.DOTALL)
if m:
    try:
        d = json.loads(m.group())
        print(d.get('verdict', 'approve'))
        sys.exit(0)
    except: pass
# Fallback: look for keywords
lower = text.lower()
if 'revise' in lower and 'approve' not in lower:
    print('revise')
else:
    print('approve')
" "$REVIEW_RESULT" 2>/dev/null || echo "approve")

    log "Review verdict: $VERDICT"

    if [ "$VERDICT" = "approve" ]; then
      log "Review approved"
      break
    fi

    # Verdict is "revise" — feed back to worker
    if [ "$REVIEW_ITERATION" -ge "$MAX_REVIEW_ITERATIONS" ]; then
      log "Max review iterations reached ($MAX_REVIEW_ITERATIONS), accepting current result"
      break
    fi

    log "Sending review feedback to worker"

    FEEDBACK_PROMPT="## Review Feedback (Iteration $REVIEW_ITERATION)

The reviewer has identified issues with your work. Please address the following feedback and re-submit your result.

### Reviewer Feedback
$REVIEW_RESULT

### Original Task
$TASK_CONTENT

Please fix the identified issues and provide an updated result."

    # Resume worker session with feedback
    sqlite3 "$DB" "UPDATE tasks SET status='processing' WHERE id=$TASK_ID;" 2>/dev/null

    WORKER_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    WORKER_OUT2=$(mktemp /tmp/worker-out-XXXXXX.json)

    set +e
    if [ -n "$WORKER_SESSION_ID" ]; then
      (cd "$WORK_DIR" && claude-atlas --mode worker-ephemeral --output-format json \
        --dangerously-skip-permissions \
        --resume "$WORKER_SESSION_ID" \
        -p "$FEEDBACK_PROMPT" > "$WORKER_OUT2" 2>>"$LOG")
    else
      (cd "$WORK_DIR" && claude-atlas --mode worker-ephemeral --output-format json \
        --dangerously-skip-permissions \
        -p "$FEEDBACK_PROMPT" > "$WORKER_OUT2" 2>>"$LOG")
    fi
    WORKER_EXIT=$?
    set -e

    WORKER_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    WORKER_SESSION_ID=$(extract_session_id "$WORKER_OUT2")
    WORKER_RESULT=$(extract_result "$WORKER_OUT2")

    save_session_metrics "$WORKER_OUT2" "worker" "$TRIGGER_NAME" "$WORKER_START" "$WORKER_END" "$WORKER_EXIT"
    rm -f "$WORKER_OUT2"

    # Update worker result in DB
    sqlite3 "$DB" "UPDATE tasks SET worker_result=$(printf "'%s'" "$(echo "$WORKER_RESULT" | sed "s/'/''/g")") WHERE id=$TASK_ID;" 2>/dev/null || true

    if [ "$WORKER_EXIT" -ne 0 ] && [ -z "$WORKER_RESULT" ]; then
      log "Worker crashed during revision (exit=$WORKER_EXIT)"
      mark_failed "Worker crashed during revision iteration $REVIEW_ITERATION"
      rm -f "$WORKER_OUT"
      exit 1
    fi
  done
fi

rm -f "$WORKER_OUT"

# 7. Task complete — build response summary
RESPONSE_SUMMARY="$WORKER_RESULT"

# 8. Mark task as done
sqlite3 "$DB" "UPDATE tasks SET status='done', response_summary=$(printf "'%s'" "$(echo "$RESPONSE_SUMMARY" | sed "s/'/''/g")"), processed_at=datetime('now') WHERE id=$TASK_ID;" 2>/dev/null

log "Task completed successfully"

# 9. Wake trigger that created this task
bun run "$APP_DIR/inbox-mcp/wake-trigger.ts" "$TASK_ID" "$RESPONSE_SUMMARY" 2>>"$LOG" || true

log "Task runner finished"
